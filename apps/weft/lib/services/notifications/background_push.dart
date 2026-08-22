import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/stores.dart';
import '../../data/matrix_chat_repository.dart';
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

/// The stack, booted once per background process and shared by every message
/// the process lives long enough to receive.
Future<WeftNotificationService?>? _boot;

Future<WeftNotificationService?> _service() => _boot ??= () async {
  try {
    final stores = await WeftStores.open();
    final session = WeftMatrixSession();
    final state = await session.initialize();
    if (state == WeftSessionState.loggedOut) return null;

    // No search store on purpose: a process that exists to post one
    // notification has no business running the embedding queue.
    final repository = MatrixChatRepository(
      session,
      store: stores.identity,
      settings: stores.settings,
    );
    final pipeline = MatrixNotificationPipeline(
      session: MatrixNotificationSession.forClient(session.client),
      chatForRoom: repository.chatForRoom,
      policy: () => NotificationPolicy.fromJson(
        stores.settings.getJson(WeftSettings.notifyPolicy),
      ),
    );
    final service = WeftNotificationService(
      sink: LocalNotificationSink(),
      pipeline: pipeline,
      chatForRoom: repository.chatForRoom,
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
