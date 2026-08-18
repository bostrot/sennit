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
    await client.init();

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

    return sdk.MatrixSdkDatabase.init(
      'weft',
      database: await openWeftSqfliteDatabase(
        p.join(directory.path, 'weft.sqlite'),
      ),
      // Attachments are cached on disk with a cap, so a chat full of video
      // doesn't grow the database without bound.
      maxFileSize: 32 * 1024 * 1024,
      fileStorageLocation: directory.uri,
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
