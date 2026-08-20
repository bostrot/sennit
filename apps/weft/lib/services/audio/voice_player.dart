import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/providers.dart';

/// What is playing right now, if anything.
///
/// One value for the whole app on purpose: two voice notes playing over each
/// other is never what anyone meant, so starting one stops the other — which
/// only works if they share this state.
class VoicePlayback {
  const VoicePlayback({
    this.eventId,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.duration,
  });

  const VoicePlayback.idle() : this();

  /// The message being played, or null when idle.
  final String? eventId;

  final bool playing;

  /// True between tapping play and audio actually starting — downloading and
  /// decrypting an attachment takes visible time on a phone.
  final bool loading;

  final Duration position;
  final Duration? duration;

  /// Played fraction, for drawing progress over the waveform.
  double get progress {
    final total = duration;
    if (total == null || total.inMilliseconds == 0) return 0;
    return (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  VoicePlayback copyWith({
    String? eventId,
    bool? playing,
    bool? loading,
    Duration? position,
    Duration? duration,
  }) {
    return VoicePlayback(
      eventId: eventId ?? this.eventId,
      playing: playing ?? this.playing,
      loading: loading ?? this.loading,
      position: position ?? this.position,
      duration: duration ?? this.duration,
    );
  }
}

/// Plays voice messages and audio attachments.
///
/// The bytes come through the repository's [ChatRepository.attachmentBytes],
/// which is the one path that also works for encrypted rooms — an encrypted
/// attachment has no playable URL, so the ciphertext is downloaded, decrypted
/// locally, spilled to a temp file and played from there.
class VoicePlayer extends Notifier<VoicePlayback> {
  AudioPlayer? _player;
  StreamSubscription<Duration>? _positions;
  StreamSubscription<PlayerState>? _states;

  /// Guards against a slow download finishing after the user tapped another
  /// message: only the newest request may install its player.
  int _requestSerial = 0;

  @override
  VoicePlayback build() {
    ref.onDispose(() {
      unawaited(_teardown());
    });
    return const VoicePlayback.idle();
  }

  /// Play, pause, or resume [message]. The play button's only entry point.
  ///
  /// Throws with a readable message when the audio cannot be fetched or the
  /// platform cannot decode it; the caller shows it as a toast.
  Future<void> toggle(WeftMessage message) async {
    final player = _player;
    if (state.eventId == message.eventId && player != null) {
      if (player.playing) {
        await player.pause();
        return;
      }
      // Tapping play on a finished clip starts it over rather than doing
      // nothing at its end position.
      if (player.processingState == ProcessingState.completed) {
        await player.seek(Duration.zero);
      }
      unawaited(player.play());
      return;
    }
    await _start(message);
  }

  Future<void> _start(WeftMessage message) async {
    final serial = ++_requestSerial;
    await _teardown();
    state = VoicePlayback(eventId: message.eventId, loading: true);

    final bytes = await ref
        .read(chatRepositoryProvider)
        .attachmentBytes(message.roomId, message.eventId, thumbnail: false);
    if (serial != _requestSerial) return;
    if (bytes == null) {
      state = const VoicePlayback.idle();
      throw Exception('The audio could not be downloaded.');
    }

    // Spilled to disk rather than streamed from memory: every platform backend
    // can open a file, and a voice note is small enough that this is free.
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(dir.path, 'weft-voice-${message.eventId.hashCode}.audio'),
    );
    await file.writeAsBytes(bytes, flush: true);
    if (serial != _requestSerial) return;

    final player = AudioPlayer();
    try {
      await player.setFilePath(file.path);
    } on Exception {
      await player.dispose();
      if (serial == _requestSerial) state = const VoicePlayback.idle();
      throw Exception('This platform cannot decode this voice message.');
    }
    if (serial != _requestSerial) {
      await player.dispose();
      return;
    }

    _player = player;
    state = VoicePlayback(
      eventId: message.eventId,
      playing: true,
      duration:
          player.duration ??
          (message.durationMs == null
              ? null
              : Duration(milliseconds: message.durationMs!)),
    );

    _positions = player.positionStream.listen((position) {
      if (state.eventId != message.eventId) return;
      state = state.copyWith(
        position: position,
        duration: player.duration ?? state.duration,
      );
    });
    _states = player.playerStateStream.listen((playerState) {
      if (state.eventId != message.eventId) return;
      final done = playerState.processingState == ProcessingState.completed;
      state = state.copyWith(
        playing: playerState.playing && !done,
        loading: false,
        position: done ? Duration.zero : null,
      );
    });

    unawaited(player.play());
  }

  Future<void> _teardown() async {
    await _positions?.cancel();
    await _states?.cancel();
    _positions = null;
    _states = null;
    final player = _player;
    _player = null;
    if (player != null) {
      await player.dispose();
    }
  }
}

final voicePlayerProvider = NotifierProvider<VoicePlayer, VoicePlayback>(
  VoicePlayer.new,
);
