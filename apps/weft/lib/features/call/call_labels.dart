import 'package:weft_call/weft_call.dart';

import '../../services/call/call_audio.dart';
import '../../services/call/call_service.dart';

/// Every sentence a call puts on screen, in one place and with no widget around
/// it.
///
/// Separate from the screens because these are the part of the call UI worth
/// asserting on: a golden proves a layout, and none of them proves that a call
/// nobody answered says "No answer" rather than "Call failed". They are also
/// read by three surfaces — the call screen, the incoming sheet and the
/// minimised bar — which must not describe the same call differently.

/// The line under the peer's name: what the call is doing right now.
///
/// [now] is passed rather than read from the clock so a caller that is already
/// ticking once a second does not read the clock twice per frame, and so a
/// golden can pin a duration.
String callStatusLabel(CallServiceState state, {required DateTime now}) {
  final session = state.session;
  if (session == null) return 'Call ended';

  switch (session.state) {
    case CallState.idle:
      return '';
    case CallState.ringing:
      return session.videoEnabled ? 'Incoming video call' : 'Incoming call';
    case CallState.outgoingRinging:
      return 'Calling…';
    case CallState.connecting:
      return 'Connecting…';
    case CallState.connected:
      // The reconnection grace is the one connection-quality signal a user can
      // act on, so it outranks the duration while it lasts. The timer keeps
      // running underneath: the call has not ended and charging the user a
      // reset would be a lie.
      if (state.reconnecting) return 'Reconnecting…';
      return formatCallDuration(session.durationAt(now)) ?? 'Connected';
    case CallState.onHold:
      return 'On hold';
    case CallState.ending:
      return 'Ending…';
    case CallState.ended:
      return callEndLabel(session.endReason, isOutgoing: session.isOutgoing);
  }
}

/// Why the call is over, as a sentence.
///
/// The wire cannot tell these apart — a hangup and a reject both carry
/// `user_hangup` — which is exactly why [CallEndReason] splits them and why
/// this is the only place that turns them into words.
String callEndLabel(CallEndReason? reason, {required bool isOutgoing}) {
  switch (reason) {
    case null:
    case CallEndReason.userHangup:
    case CallEndReason.remoteHangup:
      return 'Call ended';
    case CallEndReason.localReject:
      return 'Call declined';
    case CallEndReason.remoteReject:
      return isOutgoing ? 'They declined' : 'Call declined';
    case CallEndReason.userBusy:
      return isOutgoing
          ? 'They are on another call'
          : 'Declined — you were busy';
    case CallEndReason.inviteTimeout:
      return isOutgoing ? 'No answer' : 'Missed call';
    case CallEndReason.answeredElsewhere:
      return 'Answered on another device';
    case CallEndReason.glareLost:
      // Both sides dialled at once and this one gave way. The other call is
      // still ringing, which is the only part the user needs to know.
      return 'Your calls crossed';
    case CallEndReason.iceFailed:
      return 'Could not connect';
    case CallEndReason.mediaFailed:
      return 'Microphone or camera unavailable';
    case CallEndReason.replaced:
      return 'Call transferred';
    case CallEndReason.unknownError:
      return 'Call failed';
  }
}

/// `0:07`, `12:30`, `1:02:03`. Null when media has never flowed, because a call
/// that never connected has no duration to show — and showing `0:00` for a
/// minute of ringing is how a user concludes the timer is broken.
String? formatCallDuration(Duration? duration) {
  if (duration == null) return null;
  final total = duration.isNegative ? Duration.zero : duration;
  final seconds = total.inSeconds % 60;
  final minutes = total.inMinutes % 60;
  final hours = total.inHours;
  final mm = hours > 0 ? minutes.toString().padLeft(2, '0') : '$minutes';
  return '${hours > 0 ? '$hours:' : ''}$mm:${seconds.toString().padLeft(2, '0')}';
}

/// Why a call could not be placed, next to the button that was pressed.
String callStartFailureLabel(CallStartFailure failure) => switch (failure) {
  CallStartFailure.busy => 'You are already on a call.',
  CallStartFailure.mediaUnavailable =>
    'Weft could not open your microphone or camera.',
  CallStartFailure.signallingFailed => 'The call could not be sent.',
};

/// What the audio-route button is currently doing.
String callAudioRouteLabel(CallAudioRoute route) => switch (route) {
  CallAudioRoute.earpiece => 'Receiver',
  CallAudioRoute.speaker => 'Speaker',
  CallAudioRoute.wiredHeadset => 'Headphones',
  CallAudioRoute.bluetooth => 'Bluetooth',
};
