import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';

import 'notification_actions.dart';
import 'notification_presentation.dart';
import 'notification_service.dart';

/// The name an isolate that holds a live Matrix client serves notification
/// actions under.
///
/// Reply and mark read are delivered *headless* — Android Auto and Wear only
/// offer an action that does not open the phone's screen, and iOS runs a
/// non-foreground action in a background engine — so the plugin hands them to
/// a fresh isolate in a fresh Flutter engine. That isolate has no client of its
/// own, and opening a second one against the database the app (or the sync
/// daemon) already holds open is the one thing that must not happen: two
/// clients on one Olm store advance the same ratchets behind each other's
/// backs. So the background isolate asks first, through this name, whether
/// someone in the process already has a client, and only boots its own when
/// nobody answers.
///
/// One name per process, last registrant wins: the UI isolate and the daemon
/// never run a client at the same time — the daemon stops when the activity
/// starts — and whichever booted most recently is the one alive.
const String kNotificationActionPortName = 'weft.notification_actions';

/// Performs one action; [NotificationActionHandler.handle], as a function.
typedef NotificationActionPerformer =
    Future<NotificationActionResult> Function(NotificationActivation);

/// The shape an activation crosses an isolate boundary in. A port carries
/// primitives, and the payload already has a string form that survives a cold
/// start, so it is reused rather than given a second encoding.
@visibleForTesting
Map<String, Object?> encodeActivation(NotificationActivation activation) => {
  'payload': activation.payload.encode(),
  'actionId': activation.actionId,
  'input': activation.input,
};

@visibleForTesting
NotificationActivation? decodeActivation(Object? raw) {
  if (raw is! Map) return null;
  final payload = NotificationPayload.decode(raw['payload'] as String?);
  if (payload == null) return null;
  return NotificationActivation(
    payload: payload,
    actionId: raw['actionId'] as String?,
    input: raw['input'] as String?,
  );
}

/// The live side: an isolate with a client, taking actions from the
/// background isolate the plugin started.
class NotificationActionServer {
  NotificationActionServer._(this._name, this._port);

  /// Registers [perform] under [name], replacing whoever held it.
  factory NotificationActionServer.serve(
    NotificationActionPerformer perform, {
    String name = kNotificationActionPortName,
  }) {
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(name);
    IsolateNameServer.registerPortWithName(port.sendPort, name);
    final server = NotificationActionServer._(name, port);
    port.listen((message) {
      if (message is! List || message.length != 2) return;
      final reply = message[1];
      if (reply is! SendPort) return;
      // Accepted before the work starts, so the caller can tell "nobody is
      // here" from "somebody is sending, slowly" — the second must not be
      // answered by booting a second client and sending the reply twice.
      reply.send(_accepted);
      final activation = decodeActivation(message[0]);
      if (activation == null) {
        reply.send(NotificationActionResult.ignored.name);
        return;
      }
      unawaited(
        perform(activation).then(
          (result) => reply.send(result.name),
          onError: (Object error) {
            debugPrint('weft: a forwarded notification action threw: $error');
            reply.send(NotificationActionResult.failed.name);
          },
        ),
      );
    });
    return server;
  }

  final String _name;
  final ReceivePort _port;

  void close() {
    IsolateNameServer.removePortNameMapping(_name);
    _port.close();
  }
}

const String _accepted = 'accepted';

/// Hands [activation] to the isolate serving [name], if one is alive.
///
/// Null means nobody took it — no isolate registered, or a registration left
/// behind by one that has since died, which a port lookup cannot tell apart
/// from a live one until it fails to answer within [acceptWithin]. The caller
/// then does the work itself. Once accepted, the answer is the server's: a
/// result that does not arrive within [finishWithin] reads as
/// [NotificationActionResult.failed], never as a cue to try again, because
/// the reply may well have gone.
Future<NotificationActionResult?> forwardNotificationAction(
  NotificationActivation activation, {
  String name = kNotificationActionPortName,
  Duration acceptWithin = const Duration(seconds: 2),
  Duration finishWithin = const Duration(seconds: 60),
}) async {
  final target = IsolateNameServer.lookupPortByName(name);
  if (target == null) return null;

  final replies = ReceivePort();
  final answers = StreamIterator<Object?>(replies);
  try {
    target.send([encodeActivation(activation), replies.sendPort]);
    final accepted = await answers.moveNext().timeout(
      acceptWithin,
      onTimeout: () => false,
    );
    if (!accepted || answers.current != _accepted) return null;

    final finished = await answers.moveNext().timeout(
      finishWithin,
      onTimeout: () => false,
    );
    if (!finished) return NotificationActionResult.failed;
    return NotificationActionResult.values.asNameMap()[answers.current] ??
        NotificationActionResult.failed;
  } finally {
    replies.close();
    unawaited(answers.cancel());
  }
}
