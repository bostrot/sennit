import '../../services/call/call_audio.dart';
import '../../services/call/call_service.dart';

/// What the call UI can do to a call.
///
/// [CallService] already has exactly these methods, so this interface adds no
/// behaviour — what it adds is a call screen that can be built without one.
/// That matters more here than usual: a `CallService` needs a homeserver, a
/// media engine and an audio session, and a widget test of the mute button
/// should need none of the three. The same seam is what lets the goldens in the
/// next task render a connected video call that never existed.
abstract interface class CallControls {
  /// Answers a ringing call. [video] defaults to whatever the caller offered.
  Future<void> accept({bool? video});

  /// Declines a ringing call.
  Future<void> decline();

  /// Ends an outgoing or established call.
  Future<void> hangUp();

  Future<void> setMuted({required bool muted});

  /// Sends the audio somewhere else, and remembers the choice for as long as
  /// that route exists.
  Future<void> setAudioRoute(CallAudioRoute route);

  /// Starts or stops the local camera within an established video call. Does
  /// not renegotiate.
  Future<void> setCameraEnabled({required bool enabled});

  Future<void> switchCamera();

  /// Asks the far end to add video to a voice call, or to drop back to audio.
  Future<void> requestVideo({bool video});
}

/// [CallControls] over the real service.
///
/// A forwarder rather than `CallService implements CallControls`, so the
/// service layer keeps knowing nothing about the widgets above it.
class CallServiceControls implements CallControls {
  const CallServiceControls(this._service);

  final CallService _service;

  @override
  Future<void> accept({bool? video}) => _service.accept(video: video);

  @override
  Future<void> decline() => _service.decline();

  @override
  Future<void> hangUp() => _service.hangUp();

  @override
  Future<void> setMuted({required bool muted}) =>
      _service.setMuted(muted: muted);

  @override
  Future<void> setAudioRoute(CallAudioRoute route) =>
      _service.setAudioRoute(route);

  @override
  Future<void> setCameraEnabled({required bool enabled}) =>
      _service.setCameraEnabled(enabled: enabled);

  @override
  Future<void> switchCamera() => _service.switchCamera();

  @override
  Future<void> requestVideo({bool video = true}) =>
      _service.requestVideo(video: video);
}

/// Controls for a call surface with no service behind it — a golden, or a build
/// with no session. Every button still draws and none of them does anything,
/// which is better than a screen that cannot be rendered at all.
class InertCallControls implements CallControls {
  const InertCallControls();

  @override
  Future<void> accept({bool? video}) async {}

  @override
  Future<void> decline() async {}

  @override
  Future<void> hangUp() async {}

  @override
  Future<void> setMuted({required bool muted}) async {}

  @override
  Future<void> setAudioRoute(CallAudioRoute route) async {}

  @override
  Future<void> setCameraEnabled({required bool enabled}) async {}

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> requestVideo({bool video = true}) async {}
}
