import 'dart:async';
import 'dart:convert';

import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'package:weft_domain/weft_domain.dart' show Chat;
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/stores.dart';
import '../../data/matrix_chat_repository.dart';
import '../status/status_feed.dart' show isStatusBroadcastChat;
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

/// The session the current background process opened, for the daemon's
/// graceful stop.
WeftMatrixSession? _bootedSession;

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
