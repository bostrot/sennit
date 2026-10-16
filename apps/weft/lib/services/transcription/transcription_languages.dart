/// Languages offered as the spoken language of voice messages.
///
/// ISO-639-1 codes, which every backend here accepts: Whisper-style
/// endpoints, Deepgram and whisper.cpp. Each name is written in its own
/// language, the way a language picker is read: someone looking for theirs
/// looks for the word they would say.
///
/// Covers the 14 languages Cohere Transcribe was trained on — the model that
/// made the setting necessary, because it cannot detect the language and an
/// endpoint serving it falls back to English — plus Russian and Turkish, which
/// Whisper handles well.
const Map<String, String> kTranscriptionLanguages = {
  'ar': 'العربية',
  'de': 'Deutsch',
  'el': 'Ελληνικά',
  'en': 'English',
  'es': 'Español',
  'fr': 'Français',
  'it': 'Italiano',
  'ja': '日本語',
  'ko': '한국어',
  'nl': 'Nederlands',
  'pl': 'Polski',
  'pt': 'Português',
  'ru': 'Русский',
  'tr': 'Türkçe',
  'vi': 'Tiếng Việt',
  'zh': '中文',
};
