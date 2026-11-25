import 'dart:async';

import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../services/audio/voice_recorder.dart';

/// The composer row while a voice note is being recorded.
///
/// Recording starts the moment this appears and runs until one of exactly two
/// buttons: the bin, which throws the take away and brings the keyboard row
/// back, or send. There is no state where audio is being kept without the row
/// saying so — the pulsing dot and the counting timer are the whole contract.
/// Pause holds the take in between: the dot stops breathing and the clock
/// stops counting, so a paused note looks as still as it is.
///
/// Deliberately buttons rather than WhatsApp's hold-and-slide: the *point* of
/// that gesture is that cancelling is easy, and an explicit bin next to an
/// explicit send is the easiest cancel there is — it also cannot be fumbled
/// into sending by letting go.
class VoiceRecordingBar extends StatefulWidget {
  const VoiceRecordingBar({
    super.key,
    required this.onCancel,
    required this.onSend,
    this.recorder,
  });

  /// The take was discarded — nothing was kept.
  final VoidCallback onCancel;

  /// A finished note the caller should now send.
  final ValueChanged<VoiceRecording> onSend;

  /// The recorder to drive; a real one when null. Tests pass a fake, because
  /// there is no microphone in a widget test.
  final VoiceRecorder? recorder;

  @override
  State<VoiceRecordingBar> createState() => _VoiceRecordingBarState();
}

class _VoiceRecordingBarState extends State<VoiceRecordingBar> {
  late final VoiceRecorder _recorder = widget.recorder ?? VoiceRecorder();
  Timer? _tick;
  bool _started = false;
  bool _finishing = false;
  bool _paused = false;
  double _level = 0;
  StreamSubscription<Object?>? _amplitude;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final ok = await _recorder.start();
    if (!mounted) {
      await _recorder.cancel();
      return;
    }
    if (!ok) {
      showWeftMessage(context, context.l10n.voiceNeedsMicrophone);
      widget.onCancel();
      return;
    }
    setState(() => _started = true);
    // Once a second is all the timer needs; the dot pulses on its own.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _amplitude = _recorder.amplitude.listen((a) {
      if (!mounted || _paused) return;
      // dBFS, roughly -45 (silence) to 0 (clipping) → 0..1.
      setState(() => _level = ((a.current + 45) / 45).clamp(0.0, 1.0));
    });
  }

  Future<void> _togglePause() async {
    if (!_started || _finishing) return;
    if (_paused) {
      await _recorder.resume();
    } else {
      await _recorder.pause();
    }
    if (!mounted) return;
    setState(() {
      _paused = _recorder.paused;
      // A held take hears nothing; a full bar would say otherwise.
      if (_paused) _level = 0;
    });
  }

  Future<void> _cancel() async {
    if (_finishing) return;
    _finishing = true;
    await _recorder.cancel();
    if (mounted) widget.onCancel();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    final recording = await _recorder.stop();
    if (!mounted) return;
    if (recording == null) {
      showWeftMessage(context, context.l10n.voiceTooShort);
      widget.onCancel();
      return;
    }
    widget.onSend(recording);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _amplitude?.cancel();
    // A teardown mid-recording (navigating away) keeps nothing.
    if (!_finishing) unawaited(_recorder.cancel());
    unawaited(_recorder.dispose());
    super.dispose();
  }

  String get _clock {
    final s = _recorder.elapsed.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(
        WeftSpace.md,
        WeftSpace.sm,
        WeftSpace.md,
        WeftSpace.md,
      ),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(top: BorderSide(color: context.palette.border)),
      ),
      child: SafeArea(
        top: false,
        // One live node for the whole row: the reader hears "Recording, 0:07"
        // on the same cadence the sighted user watches the clock.
        child: Semantics(
          container: true,
          liveRegion: true,
          label: !_started
              ? context.l10n.voiceStarting
              : _paused
              ? context.l10n.voicePausedSemantics(_clock)
              : context.l10n.voiceRecordingSemantics(_clock),
          child: Row(
            children: [
              NamedButton(
                label: context.l10n.voiceDiscardLabel,
                onPressed: _cancel,
                child: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  color: context.colors.error,
                  tooltip: context.l10n.commonDiscard,
                  onPressed: _cancel,
                ),
              ),
              const SizedBox(width: WeftSpace.sm),
              _PulsingDot(active: _started, paused: _paused),
              const SizedBox(width: WeftSpace.sm),
              Text(
                _clock,
                style: context.text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: WeftSpace.md),
              // A live level bar, so "is it hearing me?" has an answer before
              // the note is sent.
              Expanded(
                child: ClipRRect(
                  borderRadius: WeftRadius.pill,
                  child: LinearProgressIndicator(
                    value: _level,
                    minHeight: 6,
                    backgroundColor: context.colors.surfaceContainerHighest,
                  ),
                ),
              ),
              const SizedBox(width: WeftSpace.xs),
              NamedButton(
                label: _paused
                    ? context.l10n.voiceResumeLabel
                    : context.l10n.voicePauseLabel,
                onPressed: _started ? _togglePause : null,
                child: IconButton(
                  icon: Icon(_paused ? Icons.mic_rounded : Icons.pause_rounded),
                  tooltip: _paused
                      ? context.l10n.voiceResumeLabel
                      : context.l10n.voicePauseLabel,
                  onPressed: _started ? _togglePause : null,
                ),
              ),
              NamedButton(
                label: context.l10n.voiceSendLabel,
                onPressed: _finish,
                child: IconButton.filled(
                  icon: const Icon(Icons.send_rounded, size: 18),
                  tooltip: context.l10n.commonSend,
                  onPressed: _finish,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The red recording dot, breathing — and holding still while paused.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.active, this.paused = false});

  final bool active;
  final bool paused;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void didUpdateWidget(_PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paused == oldWidget.paused) return;
    if (widget.paused) {
      _pulse.stop();
      _pulse.value = 0;
    } else {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox(width: 10, height: 10);
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: context.colors.error,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
