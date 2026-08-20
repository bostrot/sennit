import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:weft_attachments/weft_attachments.dart';

/// A finished recording, ready to hand to the send pipeline.
class VoiceRecording {
  const VoiceRecording({required this.source, required this.durationMs});

  final AttachmentSource source;
  final int durationMs;
}

/// Records one voice note at a time.
///
/// Thin on purpose: the composer owns the *state machine* (idle → recording →
/// sent/cancelled) because that is UI; this owns the recorder, the codec
/// choice and the temp file, because those are platform facts.
class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _elapsed = Stopwatch();
  String? _path;

  /// Amplitude ticks while recording, for the level indicator.
  Stream<Amplitude> get amplitude =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 200));

  Duration get elapsed => _elapsed.elapsed;

  /// Asks for the microphone (first time) and starts recording.
  ///
  /// Returns false when permission was refused — the caller says so in words
  /// rather than sitting in a recording state that records nothing.
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;

    // Opus-in-ogg where the platform can encode it: it is what every other
    // Matrix client sends and expects, and what the bridges transcode best.
    // Apple platforms have no opus encoder, so they record AAC — still a
    // legal m.audio, just a heavier one.
    final opus = switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.linux ||
      TargetPlatform.windows => true,
      _ => false,
    };

    final dir = await getTemporaryDirectory();
    final path = p.join(
      dir.path,
      'weft-voice-note-${DateTime.now().millisecondsSinceEpoch}'
      '${opus ? '.ogg' : '.m4a'}',
    );

    await _recorder.start(
      RecordConfig(
        encoder: opus ? AudioEncoder.opus : AudioEncoder.aacLc,
        // Voice settings, not music: mono at a modest bitrate keeps a minute
        // of speech around a quarter megabyte.
        numChannels: 1,
        bitRate: 32000,
        sampleRate: 48000,
      ),
      path: path,
    );
    _path = path;
    _elapsed
      ..reset()
      ..start();
    return true;
  }

  /// Stops and returns the note, or null when nothing usable was captured.
  Future<VoiceRecording?> stop() async {
    _elapsed.stop();
    final path = await _recorder.stop() ?? _path;
    _path = null;
    if (path == null) return null;

    final file = File(path);
    if (!file.existsSync()) return null;
    final length = file.lengthSync();
    // Under a third of a second is a fumbled tap, not a message.
    if (length == 0 || _elapsed.elapsedMilliseconds < 300) {
      await _discard(file);
      return null;
    }

    final headerLength = length < 64 ? length : 64;
    final header = await file
        .openRead(0, headerLength)
        .fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (b, chunk) => b..add(chunk),
        );

    return VoiceRecording(
      source: AttachmentSource(
        filename: path,
        sizeBytes: length,
        header: header.takeBytes(),
        declaredMimeType: path.endsWith('.ogg') ? 'audio/ogg' : 'audio/mp4',
      ),
      durationMs: _elapsed.elapsedMilliseconds,
    );
  }

  /// Stops and deletes whatever was captured.
  Future<void> cancel() async {
    _elapsed.stop();
    final path = await _recorder.stop() ?? _path;
    _path = null;
    if (path != null) await _discard(File(path));
  }

  Future<void> _discard(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Temp dir; the OS sweeps it.
    }
  }

  Future<void> dispose() => _recorder.dispose();
}
