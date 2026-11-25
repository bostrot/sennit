import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vodozemac;
import 'package:matrix/encryption.dart' as enc;
import 'package:matrix/matrix.dart' as sdk;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'homeserver.dart';
import 'login_methods.dart';
import 'registration.dart';

/// Where the session is in its lifecycle, flattened for the UI.
enum WeftSessionState {
  /// No stored session; the user must log in.
  loggedOut,

  /// Restoring a stored session or performing first sync.
  connecting,

  /// Usable, but this device cannot read history from before it joined and
  /// other devices see it as untrusted until it is verified.
  unverified,

  /// Fully set up: synced, cross-signed, backup available.
  ready,

  /// The server invalidated our token.
  softLoggedOut,
}

/// Owns the Matrix client for the whole app.
///
/// One instance per process. The Famedly SDK persists sessions in its own
/// database, so restoring a login is `init()` with no arguments — Weft stores
/// no access tokens of its own.
class WeftMatrixSession {
  WeftMatrixSession({
    this.clientName = 'Weft',
    this.deviceDisplayName = 'Weft',
    Future<sdk.DatabaseApi> Function()? databaseOverride,
  }) : _databaseOverride = databaseOverride;

  final String clientName;
  final String deviceDisplayName;

  /// Supplies an alternative database, so tests can run against a throwaway
  /// one instead of the user's real session store. Async because opening a
  /// database is.
  final Future<sdk.DatabaseApi> Function()? _databaseOverride;

  sdk.Client? _client;
  final _stateController = StreamController<WeftSessionState>.broadcast();
  WeftSessionState _state = WeftSessionState.loggedOut;

  /// The live client. Throws before [initialize] — every call site runs behind
  /// the auth gate, so a null check there would be noise.
  sdk.Client get client {
    final c = _client;
    if (c == null) {
      throw StateError('WeftMatrixSession.initialize() has not been called');
    }
    return c;
  }

  bool get isInitialized => _client != null;

  WeftSessionState get state => _state;

  Stream<WeftSessionState> get states => _stateController.stream;

  /// Whether vodozemac is up and this client can do E2EE at all.
  bool get encryptionEnabled => _client?.encryptionEnabled ?? false;

  /// Creates the client and restores any stored session.
  ///
  /// Safe to call once at startup. Returns the resulting state so the router
  /// can decide between the auth flow and the inbox without a second round.
  Future<WeftSessionState> initialize() async {
    if (_client != null) return _state;

    // Must precede client construction: the SDK checks for a working
    // vodozemac implementation when it decides whether E2EE is available.
    await _ensureVodozemac();

    final database = await (_databaseOverride?.call() ?? _openDatabase());

    final client = _WeftClient(
      clientName,
      database: database,
      verificationMethods: {
        enc.KeyVerificationMethod.emoji,
        enc.KeyVerificationMethod.numbers,
        enc.KeyVerificationMethod.qrScan,
        enc.KeyVerificationMethod.qrShow,
        enc.KeyVerificationMethod.reciprocate,
      },
      // Weft needs bridge state to know which network a room belongs to, so it
      // must survive lazy-loading rather than being fetched per room later.
      importantStateEvents: {'m.bridge', 'uk.half-shot.bridge'},
      logLevel: kDebugMode ? sdk.Level.warning : sdk.Level.error,
      // The most common cause of a soft logout is an expired token, and the
      // SDK can recover from that by itself.
      onSoftLogout: (client) => client.refreshAccessToken(),
      // The SDK otherwise refuses, in checkHomeserver, any server without a
      // password login — an SSO-only Synapse among them.
      supportedLoginTypes: {
        sdk.AuthenticationTypes.password,
        sdk.AuthenticationTypes.sso,
        sdk.AuthenticationTypes.token,
      },
    );
    _client = client;

    client.onLoginStateChanged.stream.listen(_onLoginStateChanged);
    client.onUiaRequest.stream.listen(_onUiaRequest);

    _emit(WeftSessionState.connecting);
    // Not `waitForFirstSync`: with it, init() holds until the homeserver
    // answers a full /sync round-trip and the client has processed it — on an
    // account with hundreds of bridged rooms that is tens of seconds, all of
    // them spent behind the splash. Everything the inbox needs to draw is
    // already in the local database from the last run; the sync keeps running
    // in the background and its news streams in through `onSync` exactly as it
    // would have a minute later.
    await client.init(waitForFirstSync: false);

    // The one start with nothing cached to show: a device that has never
    // completed a sync (`prevBatch` is only ever written by one). Declaring
    // the session ready there renders an empty inbox that reads as an empty
    // *account*, so this start — and only this one — keeps the splash until
    // the first sync lands.
    if (client.isLogged() && client.prevBatch == null) {
      try {
        await client.firstSyncReceived;
      } on Object {
        // Offline, or a server mid-restart. The SDK's sync loop retries on
        // its own; an inbox that fills in when the network returns beats a
        // spinner that never ends.
      }
    }

    _emit(_deriveState());
    return _state;
  }

  /// Initialises vodozemac exactly once per process.
  ///
  /// It is backed by flutter_rust_bridge, which throws
  /// `Should not initialize flutter_rust_bridge twice` on a second call. That
  /// makes this a process-wide concern rather than a per-session one: a
  /// logout-then-login cycle, a second account, or a test file that builds
  /// several sessions would all otherwise crash here.
  static Future<void>? _vodozemacInit;

  static Future<void> _ensureVodozemac() {
    // Cached as a Future, not a bool, so concurrent callers await the same
    // initialisation instead of racing into a second one.
    return _vodozemacInit ??= vodozemac.init();
  }

  Future<sdk.DatabaseApi> _openDatabase() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'matrix'));
    if (!directory.existsSync()) directory.createSync(recursive: true);

    // The attachment cache gets a directory of its own, and must not be given
    // the one the database lives in. `deleteFilesAfterDuration` makes the SDK
    // periodically `list()` this directory and `delete()` every plain file
    // older than the retention window (`database_file_storage_io.dart:63-80`),
    // and it excludes nothing — so pointing it at the database directory aims
    // a garbage collector at `weft.sqlite`.
    //
    // Two consequences, one seen and one waiting. The seen one is a race: the
    // listing picks up sqlite's transient `weft.sqlite-journal`, sqlite removes
    // it, and the `delete()` throws `PathNotFoundException` out of an unawaited
    // future. It surfaced on the emulator as three unrelated Patrol scenarios
    // failing on "Cannot delete file … weft.sqlite-journal" — an error with
    // nothing to do with what any of them was testing.
    //
    // The unseen one is worse: nothing stops the same sweep deleting
    // `weft.sqlite` itself. The file is only safe while it keeps being written,
    // so the account at risk is the dormant one — open Weft after a month away
    // and the sweep is entitled to delete the database, the device keys in it,
    // and with them every encrypted message this device could still read.
    final files = Directory(p.join(directory.path, 'files'));
    if (!files.existsSync()) files.createSync(recursive: true);

    return sdk.MatrixSdkDatabase.init(
      'weft',
      database: await openWeftSqfliteDatabase(
        p.join(directory.path, 'weft.sqlite'),
      ),
      // Attachments are cached on disk with a cap, so a chat full of video
      // doesn't grow the database without bound.
      maxFileSize: 32 * 1024 * 1024,
      fileStorageLocation: files.uri,
      deleteFilesAfterDuration: const Duration(days: 30),
    );
  }

  /// Resolves a homeserver from user input and points the client at it.
  ///
  /// Separate from [loginWithPassword] because the UI validates the server
  /// before asking for credentials — telling someone their password is wrong
  /// when the server name was the problem is a bad experience.
  Future<HomeserverDiscovery> checkHomeserver(String input) async {
    final parsed = parseHomeserverInput(input);
    if (parsed == null) {
      throw const FormatException('That does not look like a server address');
    }

    final discovery = await discoverHomeserver(parsed);
    try {
      await client.checkHomeserver(discovery.baseUrl);
    } on sdk.BadServerLoginTypesException {
      // A server whose only ways in are ones Sennit cannot do is still a
      // server: [loginMethods] says which, rather than this failing on a
      // name that looks like a typo.
      client.homeserver = discovery.baseUrl;
    }
    return discovery;
  }

  /// Which login flows the current homeserver offers, so the UI can show an
  /// SSO button only when SSO actually exists.
  Future<List<sdk.LoginFlow>> supportedLoginFlows() async {
    final flows = await client.getLoginFlows();
    return flows ?? const [];
  }

  /// Every way the current homeserver lets someone sign in.
  ///
  /// `GET /login` and the OAuth metadata are asked separately, and a refusal
  /// of either is an answer rather than a failure: a server that hands
  /// sign-in to its OAuth server refuses `GET /login` with `M_UNRECOGNIZED`
  /// — Continuwuity with an identity provider says "User-interactive
  /// authentication is not available on this server" — and that refusal,
  /// shown as it was, was the whole login screen.
  Future<LoginMethods> loginMethods() async {
    List<sdk.LoginFlow>? flows;
    try {
      flows = await client.getLoginFlows();
    } on sdk.MatrixException {
      flows = null;
    }
    Map<String, Object?>? metadata;
    try {
      metadata = await (client as _WeftClient).authMetadataJson();
    } on Object {
      metadata = null;
    }
    // Neither answered: the server is not refusing a method, it is not
    // answering. Asking again for the flows surfaces why.
    if (flows == null && metadata == null) {
      await client.getLoginFlows();
    }
    return loginMethodsFrom(flows: flows, authMetadata: metadata);
  }

  Future<void> loginWithPassword({
    required String username,
    required String password,
  }) async {
    _emit(WeftSessionState.connecting);
    try {
      await client.login(
        sdk.LoginType.mLoginPassword,
        identifier: sdk.AuthenticationUserIdentifier(user: username),
        password: password,
        initialDeviceDisplayName: deviceDisplayName,
      );
      _emit(_deriveState());
    } catch (_) {
      _emit(WeftSessionState.loggedOut);
      rethrow;
    }
  }

  /// What the current homeserver asks of someone creating an account.
  ///
  /// An empty registration request is the question: the server answers it
  /// with the stages it would want, or with a refusal, and creates nothing
  /// either way. Asked before the form is shown, so the invite-code field is
  /// there when the server wants one and absent when it does not.
  Future<RegistrationOffer> registrationOffer() async {
    try {
      await client.register();
    } on sdk.MatrixException catch (e) {
      final flows = e.authenticationFlows;
      if (flows != null) {
        return registrationOfferFor(flows.map((f) => f.stages));
      }
      if (_registrationClosed(e)) return RegistrationOffer.closed;
      rethrow;
    }
    // No server registers an account from an empty request; one that claims
    // to has not told us anything a form could be built on.
    return RegistrationOffer.unsupported;
  }

  /// Creates an account on the current homeserver and signs this device in.
  ///
  /// Unlike [loginWithPassword] this never passes through
  /// [WeftSessionState.connecting]: a taken username or a refused invite code
  /// is the ordinary case here, and the form has to still be on screen, with
  /// what was typed in it, when the refusal arrives.
  Future<void> register({
    required String username,
    required String password,
    String? registrationToken,
  }) async {
    final token = registrationToken?.trim() ?? '';
    sdk.AuthenticationData? auth;
    // One round trip per stage, and a bound on them: a server that keeps
    // answering a completed stage with another challenge must not be followed
    // forever.
    for (var round = 0; round < 5; round++) {
      try {
        await client.register(
          username: username,
          password: password,
          initialDeviceDisplayName: deviceDisplayName,
          auth: auth,
        );
        _emit(_deriveState());
        return;
      } on sdk.MatrixException catch (e) {
        final flows = e.authenticationFlows;
        if (flows == null) {
          if (_registrationClosed(e)) {
            throw const RegistrationException(RegistrationFailure.closed);
          }
          rethrow;
        }
        final stage = nextRegistrationStage(
          flows.map((f) => f.stages),
          completed: e.completedAuthenticationFlows,
        );
        if (stage == null) {
          throw const RegistrationException(RegistrationFailure.unsupported);
        }
        if (stage == RegistrationStage.token) {
          if (token.isEmpty) {
            throw const RegistrationException(
              RegistrationFailure.tokenRequired,
            );
          }
          // Asked for the stage that was just submitted: it was refused.
          if (auth?.type == RegistrationStage.token) {
            throw const RegistrationException(
              RegistrationFailure.tokenRejected,
            );
          }
        }
        auth = sdk.AuthenticationData(
          type: stage,
          session: e.session,
          additionalFields: {
            if (stage == RegistrationStage.token) 'token': token,
          },
        );
      }
    }
    throw const RegistrationException(RegistrationFailure.unsupported);
  }

  /// Whether [e] is a server saying it does not register accounts here —
  /// switched off, or handed to a separate sign-up service.
  static bool _registrationClosed(sdk.MatrixException e) =>
      e.errcode == 'M_FORBIDDEN' ||
      e.errcode == 'M_UNRECOGNIZED' ||
      e.response?.statusCode == 404;

  /// Completes an SSO redirect using the token the browser handed back.
  Future<void> loginWithToken(String token) async {
    _emit(WeftSessionState.connecting);
    try {
      await client.login(
        sdk.LoginType.mLoginToken,
        token: token,
        initialDeviceDisplayName: deviceDisplayName,
      );
      _emit(_deriveState());
    } catch (_) {
      _emit(WeftSessionState.loggedOut);
      rethrow;
    }
  }

  /// The URL to open for SSO. [redirectUrl] must be a scheme the app handles.
  Uri ssoRedirectUrl(String redirectUrl, {String? providerId}) {
    final base = client.homeserver!;
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final path = providerId == null
        ? '$prefix/_matrix/client/v3/login/sso/redirect'
        : '$prefix/_matrix/client/v3/login/sso/redirect/'
              '${Uri.encodeComponent(providerId)}';
    return base.replace(
      path: path,
      queryParameters: {'redirectUrl': redirectUrl},
    );
  }

  /// Finishes a legacy SSO sign-in from the address the browser came back
  /// to.
  Future<void> completeSsoLogin(Uri callback) =>
      loginWithToken(ssoLoginTokenFrom(callback));

  /// Starts a next-gen (OAuth 2.0) sign-in: registers Sennit with the
  /// server's OAuth server and builds the page to open.
  ///
  /// Registered afresh on every sign-in rather than once per server: a
  /// registration is cheap, and a stored one goes stale when the server is
  /// reset or forgets it, which would fail the sign-in with nothing the
  /// person could do about it. [create] asks the page to open on its sign-up
  /// form, for a server whose metadata says it has one.
  Future<sdk.OidcLoginSession> beginOAuthLogin(
    Uri redirectUri, {
    bool create = false,
  }) async {
    final loopback = redirectUri.scheme == 'http';
    final registration = await client.registerOidcClient(
      redirectUris: [redirectUri],
      applicationType: sdk.OidcApplicationType.native,
      clientInformation: sdk.OidcClientInformation(
        // l10n-ignore: the app's own name, never translated.
        clientName: 'Sennit',
        clientUri: kOAuthClientUri,
        logoUri: null,
        tosUri: null,
        policyUri: kOAuthPolicyUri,
      ),
    );
    return client.initOidcLoginSession(
      oidcClientData: registration,
      redirectUri: redirectUri,
      // The loopback server reads the query; a phone's redirect is handed
      // back whole, so either works there, and the query is what every
      // server supports.
      responseMode: loopback ? sdk.OidcResponseMode.query : null,
      prompt: create ? 'create' : null,
    );
  }

  /// Finishes an OAuth sign-in from the address the browser came back to.
  Future<void> completeOAuthLogin(
    sdk.OidcLoginSession attempt,
    Uri callback,
  ) async {
    final code = oauthCodeFrom(callback, state: attempt.state);
    _emit(WeftSessionState.connecting);
    try {
      await client.oidcLogin(
        session: attempt,
        code: code,
        state: attempt.state,
      );
      // OAuth has no initial device name; without this the device list on
      // every other client shows a bare device id.
      final deviceId = client.deviceID;
      if (deviceId != null) {
        unawaited(
          client
              .updateDevice(deviceId, displayName: deviceDisplayName)
              .catchError((Object _) {}),
        );
      }
      _emit(_deriveState());
    } catch (_) {
      _emit(WeftSessionState.loggedOut);
      rethrow;
    }
  }

  /// The OAuth server this session signed in through, or null for a session
  /// signed in with a password or a token.
  ///
  /// Such a session cannot answer a UIA challenge with a password — it never
  /// had one here — so device sign-outs and deactivation go to the server's
  /// account page instead.
  Future<OAuthServer?> signedInOAuthServer() async {
    final c = _client;
    return c == null ? null : oauthServerOf(c);
  }

  /// Opens a page a UIA challenge sent this session to and resolves once the
  /// person says they finished there; false when they backed out.
  ///
  /// Set by the app. Without it a challenge that needs the browser fails at
  /// once rather than waiting for an answer nothing is going to give.
  Future<bool> Function(Uri url)? onBrowserStage;

  final _uiaInFlight = <sdk.UiaRequest<dynamic>>{};

  /// Answers the UIA challenges the SDK raises in the background — today
  /// only the cross-signing upload while setting up recovery.
  ///
  /// Nothing listened before, and an unanswered challenge never completes:
  /// the setup spun forever. A server that signs in through OAuth sends the
  /// browser stage, done on its account page; anything else is refused here,
  /// and the setup reports the refusal.
  Future<void> _onUiaRequest(sdk.UiaRequest<dynamic> uia) async {
    if (uia.state != sdk.UiaRequestState.waitForUser) return;
    if (!_uiaInFlight.add(uia)) return;
    try {
      final url = oauthStageUrl(uia.nextStages, uia.params);
      final open = onBrowserStage;
      if (url == null || open == null) {
        uia.cancel();
        return;
      }
      final stage = uia.nextStages.contains(kOAuthStage)
          ? kOAuthStage
          : kCrossSigningResetStage;
      if (!await open(url)) {
        uia.cancel();
        return;
      }
      await uia.completeStage(
        sdk.AuthenticationData(type: stage, session: uia.session),
      );
    } finally {
      _uiaInFlight.remove(uia);
    }
  }

  /// True when this device still needs to be verified by another one.
  ///
  /// Until then it cannot decrypt history from before it joined, which is the
  /// single most confusing state a new Matrix user hits — so the UI treats it
  /// as a first-class step rather than a dismissible notice.
  bool get needsVerification {
    final encryption = _client?.encryption;
    if (encryption == null) return false;
    return !(_client
                ?.userDeviceKeys[_client?.userID]
                ?.deviceKeys[_client?.deviceID]
                ?.verified ??
            false) &&
        _client!.userID != null;
  }

  /// Whether cross-signing keys exist on the account at all. When false, this
  /// is the first device and should *bootstrap* rather than wait to be verified.
  bool get crossSigningExists =>
      _client?.encryption?.crossSigning.enabled ?? false;

  /// Starts interactive verification against another of the user's devices.
  ///
  /// With no [deviceId] this requests verification from *all* other devices,
  /// which is what a fresh login wants — whichever device the user is holding
  /// can answer.
  Future<enc.KeyVerification?> startVerification({String? deviceId}) async {
    final client = _client;
    final userId = client?.userID;
    if (client == null || userId == null) return null;

    final keys = client.userDeviceKeys[userId];
    if (keys == null) return null;

    if (deviceId != null) {
      return keys.deviceKeys[deviceId]?.startVerification();
    }
    return keys.startVerification();
  }

  // Cross-signing and key-backup setup lives in `key_backup.dart`, behind the
  // `KeyBackup` interface. It was a method here once and could not be used: it
  // started the SDK's bootstrap machine without awaiting it and returned
  // nothing, so a caller had no key to show and no way to know it had finished.

  Future<void> logout() async {
    try {
      await _client?.logout();
    } finally {
      _emit(WeftSessionState.loggedOut);
    }
  }

  /// Forgets everything this device holds for the account: the SDK's
  /// database with its rooms, events and encryption keys, and the attachment
  /// cache beside it.
  ///
  /// [logout] asks the server first and is no use once the account is gone —
  /// after a deactivation every token is already dead, and the request would
  /// only fail on its way to the same local clear-out.
  Future<void> clearLocalData() async {
    try {
      await _client?.clear();
    } finally {
      if (_databaseOverride == null) await _deleteAttachmentCache();
      _emit(WeftSessionState.loggedOut);
    }
  }

  Future<void> _deleteAttachmentCache() async {
    try {
      final support = await getApplicationSupportDirectory();
      final files = Directory(p.join(support.path, 'matrix', 'files'));
      if (files.existsSync()) await files.delete(recursive: true);
    } on Object {
      // A file held open by the platform is not a reason to leave the app
      // signed in to an account that no longer exists.
    }
  }

  Future<void> dispose() async {
    await _stateController.close();
    await _client?.dispose();
    _client = null;
  }

  void _onLoginStateChanged(sdk.LoginState loginState) {
    _emit(
      sessionStateAfterLogin(
        loginState,
        current: _state,
        refreshable: _client?.accessTokenExpiresAt != null,
        derive: _deriveState,
      ),
    );
  }

  WeftSessionState _deriveState() {
    final client = _client;
    if (client == null || client.userID == null) {
      return WeftSessionState.loggedOut;
    }
    if (!client.encryptionEnabled) return WeftSessionState.ready;
    return needsVerification
        ? WeftSessionState.unverified
        : WeftSessionState.ready;
  }

  void _emit(WeftSessionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }
}

/// What the session becomes when the SDK reports [login].
///
/// A token refresh reaches here as a soft logout followed by a login, and
/// neither half changes who is signed in or whether this device is verified.
/// Both are held at [current]: the soft logout so that the sign-in screen
/// does not flash up — taking a verification in progress down with it — while
/// the SDK fetches a new token by itself, and the login so that the state is
/// not worked out again halfway through setup. By then the SDK has downloaded
/// this device's keys and trusts its own device, so [derive] answers `ready`
/// and the verification step was skipped for the notification prompt. OAuth
/// sessions refresh every few minutes, which is where that showed up.
///
/// [refreshable] is whether the token expires, and so whether the SDK can
/// recover by itself; a soft logout it cannot recover from still signs out.
@visibleForTesting
WeftSessionState sessionStateAfterLogin(
  sdk.LoginState login, {
  required WeftSessionState current,
  required bool refreshable,
  required WeftSessionState Function() derive,
}) {
  final signedIn =
      current == WeftSessionState.unverified ||
      current == WeftSessionState.ready;
  return switch (login) {
    sdk.LoginState.loggedOut => WeftSessionState.loggedOut,
    sdk.LoginState.softLoggedOut when signedIn && refreshable => current,
    sdk.LoginState.softLoggedOut => WeftSessionState.softLoggedOut,
    sdk.LoginState.loggedIn when signedIn => current,
    sdk.LoginState.loggedIn => derive(),
  };
}

/// The OAuth server [client]'s session signed in through, or null for a
/// session signed in with a password or a token — or one whose server cannot
/// be asked right now.
Future<OAuthServer?> oauthServerOf(sdk.Client client) async {
  if (!client.isLogged()) return null;
  final stored = await client.database.getClient(client.clientName);
  if (stored?['oidc_client_id'] == null) return null;
  try {
    final json = client is _WeftClient
        ? await client.authMetadataJson()
        : (await client.getAuthMetadata()).toJson();
    return OAuthServer.fromJson(json);
  } on Object {
    return null;
  }
}

/// The SDK's client, with the OAuth metadata read leniently.
///
/// The SDK parses the metadata strictly: an account-page action newer than
/// it throws a `TypeError`, and a server that only serves the metadata at
/// MSC2965's unstable path is not found at all. Every OAuth call it makes —
/// registration, sign-in, token refresh, sign-out — goes through
/// [getAuthMetadata], so it is overridden here once.
class _WeftClient extends sdk.Client {
  _WeftClient(
    super.clientName, {
    required super.database,
    super.verificationMethods,
    super.importantStateEvents,
    super.logLevel,
    super.onSoftLogout,
    super.supportedLoginTypes,
  });

  Uri? _metadataFor;
  Map<String, Object?>? _metadata;

  /// The server's OAuth 2.0 metadata as it sent it, cached per server.
  Future<Map<String, Object?>> authMetadataJson() async {
    final base = homeserver;
    if (base == null) throw StateError('No homeserver');
    if (_metadataFor == base && _metadata != null) return _metadata!;
    Future<http.Response> get(String path) =>
        httpClient.get(base.resolveUri(Uri(path: path)));
    var response = await get('_matrix/client/v1/auth_metadata');
    if (response.statusCode == 404 ||
        (response.statusCode == 400 &&
            response.body.contains('M_UNRECOGNIZED'))) {
      final unstable = await get(
        '_matrix/client/unstable/org.matrix.msc2965/auth_metadata',
      );
      if (unstable.statusCode == 200) response = unstable;
    }
    if (response.statusCode != 200) {
      unexpectedResponse(response, response.bodyBytes);
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map<String, Object?>) {
      throw const FormatException('OAuth metadata is not an object');
    }
    _metadataFor = base;
    return _metadata = json;
  }

  @override
  Future<sdk.GetAuthMetadataResponse> getAuthMetadata({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async => sdk.GetAuthMetadataResponse.fromJson(
    sanitizeAuthMetadata(await authMetadataJson()),
  );
}
