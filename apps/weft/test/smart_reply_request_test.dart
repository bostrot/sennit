import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/services/ai/llm_budget.dart';
import 'package:weft/services/ai/llm_request.dart';
import 'package:weft/services/ai/smart_replies.dart';

/// What the reply chips ask a thinking model for: an answer without the
/// thinking.
///
/// Measured against a Qwen behind litellm: five to twelve seconds with its
/// reasoning, one to two without, for the same two eight-word answers.
void main() {
  const local = 'http://localhost:4000/v1';
  const hosted = 'https://api.openai.com/v1';

  http.Response completion(String content) => http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': content},
          'finish_reason': 'stop',
        },
      ],
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  /// A server that answers with [respond] and records every body it was
  /// sent.
  (http.Client, List<Map<String, Object?>>) server(
    http.Response Function(Map<String, Object?> body) respond,
  ) {
    final bodies = <Map<String, Object?>>[];
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      bodies.add(body);
      return respond(body);
    });
    return (client, bodies);
  }

  Future<List<String>> ask(
    http.Client client, {
    String baseUrl = local,
    bool thinking = true,
    Duration? timeout,
  }) => suggestSmartReplies(
    baseUrl: baseUrl,
    model: 'qwen3.8-flash-next-q2_0',
    chatTitle: 'Anna',
    transcript: const ['Anna: Soll ich drei Tickets kaufen?'],
    budget: LlmBudget.resolve(baseUrl, LlmModelSettings(thinking: thinking)),
    client: client,
    timeout: timeout,
  );

  group('noThinkingOptions', () {
    test('a self-hosted server is told both ways servers understand', () {
      expect(noThinkingOptions(local), {
        'reasoning_effort': 'none',
        'chat_template_kwargs': {'enable_thinking': false},
      });
      expect(
        noThinkingOptions('http://192.168.1.20:11434/v1'),
        contains('reasoning_effort'),
        reason: 'Ollama reads reasoning_effort',
      );
    });

    test('a hosted API gets only the effort every reasoning model takes', () {
      for (final api in [
        hosted,
        'https://openrouter.ai/api/v1',
        'https://api.groq.com/openai/v1',
      ]) {
        expect(noThinkingOptions(api), {
          'reasoning_effort': 'low',
        }, reason: api);
      }
    });
  });

  group('suggestSmartReplies', () {
    test('asks a thinking model not to think', () async {
      final (client, bodies) = server(
        (_) => completion('{"replies": ["Ja, kauf sie!"]}'),
      );

      expect(await ask(client), ['Ja, kauf sie!']);
      expect(bodies.single['reasoning_effort'], 'none');
      expect(bodies.single['chat_template_kwargs'], {'enable_thinking': false});
    });

    test('leaves a model marked as not thinking alone', () async {
      final (client, bodies) = server(
        (_) => completion('{"replies": ["Ja!"]}'),
      );

      await ask(client, thinking: false);

      expect(bodies.single, isNot(contains('reasoning_effort')));
      expect(bodies.single, isNot(contains('chat_template_kwargs')));
    });

    test('a hosted thinking model is asked for low effort', () async {
      final (client, bodies) = server(
        (_) => completion('{"replies": ["Yes!"]}'),
      );

      await ask(client, baseUrl: hosted);

      expect(bodies.single['reasoning_effort'], 'low');
      expect(bodies.single, isNot(contains('chat_template_kwargs')));
    });

    test('a server that refuses the switch is asked again without', () async {
      // gpt-4o and friends answer 400 to reasoning_effort: the chips are
      // worth more than the switch.
      final (client, bodies) = server(
        (body) => body.containsKey('reasoning_effort')
            ? http.Response('{"error": "unknown parameter"}', 400)
            : completion('{"replies": ["Yes!"]}'),
      );

      expect(await ask(client, baseUrl: hosted), ['Yes!']);
      expect(bodies, hasLength(2));
      expect(bodies.last, isNot(contains('reasoning_effort')));
    });

    test('any other failure is not retried', () async {
      final (client, bodies) = server(
        (_) => http.Response('{"error": "down"}', 500),
      );

      expect(await ask(client), isEmpty);
      expect(bodies, hasLength(1));
    });

    test('the answer stays short', () async {
      final (client, bodies) = server(
        (_) => completion('{"replies": ["Ja!"]}'),
      );

      await ask(client);

      expect(
        bodies.single['max_tokens'] as int,
        lessThanOrEqualTo(1024),
        reason: 'room to think briefly, should the switch be ignored',
      );
      await ask(client, thinking: false);
      expect(bodies.last['max_tokens'], 120);
    });

    test('a timeout reaches the caller, to be counted as late', () async {
      final client = MockClient((_) => Completer<http.Response>().future);

      await expectLater(
        ask(client, timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('smartReplyTimeout', () {
    test('a self-hosted model gets the time a busy GPU takes', () {
      expect(smartReplyTimeout(local), const Duration(seconds: 25));
    });

    test('a hosted API keeps a short one', () {
      expect(smartReplyTimeout(hosted), const Duration(seconds: 10));
    });
  });
}
