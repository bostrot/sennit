import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_transcribe/weft_transcribe.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

/// Transcribes on this device with whisper.cpp, using a model Weft downloaded.
///
/// This is the private path: the audio never leaves the phone, so it is the
/// only option that does not undo E2EE for voice notes. It is slower than a
/// server — expect seconds per message on mobile — which is why the endpoint
/// providers remain.
///
/// Uses the package's lower-level [Whisper] rather than `WhisperController`:
/// the controller insists on a `WhisperModel` enum and calls `initModel`,
/// which consults *its own* download registry. Weft downloads its models
/// itself, so that registry is always empty and the controller would report a
/// model this app had already installed as missing. [Whisper.transcribe]
/// takes an explicit `modelPath`, which is the seam that makes our files
/// usable.
class LocalWhisperProvider implements TranscriptionProvider {
  LocalWhisperProvider({
    required this.modelPath,
    this.languageHint,
    this.sizeHint = WhisperModel.base,
  });

  /// Only used to satisfy the constructor; the path above is what is loaded.
  final WhisperModel sizeHint;

  /// Absolute path to a ggml model file on disk.
  final String modelPath;

  /// Null asks whisper to detect the language.
  final String? languageHint;

  Whisper get _whisper => Whisper(model: sizeHint);

  @override
  String get id => 'local-whisper';

  @override
  String get displayName => 'On-device (Whisper)';

  @override
  Future<Transcript> transcribe(TranscriptionRequest request) async {
    if (!File(modelPath).existsSync()) {
      throw const TranscriptionException(
        'The on-device model is not installed. Download it in '
        'Settings → Endpoints → Local models.',
      );
    }

    // whisper.cpp reads a file, not a buffer, so the attachment is spilled to
    // a temp file first. ffmpeg inside the package handles the ogg/opus that
    // voice messages actually arrive as.
    final tempDir = await getTemporaryDirectory();
    final audioFile = File(
      p.join(
        tempDir.path,
        'weft-stt-${DateTime.now().microsecondsSinceEpoch}-${request.filename}',
      ),
    );

    try {
      await audioFile.writeAsBytes(request.audio);

      final response = await _whisper.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: audioFile.path,
          language: request.languageHint ?? languageHint ?? 'auto',
          isNoTimestamps: true,
          // Voice notes are short; letting whisper hallucinate non-speech
          // tokens on silence produces confident nonsense.
          suppressNonSpeechTokens: true,
        ),
        modelPath: modelPath,
      );

      final text = response.text.trim();
      if (text.isEmpty) {
        throw const TranscriptionException(
          'Nothing recognisable in that recording',
        );
      }

      return Transcript(
        text: text,
        provider: id,
        language: request.languageHint ?? languageHint,
      );
    } on TranscriptionException {
      rethrow;
    } on Exception catch (e) {
      throw TranscriptionException('On-device transcription failed: $e');
    } finally {
      // The audio is a copy of a private message; it does not linger in temp.
      if (audioFile.existsSync()) {
        try {
          await audioFile.delete();
        } on FileSystemException {
          // Best effort; the OS clears temp anyway.
        }
      }
    }
  }

  @override
  void dispose() {}
}
