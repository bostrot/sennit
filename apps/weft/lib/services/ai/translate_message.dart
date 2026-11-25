import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'llm_request.dart';

/// Languages a message can be translated into, by ISO-639-1 code, each named
/// in itself — the way a language picker is read: someone looking for theirs
/// looks for the word they would say.
///
/// Every language Sennit ships in, plus the ones its users write in most.
const Map<String, String> kTranslationLanguages = {
  'ar': 'العربية',
  'de': 'Deutsch',
  'el': 'Ελληνικά',
  'en': 'English',
  'es': 'Español',
  'fr': 'Français',
  'hi': 'हिन्दी',
  'it': 'Italiano',
  'ja': '日本語',
  'ko': '한국어',
  'nl': 'Nederlands',
  'pl': 'Polski',
  'pt': 'Português',
  'ru': 'Русский',
  'tr': 'Türkçe',
  'uk': 'Українська',
  'vi': 'Tiếng Việt',
  'zh': '中文',
};

/// English names for the prompt: a small model follows "into German" far
/// more reliably than "into de" or "into Deutsch".
const Map<String, String> _englishNames = {
  'ar': 'Arabic',
  'de': 'German',
  'el': 'Greek',
  'en': 'English',
  'es': 'Spanish',
  'fr': 'French',
  'hi': 'Hindi',
  'it': 'Italian',
  'ja': 'Japanese',
  'ko': 'Korean',
  'nl': 'Dutch',
  'pl': 'Polish',
  'pt': 'Portuguese',
  'ru': 'Russian',
  'tr': 'Turkish',
  'uk': 'Ukrainian',
  'vi': 'Vietnamese',
  'zh': 'Simplified Chinese',
};

/// The language a translation goes into when the user has not picked one:
/// the app's own, or English when it is not on the list.
String defaultTranslationLanguage(String appLanguageCode) =>
    kTranslationLanguages.containsKey(appLanguageCode) ? appLanguageCode : 'en';

/// The chat completion messages that translate [text] into [language].
///
/// Tags around the answer rather than "only the translation", because a
/// thinking or chatty model puts something before it either way, and the
/// tags are what [parseTranslation] can find it by.
List<Map<String, String>> translationRequest({
  required String text,
  required String language,
}) {
  final target = _englishNames[language] ?? language;
  return [
    {
      'role': 'system',
      'content':
          'You translate chat messages. Translate the message the user '
          'gives you into $target. Keep its meaning, tone, emoji, names, '
          'links and line breaks; do not answer it, explain it or add '
          'anything. If it is already in $target, repeat it unchanged. '
          'Output only the translation between <translation> and '
          '</translation>.',
    },
    {'role': 'user', 'content': text},
  ];
}

/// The translation in whatever the model said, or null when there is none.
///
/// Reasoning in `<think>` is dropped and an answer that never left it is
/// nothing; the `<translation>` tags are taken off when the model used them,
/// and the whole answer stands when it did not.
String? parseTranslation(String content) {
  var text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) return null;
  final tagged = RegExp(
    r'<translation>\s*([\s\S]*?)\s*(?:</translation>|$)',
    caseSensitive: false,
  ).firstMatch(text);
  if (tagged != null) text = tagged[1]!;
  text = text.trim();
  return text.isEmpty ? null : text;
}

/// Why a translation did not come.
enum TranslationFailure { unreachable, timedOut, empty }

/// A translation, or why there is none.
typedef TranslationResult = ({String? text, TranslationFailure? failure});

/// Asks the user's own model to translate [text] into [language].
///
/// The same OpenAI-compatible chat completion every AI feature here uses,
/// sent only on the user's tap: a message leaves the device to be translated
/// because the user asked for that one message, never in the background.
Future<TranslationResult> translateMessage({
  required String baseUrl,
  required String model,
  String? apiKey,
  required String text,
  required String language,
  http.Client? client,
  Duration? timeout,
  Future<void>? cancel,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final url = Uri.parse('$base/chat/completions');
  final owned = client == null;
  final httpClient = client ?? llmHttpClient();
  // A translation is about as long as what it translates; tokens run at
  // roughly one per three or four characters, and scripts like Hindi take
  // more. Room for that and some.
  final tokens = math.min(4096, math.max(256, text.length));
  try {
    final answer = await requestCompletion(
      httpClient,
      url,
      headers: {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      },
      body: {
        'model': model,
        'temperature': 0.2,
        'messages': translationRequest(text: text, language: language),
      },
      maxTokens: tokens,
      retryMaxTokens: math.min(8192, tokens * 2),
      answered: (content) => parseTranslation(content) != null,
      timeout: timeout ?? llmResponseTimeout(base, LlmTask.translate),
      cancel: cancel,
      what: 'translation',
      optional: noThinkingOptions(base),
    );
    if (!answer.ok) {
      debugPrint('weft: translation: $url answered ${answer.status}');
      return (text: null, failure: TranslationFailure.unreachable);
    }
    final content = answer.content;
    final translated = content == null ? null : parseTranslation(content);
    if (translated == null) {
      debugPrint('weft: translation: nothing usable in ${jsonEncode(content)}');
      return (text: null, failure: TranslationFailure.empty);
    }
    return (text: translated, failure: null);
  } on TimeoutException {
    return (text: null, failure: TranslationFailure.timedOut);
  } on Object catch (error) {
    debugPrint('weft: translation against $url failed: $error');
    return (text: null, failure: TranslationFailure.unreachable);
  } finally {
    if (owned) httpClient.close();
  }
}
