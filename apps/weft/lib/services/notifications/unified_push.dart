import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:unifiedpush/unifiedpush.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/notification_providers.dart';
import '../../app/session_providers.dart';
import '../../app/stores.dart';
import 'push_registration.dart';

/// Push that arrives while Weft is dead, without Google in the path.
///
/// A UnifiedPush distributor on the device — ntfy is the usual one — holds a
/// long-lived connection to the user's own push server and wakes Sennit with
/// the poke. Sennit registers the endpoint as an ordinary Matrix HTTP pusher,
/// pointed at the endpoint host's own Matrix gateway when it has one (ntfy
/// does) and at the public UnifiedPush gateway otherwise. The homeserver then
/// pokes the gateway, the gateway pokes the distributor, the distributor
/// wakes this service, and the notification below is posted — app running or
/// not.
///
/// The poke itself says almost nothing — for E2EE rooms the gateway only
/// ever sees an event id — but that is all the pipeline needs: the event is
/// fetched by id and decrypted *on this device*, so the posted notification
/// is the full sender-and-text MessagingStyle one, not a blind "new
/// message". With the app running that happens here; with the app dead the
/// plugin cold-starts the process and `background_push.dart` does the same
/// with a headless boot. The bare unread-count notification below survives
/// only as the last-resort fallback for a session that is not up.
class UnifiedPushService {
  UnifiedPushService(this._ref);

  final Ref _ref;

  static const String _endpointKey = 'push.up_endpoint';
  static const String _gatewayKey = 'push.up_gateway';

  String? get endpoint => storesOrNull(_ref)?.settings.getString(_endpointKey);

  bool get isConfigured => (endpoint ?? '').isNotEmpty;

  /// Wires the callbacks. Called once at startup, before anything registers —
  /// the plugin requires the handlers to exist by the time the distributor
  /// delivers, including deliveries that arrive with the app cold-started.
  Future<void> initialize() async {
    if (!NotificationPlatform.isAndroid) return;
    await UnifiedPush.initialize(
      onNewEndpoint: _onNewEndpoint,
      onRegistrationFailed: (reason, _) =>
          debugPrint('weft: UnifiedPush registration failed: $reason'),
      onUnregistered: (_) => _onUnregistered(),
      onMessage: _onMessage,
    );
  }

  /// Starts (or re-starts) a registration with the user's distributor.
  ///
  /// Returns null on success, or the sentence to show the user.
  Future<String?> register() async {
    final ok = await UnifiedPush.tryUseCurrentOrDefaultDistributor();
    if (!ok) {
      final distributors = await UnifiedPush.getDistributors();
      if (distributors.isEmpty) {
        return 'No UnifiedPush distributor is installed. Install ntfy from '
            'the Play Store or F-Droid, open it once, then try again.';
      }
    }
    await UnifiedPush.register();
    return null;
  }

  Future<void> unregister() async {
    await UnifiedPush.unregister();
    await _onUnregistered();
  }

  Future<void> _onNewEndpoint(PushEndpoint pushEndpoint, String _) async {
    final endpointUrl = pushEndpoint.url;
    final stores = storesOrNull(_ref);
    if (stores == null) return;

    // The gateway: the endpoint's own host when it runs a Matrix gateway
    // (ntfy answers the discovery probe), the public one otherwise.
    final gateway = await _resolveGateway(endpointUrl);
    stores.settings.setString(_endpointKey, endpointUrl);
    stores.settings.setString(_gatewayKey, gateway.toString());

    try {
      final session = _ref.read(matrixSessionProvider);
      final registry = MatrixPusherRegistry.forClient(session.client);
      await registry.register(
        WeftPusher(
          appId: kAndroidPushAppId,
          pushKey: endpointUrl,
          gatewayUrl: gateway,
          deviceDisplayName: 'Sennit (UnifiedPush)',
        ),
        append: false,
      );
      debugPrint('weft: UnifiedPush pusher registered via $gateway');
    } on Object catch (error) {
      debugPrint('weft: UnifiedPush pusher registration failed: $error');
    }
  }

  Future<Uri> _resolveGateway(String endpointUrl) async {
    final endpoint = Uri.parse(endpointUrl);
    final candidate = endpoint.replace(
      path: '/_matrix/push/v1/notify',
      query: null,
    );
    try {
      final response = await http
          .get(candidate)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map &&
            (decoded['unifiedpush'] as Map?)?['gateway'] == 'matrix') {
          return candidate;
        }
      }
    } on Object {
      // Fall through to the public gateway.
    }
    return Uri.parse(
      'https://matrix.gateway.unifiedpush.org'
      '/_matrix/push/v1/notify',
    );
  }

  Future<void> _onUnregistered() async {
    final stores = storesOrNull(_ref);
    final endpointUrl = stores?.settings.getString(_endpointKey);
    stores?.settings.remove(_endpointKey);
    stores?.settings.remove(_gatewayKey);
    if (endpointUrl == null) return;
    try {
      final session = _ref.read(matrixSessionProvider);
      await MatrixPusherRegistry.forClient(
        session.client,
      ).unregister(appId: kAndroidPushAppId, pushKey: endpointUrl);
    } on Object catch (error) {
      debugPrint('weft: UnifiedPush pusher removal failed: $error');
    }
  }

  /// A poke arrived while the app is running.
  ///
  /// (A poke that arrives with the app *dead* never reaches this instance —
  /// the plugin cold-starts the process with `--unifiedpush-bg` and
  /// `background_push.dart` answers it.)
  Future<void> _onMessage(PushMessage message, String _) async {
    Map<String, Object?>? data;
    Map<String, Object?>? notification;
    try {
      final decoded = jsonDecode(utf8.decode(message.content));
      if (decoded is Map) {
        data = decoded.cast<String, Object?>();
        final inner = decoded['notification'];
        if (inner is Map) notification = inner.cast<String, Object?>();
      }
    } on Object {
      // An undecodable poke still means "something happened".
    }

    // The full pipeline whenever the session is up: fetch the event by id,
    // decrypt it here, run the policy, post the same MessagingStyle
    // notification the sync path posts — deduped against it, so a message
    // arriving both ways buzzes once.
    if (data != null) {
      try {
        final service = await _ref.read(notificationServiceProvider.future);
        if (service != null) {
          await service.handlePush(data);
          return;
        }
      } on Object catch (error) {
        debugPrint('weft: push fell back to the bare notification: $error');
      }
    }

    final roomId = notification?['room_id'] as String?;
    final roomName = notification?['room_name'] as String?;
    final sender = notification?['sender_display_name'] as String?;
    final counts = notification?['counts'];
    final unread = counts is Map ? counts['unread'] : null;

    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await plugin.show(
      id: roomId?.hashCode ?? 0,
      title: roomName ?? sender ?? 'Sennit',
      body: unread is int && unread > 1
          ? '$unread new messages'
          : 'New message — open to read',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'weft.push',
          'Messages (push)',
          channelDescription:
              'Messages that arrived while Sennit was not running',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
        ),
      ),
      payload: roomId == null
          ? null
          : 'weft://chat/${Uri.encodeComponent(roomId)}',
    );
  }
}

final unifiedPushServiceProvider = Provider<UnifiedPushService>(
  UnifiedPushService.new,
);
