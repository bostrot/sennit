import 'package:weft_transcribe/weft_transcribe.dart';

/// The browser build's stand-in for the whisper.cpp provider. See
/// `local_whisper.dart`.
class LocalWhisperProvider implements TranscriptionProvider {
  LocalWhisperProvider({required this.modelPath, this.languageHint});

  final String modelPath;
  final String? languageHint;

  @override
  String get id => 'local-whisper';

  @override
  String get displayName => 'On-device (Whisper)';

  @override
  Future<Transcript> transcribe(TranscriptionRequest request) =>
      throw UnsupportedError('On-device transcription needs the app');

  @override
  void dispose() {}
}
