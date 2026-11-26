import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/localisation.dart';
import 'background_push.dart' show runFirebaseBackgroundPush;

/// Which platforms this build can do what on.
///
/// One place, rather than a `Platform.isAndroid` at every call site, because
/// the answers are not the same question: *push* is Android and iOS, *local
/// notifications* are all five, and *runtime permission* is Android 13+, iOS
/// and macOS. Conflating them is how a Linux build ends up asking Firebase for
/// a token.
///
/// Reads [defaultTargetPlatform] rather than `dart:io`'s `Platform` so a test
/// can pretend to be a phone — which is the only way the Android and iOS
/// branches below are reachable from `flutter test` on a laptop.
abstract final class NotificationPlatform {
  /// Where Sennit registers a Matrix pusher and receives pokes.
  ///
  /// Not macOS, even though `firebase_messaging` declares a macOS
  /// implementation — and not Windows, where `firebase_core` alone is linked in
  /// — because a pub dependency cannot be made per-platform and both are
  /// therefore present in a desktop build whether or not they are wanted. A Mac
  /// has no APNs entitlement in an unsigned build, and asking it for a token
  /// produces an exception rather than a token. Desktop Sennit notifies from the
  /// foreground sync path, which needs no gateway at all.
  static bool get supportsPush =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Where the OS asks the user before a single notification may be posted.
  static bool get needsPermissionPrompt =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
}

/// The app id Sennit registers its pusher under, per platform.
///
/// Per platform and not per app: the gateway routes on this to decide whether a
/// poke becomes an FCM message or an APNs one, so the two builds of the same
/// program register different ids. They must match the app ids configured in
/// whichever sygnal the user runs — which is why they are constants with names
/// rather than a string built at the call site.
const String kAndroidPushAppId = 'com.bostrot.weft.android';
const String kIosPushAppId = 'com.bostrot.weft.ios';

/// The app id of an iOS build signed for development (an Xcode run). Its APNs
/// tokens are sandbox tokens, which production APNs refuses, so Sennit's
/// gateway serves them under an id of their own.
const String kIosSandboxPushAppId = 'com.bostrot.weft.ios.dev';

/// Sennit's own push gateway: a sygnal holding the FCM and APNs credentials
/// that only the published builds can use. It receives what the homeserver
/// sends for an `event_id_only` pusher and nothing more — see
/// docs/ops/push-gateway.md.
const String kSennitPushGateway =
    'https://push.bostrot.com/_matrix/push/v1/notify';

/// Which gateway wakes this device.
enum PushGatewayMode {
  /// [kSennitPushGateway].
  sennit,

  /// The URL the user typed — their own sygnal, or any other.
  custom,

  /// No pusher. The built-in connection or UnifiedPush may still deliver.
  off;

  static PushGatewayMode? parse(String? value) =>
      PushGatewayMode.values.asNameMap()[value];
}

/// The mode in force, from what is stored.
///
/// Null means the user has not been asked yet, which only a build that offers
/// Sennit's gateway ([offerSennit]) can be in: it registers nothing until the
/// explanation has been answered. An install from before the choice existed
/// that already had a URL keeps using it.
PushGatewayMode? effectivePushMode({
  required String? stored,
  required String? customUrl,
  required bool offerSennit,
}) {
  final parsed = PushGatewayMode.parse(stored);
  if (parsed != null) return parsed;
  if ((customUrl ?? '').trim().isNotEmpty) return PushGatewayMode.custom;
  return offerSennit ? null : PushGatewayMode.custom;
}

/// The gateway a [mode] registers with, or null for none.
Uri? gatewayForMode(PushGatewayMode? mode, String? customUrl) => switch (mode) {
  PushGatewayMode.sennit => Uri.parse(kSennitPushGateway),
  PushGatewayMode.custom => resolvePushGateway(customUrl),
  PushGatewayMode.off || null => null,
};

/// The `default_payload` handed to the gateway for an iOS pusher.
///
/// `mutable-content: 1` is the only thing that gives the notification service
/// extension a chance to run, and without the extension an `event_id_only` push
/// has literally nothing to show — the payload carries an event id and no text.
/// The placeholder alert is what iOS displays in the half-second before the
/// extension replaces it, and in the case where the extension is killed for
/// running over its budget.
const Map<String, Object?> kIosDefaultPayload = {
  'aps': {
    'mutable-content': 1,
    'alert': {'title': 'Sennit', 'body': 'New message'},
    'sound': 'default',
  },
};

/// Where this device's push key is remembered between runs.
///
/// An interface over two lines of [SettingsStore] because the registration
/// logic is the part worth testing and it must not need a database to be
/// exercised.
abstract interface class PushKeyStore {
  String? readPushKey();
  void writePushKey(String? value);
}

/// The platform's push side: this device's token, and the pokes that arrive on
/// it.
///
/// Behind an interface for the reason every Firebase call in Weft is: the whole
/// point of [NotificationPlatform.supportsPush] is that this is never
/// constructed on a desktop, and a test that wants to exercise registration or
/// delivery should not have to stand up a Firebase app to do it.
abstract interface class PushTransport {
  /// The token, or null when there is not one to be had — no Firebase
  /// configuration in the build, permission refused, or APNs not yet answered.
  Future<String?> token();

  /// Tokens reissued after this call. FCM rotates on reinstall, on restore
  /// from backup, and at Google's discretion; a pusher registered against the
  /// old one is a device the gateway pokes forever and never reaches.
  Stream<String> get tokenRefreshes;

  /// Pokes, as the raw map the gateway sent.
  ///
  /// Deliberately untyped: `MatrixPushPayload.fromJson` already knows the three
  /// shapes these arrive in, and a second parse here would be a second answer
  /// to the same question.
  Stream<Map<String, Object?>> get pushes;

  /// The app id the gateway knows this kind of token under.
  String get appId;

  /// Gives the token back, so the push service forgets this device. Called
  /// when the user turns push off.
  Future<void> release();
}

/// [PushTransport] over `firebase_messaging`.
///
/// The only file in Sennit that imports Firebase. Everything above it takes a
/// [PushTransport], so the platform check happens once — here, at construction
/// — rather than at every use.
class FirebasePushTransport implements PushTransport {
  FirebasePushTransport._();

  /// Initialises Firebase and returns a transport, or null when this platform
  /// or this build cannot have one.
  ///
  /// Null rather than an exception for the ordinary case: a build with no
  /// `google-services.json` is not broken, it is a build without push, and it
  /// still notifies from sync. Treating an absent Firebase configuration as a
  /// startup failure would make the desktop app refuse to launch.
  static Future<FirebasePushTransport?> initialize() async {
    if (!NotificationPlatform.isAndroid) return null;
    try {
      await Firebase.initializeApp();
      // A poke that arrives while no UI is in front. Registered on every
      // launch; the plugin keeps the handle, so it also serves the cold starts
      // after this one.
      FirebaseMessaging.onBackgroundMessage(runFirebaseBackgroundPush);
      return FirebasePushTransport._();
    } on Object catch (error) {
      // `FirebaseException` for a missing default app, `MissingPluginException`
      // in a test binding, `PlatformException` for a malformed
      // `google-services.json`. All three mean the same thing to the caller.
      debugPrint(
        'weft: push unavailable — Firebase did not initialise: $error',
      );
      return null;
    }
  }

  @override
  Stream<Map<String, Object?>> get pushes =>
      FirebaseMessaging.onMessage.map((message) => message.data);

  @override
  Future<String?> token() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } on Object catch (error) {
      debugPrint('weft: could not resolve a push token: $error');
      return null;
    }
  }

  @override
  Stream<String> get tokenRefreshes =>
      FirebaseMessaging.instance.onTokenRefresh;

  @override
  String get appId => kAndroidPushAppId;

  @override
  Future<void> release() async {
    try {
      await FirebaseMessaging.instance.deleteToken();
    } on Object catch (error) {
      debugPrint('weft: could not delete the push token: $error');
    }
  }
}

/// [PushTransport] over APNs directly, with no Firebase on iOS.
///
/// The token comes from `AppDelegate.swift` over `com.bostrot.weft/apns`, as
/// the hex string sygnal's `apns` pushkin addresses a device by. iOS shows the
/// pokes itself, through the notification service extension, so there is no
/// stream of them here: a running app is notified from sync.
class ApnsPushTransport implements PushTransport {
  ApnsPushTransport._(this._channel) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'tokenChanged' && call.arguments is String) {
        _refreshes.add(call.arguments as String);
      }
    });
  }

  final MethodChannel _channel;
  final _refreshes = StreamController<String>.broadcast();
  bool _sandbox = false;

  static Future<ApnsPushTransport?> initialize({
    MethodChannel channel = const MethodChannel('com.bostrot.weft/apns'),
  }) async {
    if (!NotificationPlatform.isIOS) return null;
    final transport = ApnsPushTransport._(channel);
    try {
      transport._sandbox =
          await channel.invokeMethod<String>('environment') == 'development';
    } on Object catch (error) {
      debugPrint('weft: APNs unavailable: $error');
      return null;
    }
    return transport;
  }

  @override
  Future<String?> token() async {
    try {
      // Null until iOS has answered the registration, which needs the
      // notification permission settled first; [tokenRefreshes] brings it.
      return await _channel.invokeMethod<String>('token');
    } on Object catch (error) {
      debugPrint('weft: could not resolve an APNs token: $error');
      return null;
    }
  }

  @override
  Stream<String> get tokenRefreshes => _refreshes.stream;

  @override
  Stream<Map<String, Object?>> get pushes => const Stream.empty();

  @override
  String get appId => _sandbox ? kIosSandboxPushAppId : kIosPushAppId;

  // Nothing to give back: an APNs token reaches nobody but Apple until a
  // pusher names it, and unregistering from APNs would also silence calls.
  @override
  Future<void> release() async {}
}

/// The transport this platform pushes over, or null.
Future<PushTransport?> initializePushTransport() async =>
    await FirebasePushTransport.initialize() ??
    await ApnsPushTransport.initialize();

/// What happened when Weft last tried to register for push.
///
/// An enum rather than a bool because every value here is a different sentence
/// in the settings screen, and three of them are not failures at all.
enum PushRegistrationStatus {
  /// The pusher was written to the homeserver.
  registered,

  /// The homeserver already had exactly this pusher. Nothing was written.
  unchanged,

  /// Desktop. There is no push here and none is wanted; sync does the work.
  unsupportedPlatform,

  /// No push gateway is configured. The user has to supply one.
  notConfigured,

  /// The user turned push off.
  off,

  /// Sennit's gateway has not been explained yet, so nothing is registered.
  undecided,

  /// The platform would not give a token yet. Ordinary on iOS immediately
  /// after launch; the refresh stream retries.
  noToken,

  /// The homeserver refused, or could not be reached.
  failed,
}

/// The result of a registration attempt, with the sentence to show for it.
@immutable
class PushRegistrationOutcome {
  const PushRegistrationOutcome(this.status, {this.message});

  final PushRegistrationStatus status;

  /// User-facing, already written for a settings screen. Null when there is
  /// nothing worth saying — a successful registration is not news.
  final String? message;

  bool get isRegistered =>
      status == PushRegistrationStatus.registered ||
      status == PushRegistrationStatus.unchanged;

  @override
  String toString() => 'PushRegistrationOutcome($status, $message)';
}

/// Registers this device's pusher on the homeserver, and keeps it registered.
///
/// The composition point between three things that each already exist: the
/// platform's token ([PushTransport]), the account's pusher list
/// ([MatrixPusherRegistry]), and the record of what this device registered last
/// time ([PushKeyStore]). It adds no protocol of its own — it exists so the
/// order of those three operations is written down once.
class WeftPushRegistration {
  WeftPushRegistration({
    required MatrixPusherRegistry registry,
    required PushKeyStore keyStore,
    required PushTransport? tokens,
    required Uri? gatewayUrl,
    PushGatewayMode? mode = PushGatewayMode.custom,
  }) : _registry = registry,
       _keyStore = keyStore,
       _tokens = tokens,
       _gatewayUrl = gatewayUrl,
       _mode = mode;

  final MatrixPusherRegistry _registry;
  final PushKeyStore _keyStore;
  final PushTransport? _tokens;
  final Uri? _gatewayUrl;
  final PushGatewayMode? _mode;

  StreamSubscription<String>? _refreshSub;

  /// Registers, or confirms the registration, and starts following token
  /// rotations.
  ///
  /// Idempotent and cheap to call again: `ensureRegistered` compares against
  /// what the server already has and writes nothing when they agree, so this
  /// can run on every launch without a round trip's worth of writes.
  Future<PushRegistrationOutcome> ensureRegistered() async {
    final tokens = _tokens;
    if (!NotificationPlatform.supportsPush || tokens == null) {
      return const PushRegistrationOutcome(
        PushRegistrationStatus.unsupportedPlatform,
      );
    }

    if (_mode == null) {
      return const PushRegistrationOutcome(PushRegistrationStatus.undecided);
    }
    if (_mode == PushGatewayMode.off) {
      // Off means off on the homeserver too: a pusher left behind would keep
      // the gateway poking this device.
      await unregister();
      await tokens.release();
      return const PushRegistrationOutcome(PushRegistrationStatus.off);
    }

    final gateway = _gatewayUrl;
    if (gateway == null) {
      return PushRegistrationOutcome(
        PushRegistrationStatus.notConfigured,
        message: weftPlatformL10n().pushNoGatewayDetail,
      );
    }

    final token = await tokens.token();
    if (token == null || token.isEmpty) {
      return PushRegistrationOutcome(
        PushRegistrationStatus.noToken,
        message: weftPlatformL10n().pushNoTokenDetail,
      );
    }

    _refreshSub ??= tokens.tokenRefreshes.listen((_) {
      // The new token is read back through `token()` rather than taken from
      // the event: on iOS the event carries the *FCM* token while the pusher
      // is keyed on the APNs one, and registering the wrong one produces a
      // pusher the gateway will happily poke and never reach.
      unawaited(ensureRegistered());
    });

    final pusher = pusherFor(
      token: token,
      gatewayUrl: gateway,
      appId: tokens.appId,
    );
    try {
      final wrote = await _registry.ensureRegistered(
        pusher,
        previousPushKey: _keyStore.readPushKey(),
      );
      _keyStore.writePushKey(token);
      return PushRegistrationOutcome(
        wrote
            ? PushRegistrationStatus.registered
            : PushRegistrationStatus.unchanged,
      );
    } on PusherRegistrationException catch (error) {
      return PushRegistrationOutcome(
        PushRegistrationStatus.failed,
        message: error.message,
      );
    }
  }

  /// Removes this device's pusher and forgets the key.
  ///
  /// Called on sign-out. Skipping it leaves the homeserver poking a device that
  /// is no longer signed in — harmless to the user who left, and a notification
  /// for the *next* account on the same phone if the gateway is slow to notice.
  Future<void> unregister() async {
    final key = _keyStore.readPushKey();
    if (key == null || key.isEmpty) return;
    try {
      await _registry.unregister(
        appId: _tokens?.appId ?? currentPushAppId,
        pushKey: key,
      );
    } on PusherRegistrationException catch (error) {
      debugPrint(
        'weft: could not remove this device\'s pusher: ${error.message}',
      );
    }
    _keyStore.writePushKey(null);
  }

  Future<void> dispose() async {
    await _refreshSub?.cancel();
    _refreshSub = null;
  }

  /// The pusher this device would register, given a token and a gateway.
  ///
  /// Separated out so the interesting half — the app id, the format, the
  /// per-platform default payload — is assertable without a homeserver or a
  /// Firebase app.
  static WeftPusher pusherFor({
    required String token,
    required Uri gatewayUrl,
    String? deviceName,
    String? appId,
  }) {
    final ios = NotificationPlatform.isIOS;
    return WeftPusher(
      appId: appId ?? (ios ? kIosPushAppId : kAndroidPushAppId),
      pushKey: token,
      gatewayUrl: gatewayUrl,
      deviceDisplayName: deviceName ?? 'Sennit',
      // `event_id_only` is set by `WeftPusher.toJson` and is not optional; see
      // `kEventIdOnlyFormat`. What varies per platform is only this.
      defaultPayload: ios ? kIosDefaultPayload : const {},
    );
  }

  static String get currentPushAppId =>
      NotificationPlatform.isIOS ? kIosPushAppId : kAndroidPushAppId;
}

/// The gateway URL as configured, or null when there is none.
///
/// Two sources, in order: a `--dart-define` for a build that ships pointed at a
/// known gateway, then the user's own setting, which wins because they are the
/// one who runs it. Anything unparseable, or without a scheme, reads as unset —
/// a half-typed URL must degrade to "no push" rather than to a pusher the
/// homeserver accepts and can never deliver to.
Uri? resolvePushGateway(String? configured) {
  const compiled = String.fromEnvironment('WEFT_PUSH_GATEWAY');
  final raw = (configured == null || configured.trim().isEmpty)
      ? compiled
      : configured.trim();
  if (raw.isEmpty) return null;

  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return uri;
}
