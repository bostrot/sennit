import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// Asks the configured LLM for one or two short answers to a conversation.
///
/// OpenAI-compatible chat completions, which is what every self-hostable
/// server speaks — Ollama, llama.cpp, LocalAI, vLLM — as well as the hosted
/// ones. Returns at most two suggestions; an empty list on any failure,
/// because a notification is not the place for an error message.
Future<List<String>> suggestSmartReplies({
  required String baseUrl,
  required String model,
  String? apiKey,
  required String chatTitle,
  required List<String> transcript,
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || transcript.isEmpty) {
    return const [];
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
            'temperature': 0.7,
            'max_tokens': 120,
            'messages': [
              {
                'role': 'system',
                'content':
                    'You suggest quick replies the user could send in a '
                    'messaging app. Answer with ONLY a JSON array of one or '
                    'two strings, each a complete reply of at most eight '
                    'words, in the same language as the conversation. No '
                    'explanations.',
              },
              {
                'role': 'user',
                'content':
                    'Conversation "$chatTitle" (the user is "You", newest '
                    'message last):\n${transcript.join('\n')}\n\n'
                    'Suggest replies the user could send now.',
              },
            ],
          }),
        )
        .timeout(timeout);
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

/// Pulls at most two usable suggestions out of whatever the model said.
///
/// The happy path is the JSON array the prompt demands; the fallbacks cover
/// a model that wraps it in a code fence or ignores the format and writes a
/// bulleted list — small local models do both.
List<String> parseSmartReplies(String content) {
  var text = content.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();

  List<String> candidates = const [];
  final arrayStart = text.indexOf('[');
  final arrayEnd = text.lastIndexOf(']');
  if (arrayStart >= 0 && arrayEnd > arrayStart) {
    try {
      final parsed = jsonDecode(text.substring(arrayStart, arrayEnd + 1));
      if (parsed is List) candidates = parsed.whereType<String>().toList();
    } on FormatException {
      // Fall through to the line parser.
    }
  }
  if (candidates.isEmpty) {
    candidates = [
      for (final line in text.split('\n'))
        line
            .replaceFirst(RegExp(r'''^\s*(?:[-*•\d.)]+\s*)?["']?'''), '')
            .replaceFirst(RegExp(r'''["']?\s*$'''), ''),
    ];
  }

  return [
    for (final reply in candidates)
      if (reply.trim().isNotEmpty && reply.trim().length <= 60) reply.trim(),
  ].take(2).toList(growable: false);
}
