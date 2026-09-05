import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:weft/services/ai/auto_reply_writer.dart';

/// What comes back from someone else's model, and what of it may be sent.
///
/// The bar here is higher than `parseSmartReplies`' and deliberately so: a chip
/// nobody taps costs nothing, and this text is *sent*, to a person, on WhatsApp,
/// and cannot be unsent. So the parser refuses everything that is not plainly a
/// message rather than making a best effort at one.
void main() {
  group('what is accepted', () {
    test('a plain sentence', () {
      expect(
        parseAutoReply('I am away until Monday and will read this then.'),
        'I am away until Monday and will read this then.',
      );
    });

    test('surrounding whitespace goes', () {
      expect(
        parseAutoReply('  Sure, see you at six.\n\n'),
        'Sure, see you at six.',
      );
    });

    test('a reply wrapped in quotes is unwrapped', () {
      expect(
        parseAutoReply('"Sure, see you at six."'),
        'Sure, see you at six.',
      );
      expect(
        parseAutoReply('“Sure, see you at six.”'),
        'Sure, see you at six.',
      );
    });

    test('a quotation inside the reply is left alone', () {
      // Only a pair wrapping the *whole* text is the model formatting; two
      // quoted phrases are two quotations.
      const text = 'She said "yes" and I said "fine".';
      expect(parseAutoReply(text), text);
    });

    test('a label the prompt invited is stripped', () {
      expect(parseAutoReply('Reply: I will be there.'), 'I will be there.');
      expect(parseAutoReply('Message: I will be there.'), 'I will be there.');
    });

    test('a fenced block is the answer inside it', () {
      expect(
        parseAutoReply('```\nI will be there at six.\n```'),
        'I will be there at six.',
      );
    });

    test("a thinking model's answer after its reasoning", () {
      expect(
        parseAutoReply(
          '<think>They asked about this afternoon. Ada is away.</think>\n'
          'I am away this afternoon, sorry.',
        ),
        'I am away this afternoon, sorry.',
      );
    });

    test('a reply that is only an emoji is refused, one with words is not', () {
      expect(parseAutoReply('👍'), isNull);
      expect(parseAutoReply('Sounds good 👍'), 'Sounds good 👍');
    });
  });

  group('what is refused', () {
    test('nothing at all', () {
      expect(parseAutoReply(''), isNull);
      expect(parseAutoReply('   \n  '), isNull);
    });

    test('reasoning that never came out of the tag', () {
      // An unclosed <think> means the budget ran out mid-thought; there is no
      // answer in there to send.
      expect(
        parseAutoReply('<think>Let me consider what Ada would say here and'),
        isNull,
      );
    });

    test('a heading, which is the model analysing rather than answering', () {
      expect(parseAutoReply("# Here's my reply"), isNull);
      expect(parseAutoReply('- I could say I am away'), isNull);
      expect(parseAutoReply('* Option one'), isNull);
    });

    test('a label with nothing after it', () {
      expect(parseAutoReply('The message to send:'), isNull);
    });

    test('punctuation with no letters in it', () {
      expect(parseAutoReply('...'), isNull);
      expect(parseAutoReply('---'), isNull);
    });
  });

  group('the length ceiling', () {
    test('a long reply is cut at a sentence boundary', () {
      final long = '${'This is a complete sentence. ' * 40}And a final one.';
      final capped = parseAutoReply(long)!;

      expect(capped.length, lessThanOrEqualTo(kAutoReplyMaxChars));
      expect(capped, endsWith('.'));
    });

    test('a run-on with no sentence end is refused, not truncated', () {
      // Six hundred characters with nothing to cut at is a model that has
      // stopped writing a message, and half of it is worse than none of it.
      expect(parseAutoReply('word ' * 200), isNull);
    });

    test('a reply just under the ceiling is untouched', () {
      final text = '${'a' * (kAutoReplyMaxChars - 1)}.';
      expect(parseAutoReply(text), text);
    });
  });

  group('the HTTP call', () {
    Future<AutoReplyDraft> ask({
      required http.Client client,
      String instruction = 'Say I am away.',
      List<String> transcript = const ['Grace: are you around?'],
    }) => composeAutoReply(
      baseUrl: 'http://localhost:11434/v1',
      model: 'llama3',
      instruction: instruction,
      chatTitle: 'Grace',
      transcript: transcript,
      client: client,
      timeout: const Duration(seconds: 1),
    );

    http.Client answering(String content) => MockClient((request) async {
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': content},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    test('an ordinary completion becomes a draft', () async {
      final draft = await ask(client: answering('I am away until Monday.'));

      expect(draft.outcome, AutoReplyOutcome.sent);
      expect(draft.text, 'I am away until Monday.');
    });

    test("the user's instruction is in the request body", () async {
      String? body;
      final client = MockClient((request) async {
        body = request.body;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Away.'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      await ask(client: client, instruction: 'Answer only in Welsh.');

      expect(body, contains('Answer only in Welsh.'));
    });

    test('no endpoint is a typed refusal rather than a request', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('', 200);
      });

      final draft = await composeAutoReply(
        baseUrl: '   ',
        model: 'llama3',
        instruction: 'Say I am away.',
        chatTitle: 'Grace',
        transcript: const ['Grace: hello'],
        client: client,
      );

      expect(draft.outcome, AutoReplyOutcome.notConfigured);
      expect(called, isFalse);
    });

    test('an empty instruction is refused before anything is sent', () async {
      final draft = await ask(
        client: answering('anything'),
        instruction: '   ',
      );

      expect(draft.outcome, AutoReplyOutcome.notConfigured);
    });

    test('an error status reads as unreachable', () async {
      final draft = await ask(
        client: MockClient((_) async => http.Response('nope', 500)),
      );

      expect(draft.outcome, AutoReplyOutcome.unreachable);
      expect(draft.text, isNull);
    });

    test(
      'a socket failure reads as unreachable rather than throwing',
      () async {
        final draft = await ask(
          client: MockClient((_) async => throw const _Unreachable()),
        );

        expect(draft.outcome, AutoReplyOutcome.unreachable);
      },
    );

    test('a slow model reads as timed out', () async {
      final draft = await ask(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 3));
          return http.Response('{}', 200);
        }),
      );

      expect(draft.outcome, AutoReplyOutcome.timedOut);
    });

    test('a completion with no content reads as refused', () async {
      final draft = await ask(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'choices': <Object>[]}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );

      expect(draft.outcome, AutoReplyOutcome.refused);
    });

    test('a completion the parser will not take reads as refused', () async {
      final draft = await ask(client: answering('# Here is my plan'));

      expect(draft.outcome, AutoReplyOutcome.refused);
      expect(draft.text, isNull);
    });
  });
}

class _Unreachable implements Exception {
  const _Unreachable();
}
