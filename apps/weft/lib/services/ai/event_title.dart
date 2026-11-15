import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// Asks the configured LLM what to call the appointment a message is about.
///
/// The same OpenAI-compatible chat completions call as [suggestSmartReplies],
/// for the same reason. Returns null on any failure: the caller already has a
/// rule-made title, and a calendar entry is not the place for an error.
Future<String?> suggestEventTitle({
  required String baseUrl,
  required String model,
  String? apiKey,
  required String message,
  http.Client? client,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || message.trim().isEmpty) {
    return null;
  }
  final url = Uri.parse('$base/chat/completions');
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            if (apiKey != null && apiKey.isNotEmpty)
              'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': model,
            'temperature': 0.2,
            'max_tokens': 60,
            'messages': [
              {
                'role': 'system',
                'content':
                    'You name calendar events. Given a chat message about an '
                    'appointment, output ONLY a JSON object with a "title" '
                    'string — no analysis, no commentary, no markdown. The '
                    'title says what the event is in at most five words, in '
                    'the same language as the message, without its date or '
                    'time.',
              },
              // Worked examples, as in the reply prompt: they pin the format
              // and leave no placeholder to parrot back.
              {
                'role': 'user',
                'content':
                    'Message:\nHey, hast du am Dienstag um 14:30 Zeit? Dann '
                    'könnten wir zusammen zum Zahnarzt gehen.\n\nJSON:',
              },
              {'role': 'assistant', 'content': '{"title": "Zahnarzt"}'},
              {
                'role': 'user',
                'content':
                    'Message:\nlet\'s grab dinner with Sam on friday at 7 '
                    'pm?\n\nJSON:',
              },
              {'role': 'assistant', 'content': '{"title": "Dinner with Sam"}'},
              {'role': 'user', 'content': 'Message:\n$message\n\nJSON:'},
            ],
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      debugPrint('weft: event title: $url answered ${response.statusCode}');
      return null;
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final content =
        ((decoded as Map)['choices'] as List?)
                ?.cast<Map>()
                .firstOrNull?['message']?['content']
            as String?;
    if (content == null) {
      debugPrint('weft: event title: no content in the completion');
      return null;
    }
    final title = parseEventTitle(content);
    if (title == null) {
      debugPrint('weft: event title: nothing usable in ${jsonEncode(content)}');
    }
    return title;
  } on Object catch (error) {
    debugPrint('weft: event title against $url failed: $error');
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

/// Pulls the title out of whatever the model said, or null.
///
/// JSON or nothing, as with reply chips: a model's untagged reasoning must
/// not become the name of somebody's dentist appointment.
String? parseEventTitle(String content) {
  var text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) return null;
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();

  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  final Object? parsed;
  try {
    parsed = jsonDecode(text.substring(start, end + 1));
  } on FormatException {
    return null;
  }
  if (parsed is! Map || parsed['title'] is! String) return null;

  final title = (parsed['title'] as String).trim().replaceAll(
    RegExp(r'\s+'),
    ' ',
  );
  if (title.isEmpty || title.length > 60) return null;
  if (title.contains('<') || title.contains('>') || title.contains('**')) {
    return null;
  }
  if (!RegExp(r'\p{L}', unicode: true).hasMatch(title)) return null;
  return title;
}
