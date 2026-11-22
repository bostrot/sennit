import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'llm_request.dart';

/// Asks the configured LLM for one or two short answers to a conversation.
///
/// OpenAI-compatible chat completions, which is what every self-hostable
/// server speaks — Ollama, llama.cpp, LocalAI, vLLM — as well as the hosted
/// ones. Returns at most two suggestions; an empty list on any failure,
/// because a notification is not the place for an error message.
///
/// [timeout] stays short for every endpoint, self-hosted or not, unlike the
/// other AI requests': the notification is held until its chips are written,
/// under the notification service's own ten-second cap, and a chip that
/// arrives after the notification went out without it has nowhere to go.
Future<List<String>> suggestSmartReplies({
  required String baseUrl,
  required String model,
  String? apiKey,
  required String chatTitle,
  required List<String> transcript,
  String? calendar,
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || transcript.isEmpty) {
    return const [];
  }
  final url = Uri.parse('$base/chat/completions');
  final owned = client == null;
  final httpClient = client ?? llmHttpClient();
  try {
    final response = await postLlm(
      httpClient,
      url,
      headers: {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'temperature': 0.7,
        'max_tokens': 120,
        'messages': [
          {
            'role': 'system',
            'content':
                'You write short chat replies the user could send. '
                'Output ONLY a JSON object with a "replies" list of one '
                'or two strings — no analysis, no commentary, no '
                'markdown. Each reply is a complete sentence of at most '
                'eight words, in the same language as the conversation.'
                '${calendarPromptBlock(calendar)}',
          },
          // One worked example pins the format better than any amount
          // of instruction — and gives the template no placeholder text
          // to parrot back, which is how "…" became a chip.
          {
            'role': 'user',
            'content':
                'Conversation (newest message last):\n'
                'Anna: Kommst du morgen mit?\n\nJSON:',
          },
          {
            'role': 'assistant',
            'content':
                '{"replies": ["Ja, gerne!", "Ich sage dir heute Abend '
                'Bescheid."]}',
          },
          {
            'role': 'user',
            'content':
                'Conversation (newest message last):\n'
                '${transcript.join('\n')}\n\nJSON:',
          },
        ],
      }),
      timeout: timeout,
    );
    if (response.statusCode != 200) {
      debugPrint('weft: smart replies: $url answered ${response.statusCode}');
      return const [];
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final content =
        ((decoded as Map)['choices'] as List?)
                ?.cast<Map>()
                .firstOrNull?['message']?['content']
            as String?;
    if (content == null) {
      debugPrint('weft: smart replies: no content in the completion');
      return const [];
    }
    final replies = parseSmartReplies(content);
    if (replies.isEmpty) {
      debugPrint(
        'weft: smart replies: nothing usable in ${jsonEncode(content)}',
      );
    }
    return replies;
  } on Object catch (error) {
    debugPrint('weft: smart replies against $url failed: $error');
    return const [];
  } finally {
    if (owned) httpClient.close();
  }
}

/// The calendar paragraph both AI prompts end their system message with, or
/// nothing when there is no calendar to tell.
///
/// One wording for both features for the reason `transcriptLinesFor` is
/// shared: the same endpoint should not be told about the same week in two
/// different ways. "Never mention what" is there because the section carries
/// no titles to mention — a model that is not told so invents "I have a
/// meeting".
String calendarPromptBlock(String? calendar) {
  if (calendar == null || calendar.trim().isEmpty) return '';
  return '\n\nThe user\'s calendar, for when the conversation is about time:\n'
      '$calendar\n'
      'When someone asks whether the user is free, answer from this calendar. '
      'When the time they ask about is busy, say so and offer a free time '
      'instead. Never say what the user is busy with, and never promise a '
      'time the calendar shows as busy.';
}

/// Pulls at most two usable suggestions out of whatever the model said.
///
/// The happy path is the JSON array the prompt demands; the fallbacks cover
/// a model that wraps it in a code fence or ignores the format and writes a
/// bulleted list — small local models do both.
List<String> parseSmartReplies(String content) {
  var text = content.trim();
  // Thinking models narrate before they answer. The tagged form is easy;
  // an unclosed <think> means the reasoning ran to the end and there is no
  // answer in there at all.
  text = text
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) {
    return const [];
  }
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();

  // JSON or nothing. The old line-scraping fallback turned a model's prompt
  // analysis into chips — 'Sender: Joanne (Signal)' on a real notification —
  // and no suggestion beats a nonsensical one every time.
  List<String> candidates = const [];
  final objStart = text.indexOf('{');
  final objEnd = text.lastIndexOf('}');
  if (objStart >= 0 && objEnd > objStart) {
    try {
      final parsed = jsonDecode(text.substring(objStart, objEnd + 1));
      if (parsed is Map && parsed['replies'] is List) {
        candidates = (parsed['replies'] as List).whereType<String>().toList();
      }
    } on FormatException {
      // Try the bare-array spelling below.
    }
  }
  if (candidates.isEmpty) {
    final arrayStart = text.indexOf('[');
    final arrayEnd = text.lastIndexOf(']');
    if (arrayStart >= 0 && arrayEnd > arrayStart) {
      try {
        final parsed = jsonDecode(text.substring(arrayStart, arrayEnd + 1));
        if (parsed is List) candidates = parsed.whereType<String>().toList();
      } on FormatException {
        // Not JSON: no chips.
      }
    }
  }

  return [
    for (final reply in candidates)
      if (_looksLikeReply(reply.trim())) reply.trim(),
  ].take(2).toList(growable: false);
}

/// Whether [line] reads as something a person would send — and not a heading
/// out of a model's untagged reasoning ("Here's a thinking process:",
/// "**Analyze User Input:**"), which is what ended up on the notification as
/// a chip.
bool _looksLikeReply(String line) {
  if (line.isEmpty || line.length > 60) return false;
  if (line.endsWith(':')) return false;
  if (line.contains('**') || line.startsWith('#')) return false;
  // A label prefix — 'Sender: …', 'User name: …' — is the model describing
  // the conversation, not answering it.
  if (RegExp(r'^[A-Za-z][A-Za-z ]{1,20}:\s').hasMatch(line)) return false;
  // Template débris: placeholder ellipses and angle brackets are the format
  // being parroted, not a reply. A reply has letters in it.
  if (line.contains('<') || line.contains('>')) return false;
  if (!RegExp(r'\p{L}', unicode: true).hasMatch(line)) return false;
  return true;
}

/// Asks the endpoint for a trivial completion, purely to prove the wiring.
///
/// Returns null on success and the failure spelled out otherwise — the test
/// button's whole vocabulary.
Future<String?> probeLlm({
  required String baseUrl,
  required String model,
  String? apiKey,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty) return 'No base URL';
  if (model.trim().isEmpty) return 'No model name';
  final client = llmHttpClient();
  try {
    final response = await postLlm(
      client,
      Uri.parse('$base/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': 8,
        'messages': [
          {'role': 'user', 'content': 'Reply with the word OK.'},
        ],
      }),
      timeout: llmResponseTimeout(base, LlmTask.probe),
    );
    if (response.statusCode != 200) {
      return 'The server answered ${response.statusCode}';
    }
    return null;
  } on Object catch (error) {
    return 'Could not reach the server: $error';
  } finally {
    client.close();
  }
}
