/// Voice-message transcription against an endpoint the user supplies.
///
/// Weft hosts no speech service. Adapters cover the two request shapes that
/// between them serve nearly every backend in use — OpenAI-compatible
/// multipart (Whisper, faster-whisper, whisper.cpp, Groq, LocalAI, vLLM) and
/// Deepgram's raw-body API.
library;

export 'src/transcription_provider.dart';
export 'src/transcription_settings.dart';
