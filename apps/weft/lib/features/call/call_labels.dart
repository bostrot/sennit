import 'package:weft_call/weft_call.dart';

import '../../app/localisation.dart';

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
String callStatusLabel(
  AppL10n l10n,
  CallServiceState state, {
  required DateTime now,
}) {
  final session = state.session;
  if (session == null) return l10n.callStatusEnded;

  switch (session.state) {
    case CallState.idle:
      return '';
    case CallState.ringing:
      return session.videoEnabled
          ? l10n.callStatusIncomingVideo
          : l10n.callStatusIncoming;
    case CallState.outgoingRinging:
      return l10n.callStatusCalling;
    case CallState.connecting:
      return l10n.callStatusConnecting;
    case CallState.connected:
      // The reconnection grace is the one connection-quality signal a user can
      // act on, so it outranks the duration while it lasts. The timer keeps
      // running underneath: the call has not ended and charging the user a
      // reset would be a lie.
      if (state.reconnecting) return l10n.callStatusReconnecting;
      return formatCallDuration(session.durationAt(now)) ??
          l10n.callStatusConnected;
    case CallState.onHold:
      return l10n.callStatusOnHold;
    case CallState.ending:
      return l10n.callStatusEnding;
    case CallState.ended:
      return callEndLabel(
        l10n,
        session.endReason,
        isOutgoing: session.isOutgoing,
      );
  }
}

/// Why the call is over, as a sentence.
///
/// The wire cannot tell these apart — a hangup and a reject both carry
/// `user_hangup` — which is exactly why [CallEndReason] splits them and why
/// this is the only place that turns them into words.
String callEndLabel(
  AppL10n l10n,
  CallEndReason? reason, {
  required bool isOutgoing,
}) {
  switch (reason) {
    case null:
    case CallEndReason.userHangup:
    case CallEndReason.remoteHangup:
      return l10n.callStatusEnded;
    case CallEndReason.localReject:
      return l10n.callEndDeclined;
    case CallEndReason.remoteReject:
      return isOutgoing ? l10n.callEndTheyDeclined : l10n.callEndDeclined;
    case CallEndReason.userBusy:
      return isOutgoing ? l10n.callEndTheyAreBusy : l10n.callEndYouWereBusy;
    case CallEndReason.inviteTimeout:
      return isOutgoing ? l10n.callEndNoAnswer : l10n.callEndMissed;
    case CallEndReason.answeredElsewhere:
      return l10n.callEndAnsweredElsewhere;
    case CallEndReason.glareLost:
      // Both sides dialled at once and this one gave way. The other call is
      // still ringing, which is the only part the user needs to know.
      return l10n.callEndGlare;
    case CallEndReason.iceFailed:
      return l10n.callEndIceFailed;
    case CallEndReason.mediaFailed:
      return l10n.callEndMediaFailed;
    case CallEndReason.replaced:
      return l10n.callEndReplaced;
    case CallEndReason.unknownError:
      return l10n.callEndFailed;
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
String callStartFailureLabel(AppL10n l10n, CallStartFailure failure) =>
    switch (failure) {
      CallStartFailure.busy => l10n.callStartBusy,
      CallStartFailure.mediaUnavailable => l10n.callStartMediaUnavailable,
      CallStartFailure.signallingFailed => l10n.callStartSignallingFailed,
    };

/// What the audio-route button is currently doing.
String callAudioRouteLabel(AppL10n l10n, CallAudioRoute route) =>
    switch (route) {
      CallAudioRoute.earpiece => l10n.callAudioEarpiece,
      CallAudioRoute.speaker => l10n.callAudioSpeaker,
      CallAudioRoute.wiredHeadset => l10n.callAudioWiredHeadset,
      CallAudioRoute.bluetooth => l10n.callAudioBluetooth,
    };
