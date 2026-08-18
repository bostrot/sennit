import 'package:meta/meta.dart';

import 'call_session.dart';
import 'call_state.dart';
import 'sdp.dart';

/// Anything the state machine can be fed.
///
/// Two branches, and the split is the architecture: a [CallSignal] arrived from
/// the far end over Matrix, a [CallAction] happened on this device. Everything
/// that can move a call is one of the two, which is what makes the machine's
/// `switch` exhaustive and its behaviour enumerable in a test.
sealed class CallInput {
  const CallInput();
}

// ---------------------------------------------------------------------------
// Inbound: `m.call.*` events, already parsed.
// ---------------------------------------------------------------------------

/// An `m.call.*` event from the far end.
///
/// Deliberately parsed rather than a raw `Map`: the state machine must never
/// have to guess whether a key is missing or the wrong type, and the mapping
/// from event JSON lives in `weft_matrix`'s signalling layer where the SDK's
/// types already are.
sealed class CallSignal extends CallInput {
  const CallSignal({
    required this.callId,
    required this.partyId,
    required this.senderId,
  });

  /// `call_id`.
  final String callId;

  /// `party_id` of the *sender*. Absent in version 0 clients, where the
  /// signalling layer substitutes the sender's device id or an empty string.
  final String partyId;

  /// Matrix user id of the sender.
  final String senderId;
}

/// `m.call.invite`.
@immutable
class CallInviteSignal extends CallSignal {
  const CallInviteSignal({
    required super.callId,
    required super.partyId,
    required super.senderId,
    required this.roomId,
    required this.offer,
    required this.sentAt,
    this.lifetime = kDefaultInviteLifetime,
    this.video = false,
    this.invitee,
    this.version = '1',
  });

  final String roomId;
  final SessionDescription offer;

  /// Origin timestamp of the event, not the time it was received. An invite
  /// that sat in a sync backlog for two minutes must not ring.
  final DateTime sentAt;

  /// How long the caller will wait, from [sentAt].
  final Duration lifetime;

  /// Whether the caller offered video.
  final bool video;

  /// `invitee`, when the caller addressed one specific user. An invite naming
  /// somebody else is not ours to answer.
  final String? invitee;

  /// `version`. MSC2746 is `'1'`; `'0'` is the pre-MSC dialect still emitted by
  /// old clients.
  final String version;
}

/// `m.call.answer`.
@immutable
class CallAnswerSignal extends CallSignal {
  const CallAnswerSignal({
    required super.callId,
    required super.partyId,
    required super.senderId,
    required this.answer,
    this.video = false,
  });

  final SessionDescription answer;

  /// Whether the answering side included video.
  final bool video;
}

/// `m.call.candidates`.
@immutable
class CallCandidatesSignal extends CallSignal {
  const CallCandidatesSignal({
    required super.callId,
    required super.partyId,
    required super.senderId,
    required this.candidates,
  });

  final List<IceCandidate> candidates;
}

/// `m.call.select_answer`.
///
/// Sent by the caller once it has picked one of possibly several answering
/// devices. Every party except [selectedPartyId] must stop.
@immutable
class CallSelectAnswerSignal extends CallSignal {
  const CallSelectAnswerSignal({
    required super.callId,
    required super.partyId,
    required super.senderId,
    required this.selectedPartyId,
  });

  final String selectedPartyId;
}

/// `m.call.hangup`.
@immutable
class CallHangupSignal extends CallSignal {
  const CallHangupSignal({
    required super.callId,
    required super.partyId,
    required super.senderId,
    this.reason,
  });

  /// The raw `reason` string, interpreted by [CallEndReason.fromWire].
  final String? reason;
}

/// `m.call.reject`.
@immutable
class CallRejectSignal extends CallSignal {
  const CallRejectSignal({
    required super.callId,
    required super.partyId,
    required super.senderId,
    this.reason,
  });

  final String? reason;
}

/// `m.call.negotiate` — mid-call renegotiation, e.g. adding video.
@immutable
class CallNegotiateSignal extends CallSignal {
  const CallNegotiateSignal({
    required super.callId,
    required super.partyId,
    required super.senderId,
    required this.description,
    this.video = false,
  });

  /// An offer from the far end, or the answer to one of ours.
  final SessionDescription description;

  /// Whether the renegotiated session carries video.
  final bool video;
}

// ---------------------------------------------------------------------------
// Inbound: things that happened on this device.
// ---------------------------------------------------------------------------

/// Something the user or the media engine did locally.
sealed class CallAction extends CallInput {
  const CallAction();
}

/// Start an outgoing call.
@immutable
class PlaceCall extends CallAction {
  const PlaceCall({
    required this.callId,
    required this.roomId,
    required this.peer,
    this.video = false,
  });

  /// Generated by the caller. Must be unique per call; glare resolution
  /// compares it lexically against the far end's, so it also has to be
  /// something with enough entropy that two simultaneous calls never tie.
  final String callId;

  final String roomId;
  final CallPeer peer;
  final bool video;
}

/// Answer a ringing call.
@immutable
class AcceptCall extends CallAction {
  const AcceptCall({this.video});

  /// Answer with video. Defaults to whatever the caller offered — answering a
  /// video call with audio only is a deliberate choice, not the default.
  final bool? video;
}

/// Decline a ringing call. Sends `m.call.reject`.
@immutable
class DeclineCall extends CallAction {
  const DeclineCall();
}

/// End an outgoing or established call. Sends `m.call.hangup`.
@immutable
class HangUp extends CallAction {
  const HangUp({this.reason = CallEndReason.userHangup});

  final CallEndReason reason;
}

/// Mute or unmute the microphone.
@immutable
class SetMuted extends CallAction {
  const SetMuted(this.muted);

  final bool muted;
}

/// Route audio to the loudspeaker or back. Recorded on the session only; the
/// app performs the routing.
@immutable
class SetSpeaker extends CallAction {
  const SetSpeaker(this.speakerOn);

  final bool speakerOn;
}

/// Turn the local camera on or off within an existing video call. Does not
/// renegotiate — use [RequestVideoUpgrade] for that.
@immutable
class SetCameraEnabled extends CallAction {
  const SetCameraEnabled(this.enabled);

  final bool enabled;
}

/// Flip between front and rear cameras.
@immutable
class SwitchCamera extends CallAction {
  const SwitchCamera();
}

/// Ask to upgrade a voice call to video, or to put a video call back to audio.
@immutable
class RequestVideoUpgrade extends CallAction {
  const RequestVideoUpgrade({this.video = true});

  final bool video;
}

/// Suspend or resume the call.
@immutable
class SetHold extends CallAction {
  const SetHold(this.onHold);

  final bool onHold;
}

/// The media engine finished producing a local offer or answer.
@immutable
class LocalDescriptionReady extends CallAction {
  const LocalDescriptionReady(this.description);

  final SessionDescription description;
}

/// The media engine gathered a local ICE candidate.
@immutable
class LocalCandidate extends CallAction {
  const LocalCandidate(this.candidate);

  final IceCandidate candidate;
}

/// Media is flowing.
@immutable
class MediaConnected extends CallAction {
  const MediaConnected({this.codecs});

  final CodecSummary? codecs;
}

/// The peer connection failed. Almost always ICE, and almost always TURN.
@immutable
class MediaFailed extends CallAction {
  const MediaFailed({this.reason = CallEndReason.iceFailed});

  final CallEndReason reason;
}

/// A renegotiation did not complete.
///
/// Its whole purpose is that it is *not* fatal: the call carries on with
/// whatever was already negotiated, which for the audio-to-video case means the
/// user keeps talking and the video button goes back to off.
@immutable
class NegotiationFailed extends CallAction {
  const NegotiationFailed();
}

/// The media engine has finished tearing down. Completes [CallState.ending].
@immutable
class MediaDisposed extends CallAction {
  const MediaDisposed();
}

/// Advance time. The only thing that can expire an invite.
///
/// Passing time in rather than reading a clock inside the machine is what lets
/// a sixty-second timeout be tested in a microsecond.
@immutable
class Tick extends CallAction {
  const Tick();
}

// ---------------------------------------------------------------------------
// Outbound.
// ---------------------------------------------------------------------------

/// Something the state machine wants done as a result of an input.
///
/// The machine performs no I/O of its own. It says what should happen and the
/// call service does it, which is why the whole of calling's decision-making
/// can be asserted on without a socket or a microphone.
sealed class CallIntent {
  const CallIntent();
}

/// An event to put on the Matrix wire.
sealed class SignallingIntent extends CallIntent {
  const SignallingIntent({required this.callId, required this.partyId});

  final String callId;

  /// Our own `party_id`, stamped on every outgoing event.
  final String partyId;
}

/// Send `m.call.invite`.
@immutable
class SendInvite extends SignallingIntent {
  const SendInvite({
    required super.callId,
    required super.partyId,
    required this.roomId,
    required this.offer,
    required this.lifetime,
    required this.video,
  });

  final String roomId;
  final SessionDescription offer;
  final Duration lifetime;
  final bool video;
}

/// Send `m.call.answer`.
@immutable
class SendAnswer extends SignallingIntent {
  const SendAnswer({
    required super.callId,
    required super.partyId,
    required this.answer,
    required this.video,
  });

  final SessionDescription answer;
  final bool video;
}

/// Send `m.call.candidates`.
@immutable
class SendCandidates extends SignallingIntent {
  const SendCandidates({
    required super.callId,
    required super.partyId,
    required this.candidates,
  });

  final List<IceCandidate> candidates;
}

/// Send `m.call.select_answer`, committing to one answering device.
@immutable
class SendSelectAnswer extends SignallingIntent {
  const SendSelectAnswer({
    required super.callId,
    required super.partyId,
    required this.selectedPartyId,
  });

  final String selectedPartyId;
}

/// Send `m.call.hangup`.
@immutable
class SendHangup extends SignallingIntent {
  const SendHangup({
    required super.callId,
    required super.partyId,
    required this.reason,
  });

  final CallEndReason reason;
}

/// Send `m.call.reject`.
@immutable
class SendReject extends SignallingIntent {
  const SendReject({
    required super.callId,
    required super.partyId,
    required this.reason,
  });

  final CallEndReason reason;
}

/// Send `m.call.negotiate`.
@immutable
class SendNegotiate extends SignallingIntent {
  const SendNegotiate({
    required super.callId,
    required super.partyId,
    required this.description,
    required this.lifetime,
    required this.video,
  });

  final SessionDescription description;
  final Duration lifetime;
  final bool video;
}

/// Something for the media engine to do.
sealed class MediaIntent extends CallIntent {
  const MediaIntent();
}

/// Call `MediaEngine.createOffer`.
@immutable
class CreateOffer extends MediaIntent {
  const CreateOffer({required this.video});

  final bool video;
}

/// Call `MediaEngine.createAnswer` with the remote offer.
@immutable
class CreateAnswer extends MediaIntent {
  const CreateAnswer({required this.remoteOffer, required this.video});

  final SessionDescription remoteOffer;
  final bool video;
}

/// Call `MediaEngine.applyRemoteDescription`.
@immutable
class ApplyRemoteDescription extends MediaIntent {
  const ApplyRemoteDescription(this.description);

  final SessionDescription description;
}

/// Call `MediaEngine.addCandidate`. One intent per candidate, so a single
/// malformed candidate cannot take a whole batch down with it.
@immutable
class AddRemoteCandidate extends MediaIntent {
  const AddRemoteCandidate(this.candidate);

  final IceCandidate candidate;
}

/// Call `MediaEngine.setMute`.
@immutable
class ApplyMute extends MediaIntent {
  const ApplyMute(this.muted);

  final bool muted;
}

/// Call `MediaEngine.setVideo`.
@immutable
class ApplyVideo extends MediaIntent {
  const ApplyVideo(this.enabled);

  final bool enabled;
}

/// Call `MediaEngine.switchCamera`.
@immutable
class ApplySwitchCamera extends MediaIntent {
  const ApplySwitchCamera();
}

/// Call `MediaEngine.dispose`, then feed back [MediaDisposed].
@immutable
class DisposeMedia extends MediaIntent {
  const DisposeMedia();
}

/// MSC2746's default `lifetime` for an invite: how long a phone rings.
const Duration kDefaultInviteLifetime = Duration(seconds: 60);

/// MSC2746's default lifetime for every other call event, including
/// `m.call.negotiate`.
const Duration kDefaultCallEventLifetime = Duration(seconds: 10);
