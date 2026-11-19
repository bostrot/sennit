import 'dart:async';
import 'dart:convert';

import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show NotificationResponse;
import 'package:unifiedpush/unifiedpush.dart';
import 'package:weft_domain/weft_domain.dart' show Chat;
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';

import '../../app/stores.dart';
import '../../data/matrix_chat_repository.dart';
import '../status/status_feed.dart' show isStatusBroadcastChat;
import 'background_actions.dart';
import 'notification_actions.dart';
import 'notification_service.dart';

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
}
