import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:weft/services/ai/event_title.dart';

void main() {
  http.Client answering(String content, {int status = 200}) =>
      MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': content},
              },
            ],
          }),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

  Future<String?> ask(http.Client client) => suggestEventTitle(
    baseUrl: 'http://llm.test/v1/',
    model: 'small',
    message: 'Zahnarzt am Dienstag um 14:30',
    client: client,
  );

  test('the model names the event', () async {
    expect(await ask(answering('{"title": "Zahnarzt"}')), 'Zahnarzt');
  });

  test('the message is what the model is asked about', () async {
    late Map<String, Object?> body;
    final client = MockClient((request) async {
      expect(request.url.toString(), 'http://llm.test/v1/chat/completions');
      body = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response('{"choices": []}', 200);
    });
    expect(await ask(client), isNull);
    final last = (body['messages']! as List).last as Map;
    expect(last['content'], contains('Zahnarzt am Dienstag um 14:30'));
  });

  test('a failing endpoint is no title, not an error', () async {
    expect(await ask(answering('{"title": "Zahnarzt"}', status: 500)), isNull);
    expect(
      await ask(MockClient((_) async => throw http.ClientException('down'))),
      isNull,
    );
  });

  group('parseEventTitle', () {
    test('takes fenced JSON and drops tagged thinking', () {
      expect(
        parseEventTitle(
          '<think>hm</think>```json\n{"title": " Team  lunch "}\n```',
        ),
        'Team lunch',
      );
    });

    test('refuses anything that is not a title', () {
      expect(parseEventTitle('Here is a title: Dentist'), isNull);
      expect(parseEventTitle('<think>still thinking'), isNull);
      expect(parseEventTitle('{"title": ""}'), isNull);
      expect(parseEventTitle('{"title": "<title>"}'), isNull);
      expect(parseEventTitle('{"title": "${'a' * 61}"}'), isNull);
      expect(parseEventTitle('{"title": 42}'), isNull);
    });
  });
}
