import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/chat/translation_sheet.dart';
import 'package:weft/services/ai/translate_message.dart';
import 'package:weft_design/weft_design.dart';

/// Translating a message with the user's own model: the prompt, reading the
/// answer, and the sheet that shows it.
void main() {
  group('parseTranslation', () {
    test('takes the text between the tags', () {
      expect(
        parseTranslation('Sure!\n<translation>Hallo Welt</translation>'),
        'Hallo Welt',
      );
    });

    test('drops reasoning and keeps line breaks', () {
      expect(
        parseTranslation(
          '<think>German, informal</think><translation>Hallo\n\nbis '
          'gleich</translation>',
        ),
        'Hallo\n\nbis gleich',
      );
    });

    test('takes an untagged answer whole', () {
      expect(parseTranslation('  Hola  '), 'Hola');
    });

    test('a model still thinking gave nothing', () {
      expect(parseTranslation('<think>Let me see'), isNull);
      expect(parseTranslation('<translation></translation>'), isNull);
    });
  });

  test('the prompt names the language in English', () {
    final request = translationRequest(text: 'hi', language: 'de');
    expect(request.first['content'], contains('into German'));
    expect(request.last, {'role': 'user', 'content': 'hi'});
  });

  test('the default language is the app\'s, or English', () {
    expect(defaultTranslationLanguage('de'), 'de');
    expect(defaultTranslationLanguage('xx'), 'en');
  });

  group('translateMessage', () {
    Future<TranslationResult> ask(http.Client client) => translateMessage(
      baseUrl: 'http://llm.test/v1/',
      model: 'm',
      text: 'Bonjour',
      language: 'en',
      client: client,
    );

    test('sends the message and reads the translation', () async {
      late Map<String, Object?> body;
      final result = await ask(
        MockClient((request) async {
          expect(request.url.toString(), 'http://llm.test/v1/chat/completions');
          body = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '<translation>Hello</translation>'},
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(result.text, 'Hello');
      expect(result.failure, isNull);
      expect(jsonEncode(body['messages']), contains('Bonjour'));
    });

    test('a refusal is unreachable, an empty answer is empty', () async {
      expect(
        (await ask(MockClient((_) async => http.Response('no', 500)))).failure,
        TranslationFailure.unreachable,
      );
      expect(
        (await ask(
          MockClient(
            (_) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': ''},
                  },
                ],
              }),
              200,
            ),
          ),
        )).failure,
        TranslationFailure.empty,
      );
    });
  });

  group('the sheet', () {
    Future<void> open(
      WidgetTester tester,
      Future<TranslationResult> Function(String) translate, {
      void Function(String)? onLanguage,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTranslationSheet(
                  context,
                  text: 'Bonjour à tous',
                  language: 'en',
                  translate: translate,
                  onLanguage: onLanguage ?? (_) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
    }

    testWidgets('shows the translation once it comes', (tester) async {
      final answer = Completer<TranslationResult>();
      await open(tester, (_) => answer.future);
      expect(find.text('Translating…'), findsOneWidget);

      answer.complete((text: 'Hello everyone', failure: null));
      await tester.pumpAndSettle();

      expect(find.text('Hello everyone'), findsOneWidget);
      expect(find.text('Bonjour à tous'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('a failure says why and can be retried', (tester) async {
      var calls = 0;
      await open(tester, (_) async {
        calls++;
        return calls == 1
            ? (text: null, failure: TranslationFailure.timedOut)
            : (text: 'Hello', failure: null);
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Your AI model took too long to answer.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('picking a language remembers it and translates again', (
      tester,
    ) async {
      final asked = <String>[];
      final remembered = <String>[];
      await open(tester, (language) async {
        asked.add(language);
        return (text: 'in $language', failure: null);
      }, onLanguage: remembered.add);
      await tester.pumpAndSettle();

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deutsch').last);
      await tester.pumpAndSettle();

      expect(asked, ['en', 'de']);
      expect(remembered, ['de']);
      expect(find.text('in de'), findsOneWidget);
    });
  });
}
