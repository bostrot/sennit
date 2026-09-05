/// Inline video playback for the media viewer.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';

/// Builds the widget that plays [file].
///
/// A factory behind a provider rather than a widget used directly, because
/// `video_player` is a method channel: a widget test that builds one gets a
/// `MissingPluginException` before a single pixel is laid out, which would put
/// the viewer's swipe, header and action bar out of reach of `flutter test`
/// along with the playback itself. Overriding [videoSurfaceProvider] leaves
/// everything except the decoder real.
typedef VideoSurfaceBuilder = Widget Function(BuildContext context, File file);

/// Plays a file the viewer has already staged to disk.
///
/// A local file rather than the mxc URL, and not only for encrypted rooms where
/// there is no fetchable URL at all: staging once means the same bytes serve
/// playback, Save and Share, so scrubbing a video and then saving it does not
/// fetch it twice.
class VideoSurface extends StatefulWidget {
  const VideoSurface({
    super.key,
    required this.file,
    this.autoPlay = false,
    this.onFinished,
  });

  final File file;

  /// Start playing as soon as the decoder is ready. Off for the media viewer
  /// — a tapped poster should not start talking — and on for stories, which
  /// are *opened to be played*.
  final bool autoPlay;

  /// Called once when playback reaches the end. A story pager advances on it.
  final VoidCallback? onFinished;

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface> {
  VideoPlayerController? _controller;
  Object? _error;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(VideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _controller?.dispose();
      _controller = null;
      _open();
    }
  }

  Future<void> _open() async {
    final controller = VideoPlayerController.file(widget.file);
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      // The media viewer does not autoplay — a tapped poster should not
      // start talking — but a story does; the caller decides.
      await controller.setLooping(false);
      if (widget.onFinished != null) controller.addListener(_checkFinished);
      if (widget.autoPlay) await controller.play();
      setState(() => _controller = controller);
    } on Object catch (error) {
      // Deliberately Object: a platform decoder refusing a codec throws a
      // PlatformException, and an unreadable file throws before that.
      await controller.dispose();
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  /// Fires [VideoSurface.onFinished] exactly once, at the end of playback.
  void _checkFinished() {
    final value = _controller?.value;
    if (value == null || _finished) return;
    if (value.duration > Duration.zero &&
        !value.isPlaying &&
        value.position >= value.duration) {
      _finished = true;
      widget.onFinished?.call();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _Centred(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_rounded, color: Colors.white70),
            const SizedBox(height: WeftSpace.sm),
            Text(
              context.l10n.videoCannotPlay,
              style: context.text.bodySmall?.copyWith(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      return const _Centred(child: CircularProgressIndicator());
    }

    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(controller),
            _PlayPauseOverlay(controller: controller),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // A draggable control with no name and no value: a reader found
              // an unlabelled thing at the bottom of the picture, and dragging
              // it seeks the video.
              child: Semantics(
                label: context.l10n.videoPosition,
                slider: true,
                value: _positionLabel(controller.value),
                child: VideoProgressIndicator(controller, allowScrubbing: true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tap anywhere to toggle, with the badge shown only while paused.
///
/// A control bar that is always up would sit over the picture for the whole
/// clip; the paused state is the only one where the affordance is telling the
/// user something they do not already know.
class _PlayPauseOverlay extends StatefulWidget {
  const _PlayPauseOverlay({required this.controller});

  final VideoPlayerController controller;

  @override
  State<_PlayPauseOverlay> createState() => _PlayPauseOverlayState();
}

class _PlayPauseOverlayState extends State<_PlayPauseOverlay> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final playing = widget.controller.value.isPlaying;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          playing ? widget.controller.pause() : widget.controller.play(),
      child: AnimatedOpacity(
        opacity: playing ? 0 : 1,
        duration: WeftMotion.fast,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: context.colors.scrim.withValues(alpha: 0.55),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            size: 40,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _Centred extends StatelessWidget {
  const _Centred({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(child: child);
}

/// The video widget the media viewer builds. Overridden in tests with a stub,
/// because `video_player` is a method channel.
final videoSurfaceProvider = Provider<VideoSurfaceBuilder>(
  (ref) =>
      (context, file) => VideoSurface(file: file),
);

/// Builds the widget that plays a story: autoplaying, and telling the pager
/// when the clip is over.
typedef StoryVideoSurfaceBuilder =
    Widget Function(BuildContext context, File file, VoidCallback onFinished);

/// The story viewer's video surface. Same test seam as [videoSurfaceProvider].
final storyVideoSurfaceProvider = Provider<StoryVideoSurfaceBuilder>(
  (ref) =>
      (context, file, onFinished) =>
          VideoSurface(file: file, autoPlay: true, onFinished: onFinished),
);

/// Where the playhead is, in the words a person would use.
String _positionLabel(VideoPlayerValue value) {
  String clock(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  return '${clock(value.position)} of ${clock(value.duration)}';
}
