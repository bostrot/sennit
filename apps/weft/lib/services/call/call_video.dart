import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// The pictures a call has, for the widgets that draw them.
///
/// Deliberately not part of `weft_call`'s [MediaEngine]: that interface exists
/// so the state machine can be tested with no WebRTC at all, and a media stream
/// is a WebRTC type. Video is therefore a *second* interface, implemented by the
/// same engine and reached only by the call screen — which means the whole of
/// calling's logic still compiles and runs without it.
///
/// It is an interface rather than the concrete engine for the ordinary reason:
/// a widget test has no plugin behind `RTCVideoRenderer`, so it passes one of
/// these that answers null and the call screen draws its placeholder — which is
/// also exactly what a real video call looks like in the second before the far
/// end's first frame arrives.
abstract interface class CallVideoSource {
  /// This device's camera and microphone, for the local preview. Null until
  /// media has been opened, and for a voice call throughout.
  rtc.MediaStream? get localStream;

  /// The far end's media, once a track has arrived.
  rtc.MediaStream? get remoteStream;

  /// Emits whenever [remoteStream] changes, including to null on teardown.
  ///
  /// A stream and not just a getter because the remote track arrives some
  /// hundreds of milliseconds *after* the call reaches
  /// `CallState.connected` — there is no call-state change to rebuild on, so
  /// without this the far end's video would appear on the next unrelated
  /// repaint.
  Stream<rtc.MediaStream?> get remoteStreams;
}
