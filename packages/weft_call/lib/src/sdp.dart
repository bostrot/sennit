import 'package:meta/meta.dart';

/// Which half of an offer/answer exchange a description is.
///
/// Only these two appear on the Matrix wire. WebRTC's `pranswer` and `rollback`
/// have no `m.call.*` event that carries them, so admitting them here would
/// create a state the signalling layer could never produce.
enum SdpType {
  offer('offer'),
  answer('answer');

  const SdpType(this.wireType);

  /// The value of the `type` key inside `m.call.invite`'s `offer`,
  /// `m.call.answer`'s `answer` and `m.call.negotiate`'s `description`.
  final String wireType;

  static SdpType? fromWire(String type) {
    for (final value in SdpType.values) {
      if (value.wireType == type) return value;
    }
    return null;
  }
}

/// One SDP blob and what it is.
///
/// Held as a value type rather than passed around as a `Map` so that a caller
/// cannot silently swap an offer for an answer — the single mistake that turns
/// a renegotiation into a call that drops.
@immutable
class SessionDescription {
  const SessionDescription({required this.type, required this.sdp});

  const SessionDescription.offer(this.sdp) : type = SdpType.offer;

  const SessionDescription.answer(this.sdp) : type = SdpType.answer;

  final SdpType type;

  /// The raw SDP. This package never parses or rewrites it; that is the media
  /// engine's job, and the one place where a platform's WebRTC quirks live.
  final String sdp;

  @override
  bool operator ==(Object other) =>
      other is SessionDescription && other.type == type && other.sdp == sdp;

  @override
  int get hashCode => Object.hash(type, sdp);

  @override
  String toString() => 'SessionDescription(${type.wireType}, ${sdp.length}B)';
}

/// One ICE candidate as it travels in `m.call.candidates`.
///
/// Value equality matters here and is not decoration: a peer that resends the
/// same candidate — which happens routinely on a reconnect — must not have it
/// added twice, and [IceCandidateBuffer] relies on `==` to notice.
@immutable
class IceCandidate {
  const IceCandidate({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  /// The `candidate` attribute line. An empty string is the end-of-candidates
  /// marker, which MSC2746 requires be forwarded rather than dropped: a peer
  /// that never learns gathering finished waits out its own ICE timeout.
  final String candidate;

  final String? sdpMid;
  final int? sdpMLineIndex;

  /// True for the end-of-candidates sentinel.
  bool get isEndOfCandidates => candidate.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is IceCandidate &&
      other.candidate == candidate &&
      other.sdpMid == sdpMid &&
      other.sdpMLineIndex == sdpMLineIndex;

  @override
  int get hashCode => Object.hash(candidate, sdpMid, sdpMLineIndex);

  @override
  String toString() => isEndOfCandidates
      ? 'IceCandidate(end-of-candidates)'
      : 'IceCandidate($sdpMid#$sdpMLineIndex ${candidate.length}B)';
}

/// What the two sides actually agreed to encode with.
///
/// Recorded on the session because "the call sounded bad" is unanswerable
/// without it — Opus at 48 kHz and a fallback to PCMU are the same UI, and only
/// this tells them apart in a bug report.
@immutable
class CodecSummary {
  const CodecSummary({this.audio, this.video});

  /// e.g. `opus`. Null until the answer has been applied.
  final String? audio;

  /// e.g. `VP8`, `H264`. Null for a voice call, and for a video call that has
  /// not finished negotiating.
  final String? video;

  bool get isEmpty => audio == null && video == null;

  /// Single-line form for diagnostics and the call screen's detail row.
  String get label => switch ((audio, video)) {
    (final String a, final String v) => '$a / $v',
    (final String a, null) => a,
    (null, final String v) => v,
    _ => 'unknown',
  };

  @override
  bool operator ==(Object other) =>
      other is CodecSummary && other.audio == audio && other.video == video;

  @override
  int get hashCode => Object.hash(audio, video);

  @override
  String toString() => 'CodecSummary($label)';
}
