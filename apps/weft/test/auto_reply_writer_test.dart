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
  /// What [inner] comes to when the model answers in the format.
  String? reply(String inner) => parseAutoReply('<reply>$inner</reply>').text;

  group('the answer format', () {
    test('a tagged message is the reply', () {
      final draft = parseAutoReply('<reply>Sure, see you at six.</reply>');

      expect(draft.outcome, AutoReplyOutcome.sent);
      expect(draft.text, 'Sure, see you at six.');
    });

    test('an answer outside the format is never sent', () {
      // The bug this exists for: a thinking model's narration, untagged, read
      // as a sentence and went out.
      final draft = parseAutoReply(
        'Okay, Grace is asking whether Ada can make Friday. The instruction '
        'says to say she is away, so I should write something short.',
      );

      expect(draft.outcome, AutoReplyOutcome.refused);
      expect(draft.text, isNull);
    });

    test('reasoning around the tags is thrown away', () {
      expect(
        parseAutoReply(
          'Grace wants to know about Friday. Ada is away, so a short note.\n'
          '<reply>I am away on Friday, sorry.</reply>\n'
          'That keeps it brief.',
        ).text,
        'I am away on Friday, sorry.',
      );
    });

    test("a thinking model's tagged reasoning is thrown away", () {
      expect(
        parseAutoReply(
          '<think>I could answer <reply>Maybe</reply> but no.</think>\n'
          '<reply>I am away this afternoon, sorry.</reply>',
        ).text,
        'I am away this afternoon, sorry.',
      );
    });

    test('the last tagged message wins over a draft in the reasoning', () {
      expect(
        parseAutoReply(
          'First try: <reply>Yo.</reply> Too casual. Better:\n'
          '<reply>I will get back to you tonight.</reply>',
        ).text,
        'I will get back to you tonight.',
      );
    });

    test('text whose lower case is longer does not shift the message', () {
      // 'İ' lower-cases to two code units; offsets taken from a lower-cased
      // copy would cut the wrong slice out of the original.
      expect(
        parseAutoReply('İİİİ İstanbul? <reply>I land at six.</reply>').text,
        'I land at six.',
      );
    });

    test('tags in any case are read', () {
      expect(parseAutoReply('<REPLY>On my way.</Reply>').text, 'On my way.');
    });

    test('a message opened and never closed is refused', () {
      // The budget ran out mid-message.
      expect(
        parseAutoReply('<reply>I am away until Monday and will').outcome,
        AutoReplyOutcome.refused,
      );
    });

    test('a message the model ended without its closing tag is sent', () {
      // Small models drop the closing tag. When the model stopped by itself
      // the message is all there.
      expect(
        parseAutoReply('<reply>I am away until Monday.', finished: true).text,
        'I am away until Monday.',
      );
    });

    test('what the model wrote after a forgotten tag is not sent', () {
      expect(
        parseAutoReply(
          '<reply>I am away until Monday.\n\nI kept it short because the '
          'instruction asked for that.',
          finished: true,
        ).text,
        'I am away until Monday.',
      );
    });

    test('a mangled closing tag is refused, not sent', () {
      expect(
        parseAutoReply(
          '<reply>I am away until Monday.</repl',
          finished: true,
        ).outcome,
        AutoReplyOutcome.refused,
      );
    });

    test('a finished answer still needs to open the tag', () {
      expect(
        parseAutoReply('I am away until Monday.', finished: true).outcome,
        AutoReplyOutcome.refused,
      );
    });

    test('a thought that never ended is refused even when finished', () {
      expect(
        parseAutoReply('<think>Maybe <reply>I am away', finished: true).outcome,
        AutoReplyOutcome.refused,
      );
    });

    test('an empty message is refused', () {
      expect(
        parseAutoReply('<reply>  </reply>').outcome,
        AutoReplyOutcome.refused,
      );
    });

    test('reasoning that never came out of the tag', () {
      // An unclosed <think> means the budget ran out mid-thought; there is no
      // answer in there to send.
      expect(
        parseAutoReply(
          '<think>Let me consider <reply>what Ada would say</reply> and',
        ).outcome,
        AutoReplyOutcome.refused,
      );
    });
  });

  group('choosing not to reply', () {
    test('the decline marker is a decline, not a failure', () {
      final draft = parseAutoReply('<no-reply/>');

      expect(draft.outcome, AutoReplyOutcome.declined);
      expect(draft.text, isNull);
    });

    test('spellings a model is likely to use are all a decline', () {
      for (final marker in ['<no_reply/>', '<NO-REPLY />', '<no-reply>']) {
        expect(
          parseAutoReply(marker).outcome,
          AutoReplyOutcome.declined,
          reason: marker,
        );
      }
    });

    test('a decline after a drafted reply wins', () {
      expect(
        parseAutoReply(
          'Maybe <reply>See you then.</reply>? No — they said not to answer '
          'work chats. <no-reply/>',
        ).outcome,
        AutoReplyOutcome.declined,
      );
    });

    test('a reply after a considered decline wins', () {
      expect(
        parseAutoReply(
          'I could stay quiet with <no-reply/>, but they asked directly.\n'
          '<reply>I am away until Monday.</reply>',
        ).text,
        'I am away until Monday.',
      );
    });
  });

  group('what is accepted', () {
    test('a plain sentence', () {
      expect(
        reply('I am away until Monday and will read this then.'),
        'I am away until Monday and will read this then.',
      );
    });

    test('surrounding whitespace goes', () {
      expect(reply('  Sure, see you at six.\n\n'), 'Sure, see you at six.');
    });

    test('a reply wrapped in quotes is unwrapped', () {
      expect(reply('"Sure, see you at six."'), 'Sure, see you at six.');
      expect(reply('“Sure, see you at six.”'), 'Sure, see you at six.');
    });

    test('a quotation inside the reply is left alone', () {
      // Only a pair wrapping the *whole* text is the model formatting; two
      // quoted phrases are two quotations.
      const text = 'She said "yes" and I said "fine".';
      expect(reply(text), text);
    });

    test('a label the prompt invited is stripped', () {
      expect(reply('Reply: I will be there.'), 'I will be there.');
      expect(reply('Message: I will be there.'), 'I will be there.');
    });

    test('a fenced block is the answer inside it', () {
      expect(
        reply('```\nI will be there at six.\n```'),
        'I will be there at six.',
      );
    });

    test('a reply that is only an emoji is refused, one with words is not', () {
      expect(reply('👍'), isNull);
      expect(reply('Sounds good 👍'), 'Sounds good 👍');
    });
  });

  group('what is refused', () {
    test('nothing at all', () {
      expect(reply(''), isNull);
      expect(reply('   \n  '), isNull);
    });

    test('a heading, which is the model analysing rather than answering', () {
      expect(reply("# Here's my reply"), isNull);
      expect(reply('- I could say I am away'), isNull);
      expect(reply('* Option one'), isNull);
    });

    test('a label with nothing after it', () {
      expect(reply('The message to send:'), isNull);
    });

    test('punctuation with no letters in it', () {
      expect(reply('...'), isNull);
      expect(reply('---'), isNull);
    });
  });

  group('the length ceiling', () {
    test('a long reply is cut at a sentence boundary', () {
      final long = '${'This is a complete sentence. ' * 40}And a final one.';
      final capped = reply(long)!;

      expect(capped.length, lessThanOrEqualTo(kAutoReplyMaxChars));
      expect(capped, endsWith('.'));
    });

    test('a run-on with no sentence end is refused, not truncated', () {
      // Six hundred characters with nothing to cut at is a model that has
      // stopped writing a message, and half of it is worse than none of it.
      expect(reply('word ' * 200), isNull);
    });

    test('a reply just under the ceiling is untouched', () {
      final text = '${'a' * (kAutoReplyMaxChars - 1)}.';
      expect(reply(text), text);
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

    http.Client answering(String content, {String? finishReason}) =>
        MockClient((request) async {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': content},
                  'finish_reason': ?finishReason,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });

    test('an ordinary completion becomes a draft', () async {
      final draft = await ask(
        client: answering('<reply>I am away until Monday.</reply>'),
      );

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

    test('the request asks for the answer format', () async {
      String? body;
      final client = MockClient((request) async {
        body = request.body;
        return http.Response('{}', 500);
      });

      await ask(client: client);

      expect(body, contains(kAutoReplyOpen));
      expect(body, contains(kAutoReplyDecline));
    });

    test('a decline reads as declined, with nothing to send', () async {
      final draft = await ask(client: answering('<no-reply/>'));

      expect(draft.outcome, AutoReplyOutcome.declined);
      expect(draft.text, isNull);
    });

    test('a completion the parser will not take reads as refused', () async {
      final draft = await ask(client: answering('# Here is my plan'));

      expect(draft.outcome, AutoReplyOutcome.refused);
      expect(draft.text, isNull);
    });

    test('a model that stopped without closing the tag is sent', () async {
      final draft = await ask(
        client: answering('<reply>Back on Monday.', finishReason: 'stop'),
      );

      expect(draft.text, 'Back on Monday.');
    });

    test('a model cut off by the budget mid-message is refused', () async {
      final draft = await ask(
        client: answering('<reply>Back on Monday, and', finishReason: 'length'),
      );

      expect(draft.outcome, AutoReplyOutcome.refused);
    });

    test('the budget leaves a thinking model room to answer', () async {
      String? body;
      final client = MockClient((request) async {
        body = request.body;
        return http.Response('{}', 500);
      });

      await ask(client: client);

      final asked = (jsonDecode(body!) as Map)['max_tokens'] as int;
      expect(asked, kAutoReplyMaxTokens);
      // Reasoning spends the same budget as the reply. 220 was all spent
      // inside <think>, and nothing was ever sent.
      expect(asked, greaterThanOrEqualTo(1024));
    });
  });
}

class _Unreachable implements Exception {
  const _Unreachable();
}
