import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'dart:ui' show DartPluginRegistrant, IsolateNameServer;

import 'package:firebase_messaging/firebase_messaging.dart' show RemoteMessage;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show NotificationResponse;
import 'package:unifiedpush/unifiedpush.dart';
import 'package:weft_domain/weft_domain.dart' show Chat;
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/billing_providers.dart' show kProOwnershipSetting;
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';

import '../../app/stores.dart';
import '../../data/matrix_chat_repository.dart';
import '../billing/entitlements.dart';
import '../status/status_feed.dart' show isStatusBroadcastChat;
import 'background_actions.dart';
import 'notification_actions.dart';
import 'notification_service.dart';
import 'reply_suggester.dart';

/// The headless half of push.
///
/// When a poke arrives and Weft is not running, the UnifiedPush plugin starts
/// the Dart entrypoint with `--unifiedpush-bg` and delivers the message here
/// — no widgets, no `runApp`, no Riverpod. This module boots just enough of
/// the real stack to answer it properly: the stores, the Matrix client from
/// its own database (first sync included, which is what carries the room key
/// an encrypted event needs), the repository for the merge fold, and the same
/// notification pipeline the foreground uses. The result is the identical
/// MessagingStyle notification the user would have gotten with the app open —
/// fetched by event id and decrypted on this device — rather than a blind
/// "new message".
///
/// This is the shape every self-hosted Matrix client has converged on: the
/// OS forbids each app holding its own connection, so ntfy holds the one
/// connection for the whole phone and wakes Weft for seconds at a time. The
/// process is expendable — the OS reaps it when the work is done, and the
/// next poke starts a fresh one.
Future<void> runBackgroundPush() async {
  await UnifiedPush.initialize(
    // Registration belongs to the foreground app; a background process that
    // rewired the pusher on its own would race the settings screen.
    onNewEndpoint: (_, _) async {},
    onRegistrationFailed: (reason, _) async =>
        debugPrint('weft: background push registration failed: $reason'),
    onUnregistered: (_) async {},
    onMessage: _onMessage,
  );
}

/// An FCM poke that arrived with no UI in front — Sennit's gateway, on a
/// store build.
///
/// The plugin runs this in an isolate of its own whether or not the app's
/// process is alive. When it is (the app is in the background, or the daemon
/// runs) the poke is handed to the isolate holding the client, exactly as a
/// notification action is; only a cold start boots the headless stack, the
/// same one UnifiedPush uses.
@pragma('vm:entry-point')
Future<void> runFirebaseBackgroundPush(RemoteMessage message) async {
  final data = Map<String, Object?>.from(message.data);
  if (data.isEmpty) return;
  if (await forwardPush(data)) return;

  final service = await _service();
  if (service == null) return;
  await service.handlePush(data);
  await Future<void>.delayed(const Duration(seconds: 3));
  await service.chipsSettled();
}

/// The name an isolate with a live client takes pokes under; see
/// [kNotificationActionPortName] for why a second client must never open.
const String kPushPortName = 'weft.push';

/// Takes pokes forwarded by [forwardPush] and hands them to [handle].
ReceivePort servePushes(
  Future<void> Function(Map<String, Object?> data) handle, {
  String name = kPushPortName,
}) {
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(name);
  IsolateNameServer.registerPortWithName(port.sendPort, name);
  port.listen((message) {
    if (message is! List || message.length != 2) return;
    final reply = message[1];
    if (reply is SendPort) reply.send(true);
    final decoded = message[0] is String
        ? jsonDecode(message[0] as String)
        : null;
    if (decoded is! Map) return;
    unawaited(
      handle(decoded.cast<String, Object?>()).catchError(
        (Object error) => debugPrint('weft: a forwarded push failed: $error'),
      ),
    );
  });
  return port;
}

/// Hands [data] to the isolate serving [name]; false when nobody took it.
Future<bool> forwardPush(
  Map<String, Object?> data, {
  String name = kPushPortName,
  Duration acceptWithin = const Duration(seconds: 2),
}) async {
  final target = IsolateNameServer.lookupPortByName(name);
  if (target == null) return false;
  final replies = ReceivePort();
  try {
    target.send([jsonEncode(data), replies.sendPort]);
    return await replies.first.timeout(acceptWithin, onTimeout: () => false) ==
        true;
  } finally {
    replies.close();
  }
}

/// The daemon: the same headless stack, kept alive on purpose.
///
/// This is the entrypoint the built-in connection runs — `WeftSyncService`
/// hosts a headless engine started with `--weft-daemon` whenever no UI
/// engine is alive. Booting the stack starts the Matrix sync loop, and the
/// pipeline's sync path posts a full notification for every message from
/// then on; there is nothing more to do than stay alive. The `stop` method
/// is the handover: the activity is starting a real client against the same
/// database, so this one closes first.
Future<void> runSyncDaemon() async {
  const channel = MethodChannel('com.bostrot.weft/daemon');
  channel.setMethodCallHandler((call) async {
    if (call.method != 'stop') return null;
    final session = _bootedSession;
    _bootedSession = null;
    try {
      await session?.client.dispose();
    } on Object catch (error) {
      debugPrint('weft: daemon client did not close cleanly: $error');
    }
    return true;
  });
  await _service();
  // Alive until the platform destroys the engine.
  await Completer<void>().future;
}

/// A notification action that arrived with no UI to deliver it to.
///
/// `flutter_local_notifications` starts this in an engine of its own for every
/// action that does not open the app: on Android the reply and mark-read
/// buttons — the only two Android Auto and Wear can use — and on iOS every
/// action without the foreground option, which is how a reply typed under a
/// banner or a "Mark read" from the lock screen arrives.
///
/// The work is the same [NotificationActionHandler] the UI uses. What differs
/// is whose client it runs on: the UI isolate's or the daemon's when either is
/// alive in this process ([forwardNotificationAction]), and a headless boot of
/// its own only when neither is — never a second client beside a live one.
/// Nothing new leaves the device: the reply and the read receipt go to the
/// user's own homeserver, exactly as the composer would send them.
@pragma('vm:entry-point')
Future<void> runBackgroundNotificationAction(
  NotificationResponse response,
) async {
  final activation = LocalNotificationSink.activationFor(response);
  if (activation == null || activation.isTap) return;

  if (await forwardNotificationAction(activation) != null) return;

  await _service();
  final actions = _bootedActions;
  if (actions == null) return;
  final result = await actions.handle(activation);
  debugPrint('weft: background notification action: ${result.name}');
}

/// The session the current background process opened, for the daemon's
/// graceful stop.
WeftMatrixSession? _bootedSession;

/// The action handler over the booted stack's client; null until it is up.
NotificationActionHandler? _bootedActions;

/// The stack, booted once per background process and shared by every message
/// the process lives long enough to receive.
Future<WeftNotificationService?>? _boot;

Future<WeftNotificationService?> _service() => _boot ??= () async {
  try {
    DartPluginRegistrant.ensureInitialized();
    final stores = await WeftStores.open();
    final session = WeftMatrixSession();
    _bootedSession = session;
    final state = await session.initialize();
    if (state == WeftSessionState.loggedOut) return null;

    // No search store on purpose: a process that exists to post one
    // notification has no business running the embedding queue.
    final repository = MatrixChatRepository(
      session,
      store: stores.identity,
      settings: stores.settings,
    );
    // Same rule as the foreground pipeline: a status broadcast never buzzes.
    Chat? chatForRoom(String roomId) {
      final chat = repository.chatForRoom(roomId);
      if (chat == null || isStatusBroadcastChat(chat)) return null;
      return chat;
    }

    final pipeline = MatrixNotificationPipeline(
      words: () => weftNotifyStringsFrom(weftPlatformL10n()),
      session: MatrixNotificationSession.forClient(session.client),
      chatForRoom: chatForRoom,
      policy: () => NotificationPolicy.fromJson(
        stores.settings.getJson(WeftSettings.notifyPolicy),
      ),
    );
    final service = WeftNotificationService(
      sink: LocalNotificationSink(),
      pipeline: pipeline,
      chatForRoom: chatForRoom,
    );
    // The same chips the UI engine adds, posted the same way — now, then
    // updated — under the same settings and budgets. On a phone without
    // Google services this boot is what posts nearly every notification, and
    // it used to post them all without chips. No calendar and no notes: both
    // live in the UI engine's providers.
    service.suggestReplies = notificationReplySuggester(
      settings: () => stores.settings,
      apiKey: () => stores.llmApiKey,
      proUnlocked: () => ProStatus(
        edition: SennitEdition.current,
        storeBillingPlatform:
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS,
        ownership: ProOwnership.fromJson(
          stores.settings.getJson(kProOwnershipSetting),
        ),
      ).unlocks(ProFeature.aiReplies),
      serviceChatIds: () => repository.serviceChatIds,
    );
    // Actions are served from here too: a reply sent from the car while the
    // daemon is running goes out on the daemon's client, not on a second one.
    final actions = NotificationActionHandler(
      repository: repository,
      // The policy notifier lives in the UI isolate; with no UI, the timed
      // mute is written where it will read it back from.
      muteChat: (chatId, {DateTime? until}) => stores.settings.setJson(
        WeftSettings.notifyPolicy,
        NotificationPolicy.fromJson(
          stores.settings.getJson(WeftSettings.notifyPolicy),
        ).muteChat(chatId, until: until).toJson(),
      ),
      dismiss: service.dismissChat,
    );
    _bootedActions = actions;
    NotificationActionServer.serve(actions.handle);
    servePushes(service.handlePush);
    await service.start();
    return service;
  } on Object catch (error) {
    debugPrint('weft: background push boot failed: $error');
    return null;
  }
}();

Future<void> _onMessage(PushMessage message, String _) async {
  Map<String, Object?>? data;
  try {
    final decoded = jsonDecode(utf8.decode(message.content));
    if (decoded is Map) data = decoded.cast<String, Object?>();
  } on Object {
    // Not JSON. Nothing below can act on it.
  }
  if (data == null) return;

  final service = await _service();
  if (service == null) return;
  await service.handlePush(data);
  // Posting runs through the service's queue and several plugin calls; give
  // it a beat before the platform decides the wake-up is over.
  await Future<void>.delayed(const Duration(seconds: 3));
  // Then the chips: the notification is already up, and this process is
  // reaped once the handler returns. The service gives up on them after its
  // own cap, so this is bounded by it.
  await service.chipsSettled();
}
