import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/services/ai/auto_reply_writer.dart';
import 'package:weft/services/ai/event_title.dart';
import 'package:weft/services/ai/quick_messages.dart';

/// Quick messages: the name, the language, the prompt, and what comes back.
///
/// The flow through the chat view is `quick_message_flow_test.dart`; this is
/// the part of it that decides what the model is told.
void main() {
  group('firstNameOf', () {
    final cases = {
      'Anna Müller': 'Anna',
      'Anna Müller (WhatsApp)': 'Anna',
      'Anna [Telegram]': 'Anna',
      '🌸 Anna 🌸': 'Anna',
      'Müller, Anna': 'Anna',
      'Dr. Anna Müller': 'Anna',
      'Frau Müller': 'Müller',
      'Anna "Annie" Müller': 'Annie',
      'Jean-Luc Picard': 'Jean-Luc',
      "D'Arcy Smith": "D'Arcy",
      'anna.mueller': 'Anna',
      'sam': 'Sam',
      'Sam - Work': 'Sam',
      'Zoë': 'Zoë',
      '王小明': '王小明',
      '@anna:matrix.org': null,
      'anna@example.com': null,
      '+49 170 1234567': null,
      '🎉🎉': null,
      '': null,
      '   ': null,
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      test('"$key" → $value', () => expect(firstNameOf(key), value));
    }
    test('null is no name', () => expect(firstNameOf(null), isNull));
  });

  group('detectChatLanguage', () {
    test('German from both sides', () {
      expect(
        detectChatLanguage(const [
          'Anna Müller: Kommst du morgen mit?',
          'You: Ja, ich bin dabei!',
        ], fallback: 'en'),
        'de',
      );
    });

    test('the names do not vote', () {
      // "Ich" in a name would tip a naive count to German.
      expect(
        detectChatLanguage(const [
          'Ich Bin Anna: see you at the station, it is the last train',
        ], fallback: 'de'),
        'en',
      );
    });

    test('French, Spanish, Portuguese', () {
      expect(
        detectChatLanguage(const [
          'Claire: Je suis malade, pas de bureau pour moi',
        ], fallback: 'en'),
        'fr',
      );
      expect(
        detectChatLanguage(const [
          'Lucía: ¿A qué hora llegáis mañana? Estoy en casa',
        ], fallback: 'en'),
        'es',
      );
      expect(
        detectChatLanguage(const [
          'João: Oi, tudo bem? Você vem hoje?',
        ], fallback: 'en'),
        'pt',
      );
    });

    test('a script settles it', () {
      expect(detectChatLanguage(const ['小明: 你明天来吗？'], fallback: 'en'), 'zh');
      expect(
        detectChatLanguage(const ['Yuki: 明日は来ますか？'], fallback: 'en'),
        'ja',
      );
      expect(
        detectChatLanguage(const ['Олег: Ты завтра придёшь?'], fallback: 'en'),
        'ru',
      );
    });

    test('nothing to go on is the app language', () {
      expect(detectChatLanguage(const [], fallback: 'fr'), 'fr');
      expect(detectChatLanguage(const ['Anna: 👍'], fallback: 'de'), 'de');
      expect(detectChatLanguage(const ['Anna: ok'], fallback: 'pt'), 'pt');
    });
  });

  group('quickMessageRequest', () {
    List<Map<String, String>> birthday({
      String? recipient,
      String? groupName,
      String language = 'de',
      List<String> transcript = const ['Anna Müller: Bis Samstag!'],
    }) => quickMessageRequest(
      instruction: kQuickMessageDefaultPrompts[QuickMessagePreset.birthday]!,
      transcript: transcript,
      language: language,
      recipient: recipient,
      groupName: groupName,
    );

    test('the task, the name and the language come last, after the chat', () {
      final last = birthday(recipient: 'Anna').last['content']!;
      expect(last, contains('Anna Müller: Bis Samstag!'));
      expect(last, contains('It is for: Anna'));
      expect(last, contains('Write it in: German'));
      expect(
        last.indexOf('New message to write:'),
        greaterThan(last.indexOf('Bis Samstag')),
      );
    });

    test('a group is addressed as one', () {
      final last = birthday(groupName: 'Familie').last['content']!;
      expect(last, contains('the group chat "Familie"'));
    });

    test('no name known is said, never invented', () {
      final messages = birthday();
      expect(messages.last['content'], contains('no name known'));
      expect(messages.first['content'], contains('never invent a name'));
    });

    test('a language without a name in the table is still asked for', () {
      expect(
        birthday(language: 'xx').last['content'],
        contains('the language of the recent messages'),
      );
    });

    test('an empty chat says so', () {
      expect(
        birthday(transcript: const []).last['content'],
        contains('(no messages yet)'),
      );
    });
  });

  group('recentConversationTranscript', () {
    final start = DateTime(2026, 11, 20, 18);
    var seq = 0;
    WeftMessage msg(
      String body, {
      bool own = false,
      int minute = 0,
      String? thread,
      bool redacted = false,
    }) => WeftMessage(
      eventId: '\$${seq++}',
      roomId: '!room:x',
      network: ChatNetwork.matrix,
      senderId: own ? '@me:x' : '@anna:x',
      senderName: own ? 'Eric' : 'Anna',
      timestamp: start.add(Duration(minutes: minute)),
      kind: MessageKind.text,
      isOwn: own,
      body: body,
      redacted: redacted,
      threadRootId: thread,
    );

    test('the newest, oldest first, without threads or redactions', () {
      final lines = recentConversationTranscript([
        // Newest first, as the chat view holds them.
        msg('see you', own: true, minute: 3),
        msg('in a thread', minute: 2, thread: r'$root'),
        msg('deleted', minute: 2, redacted: true),
        msg('dinner at 8?', minute: 1),
        msg('hi', minute: 0),
      ], maxMessages: 2);
      expect(lines, ['Anna: dinner at 8?', 'You: see you']);
    });
  });

  group('parseQuickMessage', () {
    test('plain text, tidied', () {
      expect(
        parseQuickMessage('  "Alles Gute, Anna! 🎂"  '),
        'Alles Gute, Anna! 🎂',
      );
      expect(parseQuickMessage('Message: Happy birthday!'), 'Happy birthday!');
      expect(
        parseQuickMessage("Here's your message: Happy birthday, Sam!"),
        'Happy birthday, Sam!',
      );
      expect(
        parseQuickMessage('Happy birthday!\n\nThis message is warm because…'),
        'Happy birthday!',
      );
    });

    test('reasoning is dropped, and reasoning alone is nothing', () {
      expect(
        parseQuickMessage('<think>German, short.</think>Alles Gute!'),
        'Alles Gute!',
      );
      expect(parseQuickMessage('<think>Let me see, the user'), isNull);
    });

    test('the auto-reply tags are read when a model uses them', () {
      expect(
        parseQuickMessage('<reply>Gute Besserung!</reply>'),
        'Gute Besserung!',
      );
    });

    test('no letters is no message', () {
      expect(parseQuickMessage('🎉'), isNull);
      expect(parseQuickMessage(''), isNull);
    });
  });

  group('QuickMessage', () {
    test('an untouched list is the defaults, Happy Birthday first', () {
      final list = QuickMessage.listFromJson(null);
      expect(list.first.preset, QuickMessagePreset.birthday);
      expect(list.length, QuickMessagePreset.values.length);
      expect(list.first.title, isNull, reason: 'the title follows the ARB');
      expect(list.first.effectivePrompt, contains('birthday'));
    });

    test('a round trip keeps order, edits and the user\'s own', () {
      final list = [
        const QuickMessage(
          id: 'mine',
          title: 'Coffee?',
          emoji: '☕',
          prompt: 'Ask if they want coffee this week.',
        ),
        QuickMessage.builtIn(
          QuickMessagePreset.thanks,
        ).copyWith(prompt: 'Thank them for dinner.'),
      ];
      final back = QuickMessage.listFromJson(
        jsonDecode(jsonEncode(QuickMessage.listToJson(list)))
            as Map<String, Object?>,
      );
      expect(back, list);
      expect(back.last.effectivePrompt, 'Thank them for dinner.');
    });

    test('an emptied list stays empty', () {
      expect(QuickMessage.listFromJson({'messages': <Object?>[]}), isEmpty);
    });

    test('what this build cannot read is dropped, the rest kept', () {
      final list = QuickMessage.listFromJson({
        'messages': [
          {'id': 'future', 'preset': 'anniversary'},
          {'id': 'blank', 'title': '', 'prompt': 'x'},
          'garbage',
          {'id': 'preset:getWell', 'preset': 'getWell'},
        ],
      });
      expect(list.map((m) => m.id), ['preset:getWell']);
    });
  });

  group('composeQuickMessage', () {
    late Map<String, Object?> sent;
    http.Client answering(String content, {int status = 200}) =>
        MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': content},
                  'finish_reason': 'stop',
                },
              ],
            }),
            status,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });

    Future<AutoReplyDraft> ask(http.Client client) => composeQuickMessage(
      baseUrl: 'http://llm.test/v1/',
      model: 'small',
      instruction: kQuickMessageDefaultPrompts[QuickMessagePreset.birthday]!,
      transcript: const ['Anna Müller: Bis Samstag!'],
      language: 'de',
      recipient: 'Anna',
      client: client,
    );

    test('the model\'s words, for the composer', () async {
      final draft = await ask(answering('Alles Gute zum Geburtstag, Anna! 🎂'));
      expect(draft.text, 'Alles Gute zum Geburtstag, Anna! 🎂');
      expect(sent['model'], 'small');
      final messages = (sent['messages']! as List).cast<Map>();
      expect(messages.last['content'], contains('It is for: Anna'));
    });

    test('a failure is a reason, never text', () async {
      expect(
        (await ask(answering('x', status: 500))).outcome,
        AutoReplyOutcome.unreachable,
      );
      expect(
        (await ask(answering('<think>hm'))).outcome,
        AutoReplyOutcome.refused,
      );
    });

    test('no endpoint is not configured', () async {
      final draft = await composeQuickMessage(
        baseUrl: ' ',
        model: 'small',
        instruction: 'x',
        transcript: const [],
        language: 'en',
      );
      expect(draft.outcome, AutoReplyOutcome.notConfigured);
    });
  });
}
