import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_call/weft_call.dart';

import '../../app/a11y.dart';
import '../../app/call_providers.dart';
import 'call_labels.dart';

/// Places a call and says so if it could not be placed.
///
/// Deliberately does *not* open the call screen: [CallOverlay] watches for a
/// call becoming live and opens it, so a call answered from a notification, a
/// call placed from the chat view and a call placed from anywhere added later
/// all reach the same screen by the same path. A button that pushed its own
/// route would be a second path, and the second path is the one that gets
/// forgotten when the first changes.
///
/// The awaited [CallService.placeCall] can take a moment on the very first
/// call — that is the operating system's microphone prompt — which is why the
/// failure it may return is worth showing rather than swallowing.
Future<void> startCall(
  BuildContext context,
  WidgetRef ref,
  CallTarget target, {
  bool video = false,
}) async {
  // A call that could not be placed is reported here and nowhere else: nothing
  // appears on screen, no call screen opens, and the button the user pressed
  // looks exactly as it did. A snackbar alone made that report to whoever
  // happened to be watching the bottom of the screen for four seconds.
  void say(String message) => showWeftMessage(context, message);

  final service = ref.read(callServiceProvider);
  if (service == null) {
    say('Calling needs a signed-in Matrix account.');
    return;
  }

  final failure = await service.placeCall(
    roomId: target.roomId,
    peer: target.peer,
    video: video,
  );
  if (failure != null) say(callStartFailureLabel(failure));
}
