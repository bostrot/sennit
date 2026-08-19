import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:weft_design/weft_design.dart';

import '../../services/call/call_video.dart';

/// One video surface — the far end's picture, or this device's preview.
///
/// Everything awkward about rendering WebRTC video is here: a renderer is a
/// platform texture that must be created, initialised, pointed at a stream and
/// disposed in that order, and it must not be created at all when there is no
/// stream to show. That last part is what makes the call screen renderable in a
/// widget test and in a golden — with no stream there is no plugin call, and
/// what draws is [placeholder], which is also what a real call draws in the
/// second before the first frame arrives.
class CallVideoView extends StatefulWidget {
  const CallVideoView({
    super.key,
    required this.source,
    required this.local,
    this.mirror = false,
    this.fit = rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    this.placeholder,
  });

  /// The call's pictures, or null when the call has no engine yet.
  final CallVideoSource? source;

  /// Whether this shows [CallVideoSource.localStream] rather than the remote
  /// one.
  final bool local;

  /// Mirrored, as a selfie preview must be — a preview that moves the wrong way
  /// when the user does is disorienting in a way nobody can name.
  final bool mirror;

  final rtc.RTCVideoViewObjectFit fit;

  /// Drawn while there is no picture.
  final Widget? placeholder;

  @override
  State<CallVideoView> createState() => _CallVideoViewState();
}

class _CallVideoViewState extends State<CallVideoView> {
  rtc.RTCVideoRenderer? _renderer;
  rtc.MediaStream? _attached;
  StreamSubscription<rtc.MediaStream?>? _remote;

  @override
  void initState() {
    super.initState();
    _listen();
    unawaited(_sync());
  }

  @override
  void didUpdateWidget(CallVideoView old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source || old.local != widget.local) {
      _remote?.cancel();
      _remote = null;
      _listen();
    }
    // The local stream has no change notification of its own — it appears when
    // the engine opens the microphone and camera, which is a call-state change
    // the screen above has already rebuilt for.
    unawaited(_sync());
  }

  void _listen() {
    if (widget.local) return;
    _remote = widget.source?.remoteStreams.listen((_) => unawaited(_sync()));
  }

  /// Points the renderer at whichever stream this view is for, creating one the
  /// first time there is anything to point it at.
  Future<void> _sync() async {
    final source = widget.source;
    final stream = source == null
        ? null
        : (widget.local ? source.localStream : source.remoteStream);

    if (identical(stream, _attached)) return;

    if (stream == null) {
      _attached = null;
      _renderer?.srcObject = null;
      if (mounted) setState(() {});
      return;
    }

    var renderer = _renderer;
    if (renderer == null) {
      renderer = rtc.RTCVideoRenderer();
      try {
        await renderer.initialize();
      } on Object catch (error) {
        // No platform behind the texture: a widget test, or a build of a
        // platform flutter_webrtc has no renderer for. The placeholder is the
        // honest result and the call's audio is unaffected.
        debugPrint('weft: could not initialise a video renderer: $error');
        return;
      }
      if (!mounted) {
        await renderer.dispose();
        return;
      }
      _renderer = renderer;
    }

    renderer.srcObject = stream;
    _attached = stream;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_remote?.cancel());
    final renderer = _renderer;
    _renderer = null;
    if (renderer != null) {
      renderer.srcObject = null;
      unawaited(renderer.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    if (renderer == null || _attached == null) {
      return widget.placeholder ?? const _NoPicture();
    }
    // `RTCVideoView` contributes no semantics of its own, so a video call was
    // a screen-sized region a reader could find nothing in at all. There is
    // nothing useful to say about the *picture* — this says what the region is,
    // which is what stops it being a hole in the screen.
    return Semantics(
      label: widget.mirror ? 'Your camera' : 'Video from the other person',
      child: rtc.RTCVideoView(
        renderer,
        mirror: widget.mirror,
        objectFit: widget.fit,
      ),
    );
  }
}

/// A video surface with nothing in it yet.
class _NoPicture extends StatelessWidget {
  const _NoPicture();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'No picture yet',
      excludeSemantics: true,
      child: ColoredBox(
        color: context.colors.surfaceContainerHighest,
        child: Center(
          child: Icon(
            Icons.videocam_off_rounded,
            size: 28,
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
