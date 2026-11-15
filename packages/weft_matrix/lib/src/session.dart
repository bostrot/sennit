import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vodozemac;
import 'package:matrix/encryption.dart' as enc;
import 'package:matrix/matrix.dart' as sdk;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'homeserver.dart';
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

    final client = sdk.Client(
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
    );
    _client = client;

    client.onLoginStateChanged.stream.listen(_onLoginStateChanged);

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
    await client.checkHomeserver(discovery.baseUrl);
    return discovery;
  }

  /// Which login flows the current homeserver offers, so the UI can show an
  /// SSO button only when SSO actually exists.
  Future<List<sdk.LoginFlow>> supportedLoginFlows() async {
    final flows = await client.getLoginFlows();
    return flows ?? const [];
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
    final path = providerId == null
        ? '/_matrix/client/v3/login/sso/redirect'
        : '/_matrix/client/v3/login/sso/redirect/$providerId';
    return base.replace(
      path: path,
      queryParameters: {'redirectUrl': redirectUrl},
    );
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

  Future<void> dispose() async {
    await _stateController.close();
    await _client?.dispose();
    _client = null;
  }

  void _onLoginStateChanged(sdk.LoginState loginState) {
    _emit(switch (loginState) {
      sdk.LoginState.loggedIn => _deriveState(),
      sdk.LoginState.loggedOut => WeftSessionState.loggedOut,
      sdk.LoginState.softLoggedOut => WeftSessionState.softLoggedOut,
    });
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
