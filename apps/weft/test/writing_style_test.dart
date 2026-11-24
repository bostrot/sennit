/// Replies in the user's own style: how the user and the people they write to
/// write is measured and learned per chat and person, and every feature that
/// writes a message the user sends is told it — with the user's own messages
/// as examples, never the contact's.
///
/// The claims: the habits count what they say they count; a profile is learned
/// only for someone who wrote enough, lands in the right layer, and is
/// pinned, edited and undone like any fact; the reply prompts carry the
/// user's profile and examples, the usual profile when the chat has none, and
/// the contact's only as context; and nothing of it is sent with the memory
/// switch off.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/app/person_memory_providers.dart';
import 'package:weft/services/ai/auto_reply_service.dart';
import 'package:weft/services/ai/auto_reply_writer.dart';
import 'package:weft/services/ai/llm_budget.dart';
import 'package:weft/services/ai/person_memory.dart';
import 'package:weft/services/ai/quick_messages.dart';
import 'package:weft/services/ai/smart_replies.dart';
import 'package:weft/services/ai/writing_style.dart';
import 'package:weft_domain/weft_domain.dart';

const _hosted = 'https://api.openai.com/v1';
const _local = 'http://localhost:11434/v1';

const _chatKeys = ['room:!dm:example.org'];
const _annaKeys = ['dm:!dm:example.org'];
const MemoryPerson _annaPerson = (name: 'Anna', keys: _annaKeys);

const _anna = Chat(
  id: '!dm:example.org',
  title: 'Anna',
  sources: [
    ChatSource(roomId: '!dm:example.org', network: ChatNetwork.whatsapp),
  ],
);

var _n = 0;

WeftMessage _message(
  String body, {
  bool own = false,
  bool encrypted = false,
  bool autoReply = false,
  int? minute,
}) {
  final at = minute ?? _n++;
  return WeftMessage(
    eventId: '\$e$at',
    roomId: '!dm:example.org',
    network: ChatNetwork.whatsapp,
    senderId: own ? '@me:example.org' : '@anna:example.org',
    senderName: own ? 'Me' : 'Anna',
    timestamp: DateTime.utc(2026, 11, 20, 12).add(Duration(minutes: at)),
    kind: MessageKind.text,
    isOwn: own,
    isAutoReply: autoReply,
    body: body,
    encrypted: encrypted,
  );
}

/// A terse lowercase German texter writing to a formal English one.
List<WeftMessage> _conversation() {
  _n = 0;
  return [
    _message('Dear Eric, I hope this message finds you well.'),
    _message('jo passt 👍', own: true),
    _message('Would Thursday at 3 pm suit you for the review?'),
    _message('klar, bin da 😅', own: true),
    _message('Excellent. I shall send the agenda beforehand.'),
    _message('top danke 🙏', own: true),
    _message('Kind regards, Anna.'),
    _message('bis do', own: true),
  ];
}

http.Client _answering(
  String content, {
  void Function(Map<String, Object?> body)? onRequest,
}) => MockClient((request) async {
  onRequest?.call(jsonDecode(request.body) as Map<String, Object?>);
  return http.Response(
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
});

String _system(Map<String, Object?> body) =>
    ((body['messages'] as List).first as Map)['content'] as String;

String _lastUser(Map<String, Object?> body) =>
    ((body['messages'] as List).last as Map)['content'] as String;

void main() {
  group('measureWritingHabits', () {
    test('terse lowercase with emojis', () {
      final habits = measureWritingHabits([
        'jo passt 👍',
        'klar, bin da 😅',
        'top danke 🙏',
        'haha ja 😅',
      ])!;
      expect(habits.messages, 4);
      expect(habits.medianWords, lessThanOrEqualTo(4));
      expect(habits.lowercaseShare, 1);
      expect(habits.periodShare, 0);
      expect(habits.emojiShare, 1);
      expect(habits.emojis.first, '😅');
      final said = habits.describe();
      expect(said, contains('very short'));
      expect(said, contains('starts lowercase'));
      expect(said, contains('no full stop at the end'));
      expect(said, contains('emojis in most messages (😅'));
    });

    test('formal and complete', () {
      final said = measureWritingHabits([
        'Dear Eric, I hope this message finds you well.',
        'Would Thursday at 3 pm suit you for the review?',
        'Excellent. I shall send the agenda beforehand.',
        'Kind regards, Anna.',
      ])!.describe();
      expect(said, contains('starts with a capital'));
      expect(said, contains('ends with a full stop'));
      expect(said, contains('no emojis'));
      expect(said, isNot(contains('lowercase')));
    });

    test('too few messages say nothing', () {
      expect(measureWritingHabits(['ok', 'ja']), isNull);
      expect(measureWritingHabits(['ok', '  ', '', 'ja']), isNull);
    });

    test('an ellipsis is not a full stop', () {
      final habits = measureWritingHabits([
        'hmm...',
        'naja...',
        'mal sehen...',
      ])!;
      expect(habits.periodShare, 0);
    });
  });

  group('ownStyleExamples', () {
    test("the user's newest messages only, oldest first, each once", () {
      _n = 0;
      final messages = [
        for (var i = 0; i < 14; i++) _message('msg $i', own: true),
        _message('msg 13', own: true),
        _message('from Anna'),
        _message('away until monday', own: true, autoReply: true),
      ];
      final examples = ownStyleExamples(messages);
      expect(examples, hasLength(kStyleExamples));
      expect(examples.first, 'msg 4');
      expect(examples.last, 'msg 13');
      expect(examples, isNot(contains('from Anna')));
      // An auto-reply is not the user's voice.
      expect(examples, isNot(contains('away until monday')));
    });

    test('fits a budget by leaving out the oldest, and cuts a long one', () {
      _n = 0;
      final long = List.filled(60, 'wort').join(' ');
      final examples = ownStyleExamples([
        _message('old one', own: true),
        _message(long, own: true),
        _message('newest', own: true),
      ], maxChars: 170);
      expect(examples, hasLength(2));
      expect(examples.last, 'newest');
      expect(examples.first.length, lessThanOrEqualTo(kStyleExampleChars));
      expect(examples.first, endsWith('…'));
    });

    test('leaves out what may not be sent', () {
      _n = 0;
      final examples = ownStyleExamples([
        _message('secret', own: true, encrypted: true),
        _message('open', own: true),
      ], allowed: (m) => !m.encrypted);
      expect(examples, ['open']);
    });
  });

  group('stylePromptBlock', () {
    const style = AiStyle(
      mine: 'Sehr kurz, alles klein, kaum Punkte, oft 😅',
      usual: 'Kurz und locker',
      habits: 'very short (about 2 words); starts lowercase',
      examples: ['jo passt 👍', 'klar, bin da 😅'],
      theirs: [(name: 'Anna', style: 'Formal English, full sentences')],
    );

    test('tells the model to write as the user, with their examples', () {
      final block = stylePromptBlock(style, maxChars: 2000);
      expect(block, contains('Write as the user'));
      expect(block, contains('not like an assistant'));
      expect(block, contains("style in this chat: Sehr kurz, alles klein"));
      // The chat's profile wins over the usual one.
      expect(block, isNot(contains('Kurz und locker')));
      expect(block, contains('- jo passt 👍\n- klar, bin da 😅'));
      expect(
        block,
        contains(
          'How Anna writes (only to understand them — never copy it): '
          'Formal English',
        ),
      );
    });

    test('falls back to the usual style for a chat with none', () {
      const fresh = AiStyle(usual: 'Kurz und locker');
      final block = stylePromptBlock(fresh, maxChars: 2000);
      expect(block, contains("The user's usual style: Kurz und locker"));
    });

    test('cuts examples first, and never the instruction', () {
      final full = stylePromptBlock(style, maxChars: 2000);
      final tight = stylePromptBlock(style, maxChars: full.length - 5);
      expect(tight, contains('Write as the user'));
      expect(tight, contains('Sehr kurz'));
      expect(tight, contains('klar, bin da'));
      expect(tight, isNot(contains('jo passt')));
      expect(tight.length, lessThanOrEqualTo(full.length - 5 + 2));
    });

    test('says nothing when nothing is known about the user', () {
      expect(stylePromptBlock(AiStyle.none, maxChars: 2000), '');
      expect(stylePromptBlock(null, maxChars: 2000), '');
    });
  });

  group('memoryPromptBlock', () {
    const memory = AiMemory(
      style: AiStyle(mine: 'Sehr kurz', examples: ['jo passt 👍']),
    );

    test('carries the style for the features that write as the user', () {
      for (final feature in [
        AiFeature.smartReplies,
        AiFeature.quickMessage,
        AiFeature.autoReply,
      ]) {
        final block = memoryPromptBlock(
          memory,
          baseUrl: _local,
          budget: LlmBudget.resolve(_local),
          feature: feature,
        );
        expect(block, contains('jo passt 👍'), reason: '$feature');
      }
    });

    test('and not for the ones that do not', () {
      for (final feature in [AiFeature.todo, AiFeature.eventTitle]) {
        expect(
          memoryPromptBlock(memory, baseUrl: _local, feature: feature),
          isNot(contains('Sehr kurz')),
          reason: '$feature',
        );
      }
    });

    test('the chips get a smaller share than a message', () {
      final budget = LlmBudget.resolve(_local);
      expect(
        budget.styleCharsFor(AiFeature.smartReplies),
        lessThan(budget.styleCharsFor(AiFeature.quickMessage)),
      );
      expect(budget.styleCharsFor(AiFeature.todo), 0);
    });
  });

  group('the reply prompts', () {
    final memory = aiMemoryFrom(MemoryBook.empty, _anna, const [
      _annaPerson,
    ], ownMessages: _conversation());

    test(
      'the chips carry my messages, and not the contact\'s, as mine',
      () async {
        late Map<String, Object?> sent;
        await suggestSmartReplies(
          baseUrl: _local,
          model: 'qwen',
          chatTitle: 'Anna',
          transcript: const ['Anna: Kind regards, Anna.'],
          memory: memory,
          client: _answering(
            '{"replies": ["passt 👍"]}',
            onRequest: (b) => sent = b,
          ),
        );
        final system = _system(sent);
        final examples = system.substring(
          system.indexOf('Messages the user sent'),
        );
        expect(examples, contains('- jo passt 👍'));
        expect(examples, contains('- bis do'));
        expect(examples, isNot(contains('Dear Eric')));
        expect(system, contains('starts lowercase'));
        // The fast path is unchanged: still asked not to think.
        expect(sent['max_tokens'], lessThanOrEqualTo(1024));
      },
    );

    test('a quick message and an auto-reply carry them too', () async {
      late Map<String, Object?> quick;
      await composeQuickMessage(
        baseUrl: _hosted,
        model: 'gpt',
        instruction: 'A thank-you.',
        transcript: const ['Anna: Kind regards, Anna.'],
        language: 'de',
        memory: memory,
        client: _answering('danke dir 🙏', onRequest: (b) => quick = b),
      );
      expect(_system(quick), contains('Write as the user'));
      expect(_system(quick), contains('- top danke 🙏'));

      late Map<String, Object?> auto;
      await composeAutoReply(
        baseUrl: _hosted,
        model: 'gpt',
        instruction: 'Say I am driving.',
        chatTitle: 'Anna',
        transcript: const ['Anna: Kind regards, Anna.'],
        memory: memory,
        client: _answering(
          '${kAutoReplyOpen}sitz im auto, meld mich$kAutoReplyClose',
          onRequest: (b) => auto = b,
        ),
      );
      expect(_system(auto), contains('- klar, bin da 😅'));
    });
  });

  group('aiMemoryFrom', () {
    test('the chat profile, the usual one, and theirs', () {
      final now = DateTime(2026, 11, 24);
      final book = MemoryBook.empty
          .applyLearning(
            const MemoryUpdate(
              styles: {
                'me': 'Sehr kurz',
                'default': 'Kurz und locker',
                'Anna': 'Formal English',
              },
            ),
            chatKeys: _chatKeys,
            people: const [_annaPerson],
            numbered: const [],
            now: now,
          )
          .book;
      final memory = aiMemoryFrom(book, _anna, const [_annaPerson])!;
      expect(memory.style.mine, 'Sehr kurz');
      expect(memory.style.usual, 'Kurz und locker');
      expect(memory.style.theirs.single, (
        name: 'Anna',
        style: 'Formal English',
      ));
      // Not a fact about the chat or about Anna.
      expect(memory.chat, isEmpty);
      expect(memory.people, isEmpty);
    });

    test('nothing at all is no memory', () {
      expect(aiMemoryFrom(MemoryBook.empty, _anna, const []), isNull);
    });
  });

  group('learning a style', () {
    final now = DateTime(2026, 11, 24, 9);

    ({MemoryBook book, int added, int updated, int dropped}) apply(
      MemoryBook book,
      Map<String, String> styles,
    ) => book.applyLearning(
      MemoryUpdate(styles: styles),
      chatKeys: _chatKeys,
      people: const [_annaPerson],
      numbered: book.numberedFacts(_chatKeys, const [_annaPerson]),
      now: now,
    );

    test('files each profile in its layer, as one style fact', () {
      final result = apply(MemoryBook.empty, {
        'me': 'Sehr kurz, alles klein',
        'Default': 'Kurz und locker',
        'anna': 'Formal English',
        'Nobody': 'Ignored',
      });
      expect(result.added, 3);
      final book = result.book;
      expect(book.styleFor(_chatKeys)!.text, 'Sehr kurz, alles klein');
      expect(book.styleFor(const [kOwnStyleKey])!.text, 'Kurz und locker');
      expect(book.styleFor(_annaKeys)!.text, 'Formal English');
      expect(book.styleFor(_chatKeys)!.style, isTrue);
      // Never numbered for the model to rewrite as a fact.
      expect(book.numberedFacts(_chatKeys, const [_annaPerson]), isEmpty);
      expect(book.memoryFor(_chatKeys), isEmpty);
    });

    test('replaces the profile, and leaves a pinned one alone', () {
      var book = apply(MemoryBook.empty, {'me': 'Sehr kurz'}).book;
      book = apply(book, {'me': 'Kurz, mit Emojis'}).book;
      expect(book.learnedFor(_chatKeys), hasLength(1));
      expect(book.styleFor(_chatKeys)!.text, 'Kurz, mit Emojis');

      book = book.editLearned(
        _chatKeys,
        book.styleFor(_chatKeys)!,
        'Kurz, immer klein',
        now: now,
      );
      expect(book.styleFor(_chatKeys)!.pinned, isTrue);
      expect(book.styleFor(_chatKeys)!.style, isTrue);
      final again = apply(book, {'me': 'Lang und förmlich'});
      expect(again.added + again.updated, 0);
      expect(again.book.styleFor(_chatKeys)!.text, 'Kurz, immer klein');
    });

    test('is undone with the rest of the update', () {
      final first = apply(MemoryBook.empty, {'me': 'Sehr kurz'}).book;
      final second = apply(first, {'me': 'Förmlich', 'default': 'Locker'});
      final undone = second.book.undoAutomatic();
      expect(undone.styleFor(_chatKeys)!.text, 'Sehr kurz');
      expect(undone.styleFor(const [kOwnStyleKey]), isNull);
    });

    test('is never cut by the fact limit', () {
      var book = apply(MemoryBook.empty, {'me': 'Sehr kurz'}).book;
      book = book
          .applyLearning(
            MemoryUpdate(
              adds: [
                for (var i = 0; i < kChatLearnedLimit + 3; i++)
                  MemoryAddition('Topic number $i'),
              ],
            ),
            chatKeys: _chatKeys,
            people: const [_annaPerson],
            numbered: const [],
            now: now.add(const Duration(hours: 1)),
          )
          .book;
      expect(book.styleFor(_chatKeys)!.text, 'Sehr kurz');
    });

    test('survives being saved', () {
      final book = apply(MemoryBook.empty, {'me': 'Sehr kurz'}).book;
      expect(
        MemoryBook.decode(book.encode()).styleFor(_chatKeys)!.style,
        isTrue,
      );
    });

    test('is read from the model\'s answer', () {
      final update = parseMemoryUpdate(
        '{"add": [], "update": [], "drop": [], '
        '"style": {"me": "Sehr kurz", "Anna": "Formal", "x": 3}}',
      )!;
      expect(update.styles, {'me': 'Sehr kurz', 'Anna': 'Formal'});
      expect(parseMemoryUpdate('{"style": {"me": "Kurz"}}')!.styles, {
        'me': 'Kurz',
      });
    });
  });

  group('learnPersonFacts', () {
    const endpoint = AutoReplyEndpoint(baseUrl: _hosted, model: 'gpt');
    late PersonMemoryNotifier memory;
    setUp(() {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      memory = container.read(personMemoryProvider.notifier);
    });

    test(
      'tells the model the measured habits, and the profiles so far',
      () async {
        late Map<String, Object?> sent;
        await learnPersonFacts(
          settings: const PersonMemorySettings(useInAi: true),
          endpoint: endpoint,
          memory: memory,
          chat: _anna,
          people: const [_annaPerson],
          messages: _conversation(),
          client: _answering(
            '{"add": [], "update": [], "drop": [], "style": {}}',
            onRequest: (b) => sent = b,
          ),
        );
        final prompt = _lastUser(sent);
        expect(prompt, contains('Writing style so far:'));
        expect(prompt, contains('- me: very short'));
        expect(prompt, contains('- Anna: '));
        expect(prompt, contains('ends with a full stop'));
      },
    );

    test('keeps a profile only for someone who wrote enough', () async {
      _n = 0;
      final result = await learnPersonFacts(
        settings: const PersonMemorySettings(useInAi: true),
        endpoint: endpoint,
        memory: memory,
        chat: _anna,
        people: const [_annaPerson],
        messages: [
          _message('Hello Eric, how are you?'),
          _message('Are you free on Thursday?'),
          _message('Please let me know.'),
          _message('jo', own: true),
        ],
        client: _answering(
          '{"add": [], "update": [], "drop": [], "style": '
          '{"me": "Einsilbig", "default": "Einsilbig", "Anna": "Formal"}}',
        ),
      );
      expect(result.outcome, PersonFactsOutcome.learned);
      expect(memory.book.styleFor(_chatKeys), isNull);
      expect(memory.book.styleFor(const [kOwnStyleKey]), isNull);
      expect(memory.book.styleFor(_annaKeys)!.text, 'Formal');
    });
  });

  group('the gates', () {
    test('nothing of it goes into a prompt with the memory off', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Without stores the settings read as everything off.
      expect(container.read(personMemorySettingsProvider).useInAi, isFalse);
      expect(
        container.read(aiMemoryForPromptProvider)(_anna, _conversation()),
        isNull,
      );
      // Not even kept for later.
      expect(
        container.read(ownMessageCacheProvider).remember(_anna.id, const []),
        isEmpty,
      );
    });
  });

  group('OwnMessageCache', () {
    test('keeps the newest of mine per chat, by event once', () {
      _n = 0;
      final cache = OwnMessageCache();
      cache.remember('a', [
        for (var i = 0; i < 12; i++) _message('m$i', own: true),
        _message('theirs'),
      ]);
      final kept = cache.remember('a', [
        _message('m11', own: true, minute: 11),
      ]);
      expect(kept, hasLength(kStyleExamples));
      expect(kept.first.body, 'm11');
      expect(kept.any((m) => !m.isOwn), isFalse);
      expect(cache.remember('b', const []), isEmpty);
    });

    test('forgets the chats spoken in least recently', () {
      _n = 0;
      final cache = OwnMessageCache();
      for (var i = 0; i <= kOwnMessageCacheChats; i++) {
        cache.remember('chat$i', [_message('hi', own: true)]);
      }
      expect(cache.remember('chat0', const []), isEmpty);
      expect(cache.remember('chat1', const []), hasLength(1));
    });
  });
}
