import 'sdp.dart';

/// How the peer connection is doing.
///
/// A flattening of WebRTC's `RTCPeerConnectionState` down to what the call
/// state machine acts on. `disconnected` is kept separate from `failed` on
/// purpose: the first is recoverable and routinely happens when a phone changes
/// network, and treating it as fatal ends calls that would have healed.
enum MediaConnectionState { connecting, connected, disconnected, failed, closed }

/// The seam between calling's decisions and calling's plumbing.
///
/// Everything below this interface is platform WebRTC — `flutter_webrtc`, a
/// microphone, a camera, a codec. Everything above it is [CallStateMachine],
/// which is why the whole of glare resolution, candidate ordering and
/// renegotiation can be tested in a second with a fake that returns canned SDP.
///
/// The interface is deliberately narrow. Anything that could be decided by the
/// state machine is *not* here — audio routing, ringtones, hold semantics — so
/// that the app's implementation stays a thin adapter with no branching of its
/// own to get wrong.
abstract interface class MediaEngine {
  /// Open local media if needed and produce an offer.
  Future<SessionDescription> createOffer({required bool video});

  /// Apply [remoteOffer] and produce the answer to it.
  ///
  /// Combined rather than split into apply-then-answer because WebRTC requires
  /// them in that order and a caller who reversed them would get a failure with
  /// no useful message.
  Future<SessionDescription> createAnswer(
    SessionDescription remoteOffer, {
    required bool video,
  });

  /// Apply a description that is not being answered — the far end's answer to
  /// our offer, or its answer to a renegotiation.
  ///
  /// Not in the phase's original list for this interface and added because the
  /// caller's side of an offer/answer exchange has no other way to finish it.
  Future<void> applyRemoteDescription(SessionDescription description);

  /// Add a remote ICE candidate. Ordering is the caller's responsibility; see
  /// [IceCandidateBuffer].
  Future<void> addCandidate(IceCandidate candidate);

  /// Mute or unmute the local microphone track.
  Future<void> setMute(bool muted);

  /// Enable or disable the local video track. Does not renegotiate — adding
  /// video to a call that was negotiated as audio-only needs a new offer, which
  /// the state machine asks for separately.
  Future<void> setVideo(bool enabled);

  /// Flip between front and rear cameras. A no-op where there is one camera.
  Future<void> switchCamera();

  /// Release the microphone, camera and peer connection.
  ///
  /// Must be safe to call twice: a call that ends by remote hangup while the
  /// user is pressing the red button disposes from two directions.
  Future<void> dispose();

  /// Locally gathered candidates, as they are trickled.
  Stream<IceCandidate> get localCandidates;

  /// Peer connection state changes.
  Stream<MediaConnectionState> get connectionState;

  /// What was negotiated, once it has been. Null before the answer is applied.
  CodecSummary? get negotiatedCodecs;
}
