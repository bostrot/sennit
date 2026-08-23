import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:weft_call/weft_call.dart';

import 'call_video.dart';
import 'sdp_codecs.dart';

/// Opens a peer connection. Injected so the engine can be built in a test
/// without a platform channel behind it.
typedef PeerConnectionFactory =
    Future<rtc.RTCPeerConnection> Function(Map<String, dynamic> configuration);

/// Opens the microphone and, when asked, the camera.
typedef UserMediaFactory =
    Future<rtc.MediaStream> Function(Map<String, dynamic> constraints);

/// `weft_call`'s [MediaEngine], over `flutter_webrtc`.
///
/// **This is the only file in Braid that talks to WebRTC.** Everything a call
/// decides — which of two crossed invites survives, whether an early candidate
/// is applied or buffered, whether a failed video upgrade takes the call with
/// it — is in `weft_call` above this interface, tested without a microphone.
/// What is left here is plumbing, and it is written to have as few decisions in
/// it as possible: the one real judgement, reading the negotiated codecs out of
/// an answer, lives in [codecSummaryFromSdp] where a test can reach it.
///
/// Two behaviours are worth knowing because they are visible to the far end:
///
///  * **Turning the camera off stops the capture, it does not merely mute the
///    track.** A disabled track leaves the camera light on, which is a promise
///    broken rather than a cosmetic difference. The sender is kept and its
///    track replaced, so turning the camera back on does not need a
///    renegotiation.
///  * **End-of-candidates is forwarded.** MSC2746 requires it and dropping it
///    makes the far end wait out its own ICE timeout instead of failing over.
///    `flutter_webrtc` signals it with an empty candidate string, and
///    [IceCandidate.isEndOfCandidates] is the same sentinel, so it passes
///    straight through.
class WebRTCMediaEngine implements MediaEngine, CallVideoSource {
  WebRTCMediaEngine({
    List<Map<String, Object?>> iceServers = const [],
    PeerConnectionFactory? peerConnections,
    UserMediaFactory? userMedia,
  }) : _iceServers = iceServers,
       _peerConnections = peerConnections ?? rtc.createPeerConnection,
       _userMedia =
           userMedia ??
           ((constraints) =>
               rtc.navigator.mediaDevices.getUserMedia(constraints));

  /// `iceServers`, as [IceConfiguration.servers] produced them.
  ///
  /// Empty is a supported configuration and not an error: it means the
  /// homeserver offers no relay, the call may still connect on one network, and
  /// the warning that says so is the call service's to show.
  final List<Map<String, Object?>> _iceServers;

  final PeerConnectionFactory _peerConnections;
  final UserMediaFactory _userMedia;

  final StreamController<IceCandidate> _candidates =
      StreamController<IceCandidate>.broadcast();
  final StreamController<MediaConnectionState> _connectionStates =
      StreamController<MediaConnectionState>.broadcast();
  final StreamController<rtc.MediaStream?> _remoteStreams =
      StreamController<rtc.MediaStream?>.broadcast();

  rtc.RTCPeerConnection? _peerConnection;
  rtc.MediaStream? _localStream;
  rtc.MediaStream? _remoteStream;
  rtc.RTCRtpSender? _videoSender;

  CodecSummary? _codecs;
  bool _disposed = false;

  /// The local camera and microphone, for the call screen's preview. Null until
  /// media has been opened.
  @override
  rtc.MediaStream? get localStream => _localStream;

  /// The far end's media, once a track has arrived.
  @override
  rtc.MediaStream? get remoteStream => _remoteStream;

  /// Emits whenever [remoteStream] changes, including to null on teardown.
  @override
  Stream<rtc.MediaStream?> get remoteStreams => _remoteStreams.stream;

  @override
  Stream<IceCandidate> get localCandidates => _candidates.stream;

  @override
  Stream<MediaConnectionState> get connectionState => _connectionStates.stream;

  @override
  CodecSummary? get negotiatedCodecs => _codecs;

  @override
  Future<SessionDescription> createOffer({required bool video}) async {
    final connection = await _ensureConnection(video: video);
    final offer = await connection.createOffer(_offerConstraints);
    await connection.setLocalDescription(offer);
    return _describe(offer, SdpType.offer);
  }

  @override
  Future<SessionDescription> createAnswer(
    SessionDescription remoteOffer, {
    required bool video,
  }) async {
    final connection = await _ensureConnection(video: video);
    await connection.setRemoteDescription(_toRtc(remoteOffer));
    final answer = await connection.createAnswer(_offerConstraints);
    await connection.setLocalDescription(answer);
    // Our own answer is what the two sides settled on, so it carries the codecs
    // just as the far end's would.
    _codecs = codecSummaryFromSdp(answer.sdp ?? '') ?? _codecs;
    return _describe(answer, SdpType.answer);
  }

  @override
  Future<void> applyRemoteDescription(SessionDescription description) async {
    final connection = _peerConnection;
    if (connection == null) {
      throw StateError(
        'No peer connection to apply a ${description.type.wireType} to.',
      );
    }
    await connection.setRemoteDescription(_toRtc(description));
    if (description.type == SdpType.answer) {
      _codecs = codecSummaryFromSdp(description.sdp) ?? _codecs;
    }
  }

  @override
  Future<void> addCandidate(IceCandidate candidate) async {
    final connection = _peerConnection;
    if (connection == null) {
      throw StateError('No peer connection to add a candidate to.');
    }
    await connection.addCandidate(
      rtc.RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ),
    );
  }

  @override
  Future<void> setMute(bool muted) async {
    for (final track in _localStream?.getAudioTracks() ?? const []) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setVideo(bool enabled) async {
    if (!enabled) {
      await _stopCapture();
      return;
    }

    final stream = _localStream;
    if (stream == null) {
      // Video before any media at all: the next createOffer/createAnswer opens
      // the camera with the rest, so there is nothing to do and nothing to
      // fail. Throwing here would end a call over a button pressed early.
      return;
    }

    final existing = stream.getVideoTracks().firstOrNull;
    if (existing != null) {
      existing.enabled = true;
      return;
    }

    final camera = await _userMedia(_constraints(video: true, audio: false));
    final track = camera.getVideoTracks().firstOrNull;
    if (track == null) return;
    await stream.addTrack(track);

    // Reuse the sender if there is one — replacing its track is what keeps
    // turning the camera back on from needing a second renegotiation.
    final sender = _videoSender;
    if (sender != null) {
      await sender.replaceTrack(track);
      return;
    }
    _videoSender = await _peerConnection?.addTrack(track, stream);
  }

  @override
  Future<void> switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    await rtc.Helper.switchCamera(track);
  }

  @override
  Future<void> dispose() async {
    // Safe to call twice on purpose: a call ended by remote hangup while the
    // user is pressing the red button disposes from two directions.
    if (_disposed) return;
    _disposed = true;

    final connection = _peerConnection;
    _peerConnection = null;
    _videoSender = null;

    for (final track in _localStream?.getTracks() ?? const []) {
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;

    await _remoteStream?.dispose();
    _remoteStream = null;

    if (connection != null) {
      await connection.close();
      await connection.dispose();
    }

    if (!_remoteStreams.isClosed) _remoteStreams.add(null);
    await _candidates.close();
    await _connectionStates.close();
    await _remoteStreams.close();
  }

  // -------------------------------------------------------------------------

  Future<rtc.RTCPeerConnection> _ensureConnection({required bool video}) async {
    final existing = _peerConnection;
    if (existing != null) {
      // A renegotiation. The camera may have been opened since, but the
      // connection and its senders stay.
      if (video) await setVideo(true);
      return existing;
    }

    final connection = await _peerConnections({
      'iceServers': _iceServers,
      // Unified plan is what every other client negotiates in; plan-b would
      // produce SDP an Element on the far end could not answer.
      'sdpSemantics': 'unified-plan',
    });

    connection.onIceCandidate = _onIceCandidate;
    connection.onIceGatheringState = _onGatheringState;
    connection.onConnectionState = _onConnectionState;
    connection.onTrack = _onTrack;

    _peerConnection = connection;

    final stream = await _openLocalMedia(video: video);
    for (final track in stream.getTracks()) {
      final sender = await connection.addTrack(track, stream);
      if (track.kind == 'video') _videoSender = sender;
    }
    return connection;
  }

  Future<rtc.MediaStream> _openLocalMedia({required bool video}) async {
    final existing = _localStream;
    if (existing != null) return existing;
    final stream = await _userMedia(_constraints(video: video, audio: true));
    _localStream = stream;
    return stream;
  }

  /// Releases the camera without touching the microphone or the connection.
  Future<void> _stopCapture() async {
    final stream = _localStream;
    if (stream == null) return;
    // The sender is deliberately kept with a null track: the m= section stays
    // in the SDP, so the far end sees the video stop rather than the session
    // change shape, and turning the camera back on is a replaceTrack.
    await _videoSender?.replaceTrack(null);
    for (final track in stream.getVideoTracks()) {
      await track.stop();
      await stream.removeTrack(track);
    }
  }

  void _onIceCandidate(rtc.RTCIceCandidate candidate) {
    if (_candidates.isClosed) return;
    _candidates.add(
      IceCandidate(
        candidate: candidate.candidate ?? '',
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      ),
    );
  }

  void _onGatheringState(rtc.RTCIceGatheringState state) {
    if (state != rtc.RTCIceGatheringState.RTCIceGatheringStateComplete) return;
    if (_candidates.isClosed) return;
    // MSC2746's end-of-candidates marker. Some platforms deliver it as a null
    // candidate and some deliver nothing at all, so it is synthesised from the
    // gathering state, which every platform reports.
    _candidates.add(const IceCandidate(candidate: ''));
  }

  void _onConnectionState(rtc.RTCPeerConnectionState state) {
    if (_connectionStates.isClosed) return;
    _connectionStates.add(mediaConnectionState(state));
  }

  void _onTrack(rtc.RTCTrackEvent event) {
    final stream = event.streams.firstOrNull;
    if (stream == null || _remoteStreams.isClosed) return;
    if (identical(stream, _remoteStream)) return;
    _remoteStream = stream;
    _remoteStreams.add(stream);
  }

  SessionDescription _describe(rtc.RTCSessionDescription value, SdpType type) {
    final sdp = value.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('WebRTC produced an empty ${type.wireType}.');
    }
    return SessionDescription(type: type, sdp: sdp);
  }

  rtc.RTCSessionDescription _toRtc(SessionDescription description) =>
      rtc.RTCSessionDescription(description.sdp, description.type.wireType);

  Map<String, dynamic> _constraints({
    required bool video,
    required bool audio,
  }) => {
    'audio': audio,
    'video': video
        ? {
            // The selfie camera, which is what a video call means on a phone
            // and is ignored everywhere else.
            'facingMode': 'user',
          }
        : false,
  };

  /// `offerToReceiveAudio`/`Video` are deliberately both on, including for a
  /// voice call: the far end may add video mid-call, and a peer connection that
  /// offered to receive none would need a renegotiation before it could show
  /// any.
  static const Map<String, dynamic> _offerConstraints = {
    'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
    'optional': <Object?>[],
  };
}

/// WebRTC's six connection states as the four `weft_call` acts on.
///
/// `new` folds into [MediaConnectionState.connecting] because they are the same
/// spinner, and `disconnected` stays separate from `failed` because the first
/// routinely heals when a phone changes network — treating it as fatal ends
/// calls that would have recovered.
@visibleForTesting
MediaConnectionState mediaConnectionState(rtc.RTCPeerConnectionState state) =>
    switch (state) {
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew ||
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
        MediaConnectionState.connecting,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
        MediaConnectionState.connected,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
        MediaConnectionState.disconnected,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
        MediaConnectionState.failed,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
        MediaConnectionState.closed,
    };
