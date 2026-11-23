/// Personal memory: what a note turns into in a prompt, how the model's
/// proposed facts are merged with what is already there, and the gates that
/// decide whether anything is sent at all.
///
/// The claims that matter most are the negative ones. A note is never sent
/// while the switch is off, never past its budget, and a proposed fact is
/// never written into a note without the user accepting it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/app/person_memory_providers.dart';
import 'package:weft/services/ai/auto_reply_service.dart';
import 'package:weft/services/ai/auto_reply_writer.dart';
import 'package:weft/services/ai/person_memory.dart';
import 'package:weft/services/ai/quick_messages.dart';
import 'package:weft/services/ai/smart_replies.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart' show IdentityGraph;

const _hosted = 'https://api.openai.com/v1';
const _local = 'http://localhost:11434/v1';

WeftMessage _message(
  String body, {
  bool own = false,
  bool encrypted = false,
  int minute = 0,
}) => WeftMessage(
  eventId: '\$e$minute',
  roomId: '!dm:example.org',
  network: ChatNetwork.whatsapp,
  senderId: own ? '@me:example.org' : '@anna:example.org',
  senderName: own ? 'Me' : 'Anna',
  timestamp: DateTime.utc(2026, 11, 20, 12, minute),
  kind: MessageKind.text,
  isOwn: own,
  body: body,
  encrypted: encrypted,
);

const _anna = Chat(
  id: '!dm:example.org',
  title: 'Anna',
  sources: [
    ChatSource(roomId: '!dm:example.org', network: ChatNetwork.whatsapp),
  ],
);

http.Client _answering(
  String? content, {
  void Function(Map<String, Object?> body)? onRequest,
  int status = 200,
  String finishReason = 'stop',
  String? reasoning,
}) => MockClient((request) async {
  onRequest?.call(jsonDecode(request.body) as Map<String, Object?>);
  return http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': content, 'reasoning_content': ?reasoning},
          'finish_reason': finishReason,
        },
      ],
    }),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
});

String _system(Map<String, Object?> body) =>
    ((body['messages'] as List).first as Map)['content'] as String;

void main() {
  group('trimPersonMemory', () {
    test('drops comments, empty headings and runs of blank lines', () {
      const note = '''
## What they like to be called
Annie

## Birthday
## Partner and kids
Mia (5), Ben (3)


<!-- private: owes me 20€ -->
## Ongoing topics
''';
      expect(
        trimPersonMemory(note, maxChars: 1000),
        '## What they like to be called\n'
        'Annie\n'
        '\n'
        '## Partner and kids\n'
        'Mia (5), Ben (3)',
      );
    });

    test('a note of nothing but the suggested headings is nothing', () {
      expect(
        trimPersonMemory(
          '## Birthday\n## Relationship\n\n## Likes and dislikes\n',
          maxChars: 1000,
        ),
        isEmpty,
      );
    });

    test('cuts at a whole line, keeping the first lines', () {
      final note = [for (var i = 0; i < 40; i++) '- fact number $i'].join('\n');
      final trimmed = trimPersonMemory(note, maxChars: 100);
      expect(trimmed.length, lessThanOrEqualTo(100));
      expect(trimmed, startsWith('- fact number 0\n- fact number 1'));
      expect(trimmed.split('\n').last, matches(RegExp(r'^- fact number \d+$')));
    });

    test('a heading the cut leaves last goes too', () {
      const note = 'Calls me Ricky\n## Kids\nMia and Ben, twins, born in May';
      expect(trimPersonMemory(note, maxChars: 24), 'Calls me Ricky');
    });

    test('one line longer than the budget is cut at a word and marked', () {
      final trimmed = trimPersonMemory(
        'Prefers voice notes over long texts and never answers before noon',
        maxChars: 30,
      );
      expect(trimmed, 'Prefers voice notes over…');
      expect(trimmed.length, lessThanOrEqualTo(30));
    });

    test('a local model gets a smaller budget than a hosted one', () {
      expect(aiMemoryBudget(_hosted), kAiMemoryHostedChars);
      expect(aiMemoryBudget(_local), kAiMemoryLocalChars);
      expect(kAiMemoryLocalChars, lessThan(kAiMemoryHostedChars));
    });
  });

  group('memoryPromptBlock', () {
    test('is empty for nothing, blanks, or notes of only headings', () {
      expect(memoryPromptBlock(null, baseUrl: _hosted), isEmpty);
      expect(
        memoryPromptBlock(
          const AiMemory(
            chat: '  \n ',
            people: [(name: 'Anna', note: '## Birthday')],
          ),
          baseUrl: _hosted,
        ),
        isEmpty,
      );
    });

    test('carries the person first, then the chat, and says not to quote', () {
      final block = memoryPromptBlock(
        const AiMemory(
          chat: 'Planning the Lisbon trip',
          people: [(name: 'Anna', note: 'Calls me Ricky')],
        ),
        baseUrl: _hosted,
      );
      expect(block, contains('never quote it'));
      expect(
        block,
        endsWith(
          'About Anna:\nCalls me Ricky\n\n'
          'About this chat:\nPlanning the Lisbon trip',
        ),
      );
    });

    test('stays inside the budget, which is smaller for a local model', () {
      final long = [for (var i = 0; i < 200; i++) '- fact $i'].join('\n');
      final memory = AiMemory(chat: long, people: [(name: 'Anna', note: long)]);
      final local = memoryPromptBlock(memory, baseUrl: _local);
      final hosted = memoryPromptBlock(memory, baseUrl: _hosted);
      expect(local, contains('- fact 0'));
      expect(local.length, lessThan(hosted.length));
      String notes(String block) => block.substring(block.indexOf('):\n') + 3);
      expect(notes(local).length, lessThanOrEqualTo(kAiMemoryLocalChars));
      expect(notes(hosted).length, lessThanOrEqualTo(kAiMemoryHostedChars));
      // A person is kept short whatever the budget: they are one of many.
      final anna = notes(hosted).split('\n\n').first;
      expect(anna.length, lessThanOrEqualTo(kPersonMemoryHostedChars + 20));
    });

    test(
      'in a group, the people who spoke last come first and the rest go',
      () {
        final people = [
          for (var i = 0; i < 8; i++)
            (name: 'Person $i', note: 'Likes the number $i, ${'x' * 60}'),
        ];
        final block = memoryPromptBlock(
          AiMemory(chat: 'Family group', people: people),
          baseUrl: _local,
        );
        expect(block, contains('About Person 0'));
        expect(block, isNot(contains('About Person 7')));
        expect(block, contains('About this chat:\nFamily group'));
      },
    );
  });

  group('the note in each prompt', () {
    test('a quick message carries it at the end of the system message', () {
      final messages = quickMessageRequest(
        instruction: 'A happy birthday wish.',
        transcript: const ['Anna: Bis Samstag!'],
        language: 'de',
        recipient: 'Anna',
        memory: memoryPromptBlock(
          const AiMemory(people: [(name: 'Anna', note: 'Calls me Ricky')]),
          baseUrl: _hosted,
        ),
      );
      expect(messages.first['content'], endsWith('Calls me Ricky'));
      // Only the system message: the worked examples are not about Anna.
      expect(
        messages.skip(1).where((m) => m['content']!.contains('Ricky')),
        isEmpty,
      );
    });

    test('a quick message without a note says nothing about notes', () {
      final messages = quickMessageRequest(
        instruction: 'A happy birthday wish.',
        transcript: const ['Anna: Bis Samstag!'],
        language: 'de',
      );
      expect(messages.first['content'], isNot(contains('noted')));
    });

    test('composeQuickMessage sends it, trimmed for the endpoint', () async {
      late Map<String, Object?> sent;
      await composeQuickMessage(
        baseUrl: _local,
        model: 'small',
        instruction: 'A happy birthday wish.',
        transcript: const ['Anna: Bis Samstag!'],
        language: 'de',
        memory: AiMemory(chat: 'Du, never Sie\n${'x' * 2000}'),
        client: _answering('Alles Gute!', onRequest: (b) => sent = b),
      );
      expect(_system(sent), contains('Du, never Sie'));
      expect(_system(sent), isNot(contains('x' * 500)));
    });

    test('an auto-reply carries it', () async {
      late Map<String, Object?> sent;
      await composeAutoReply(
        baseUrl: _hosted,
        model: 'gpt',
        instruction: 'Say I am on holiday.',
        chatTitle: 'Anna',
        transcript: const ['Anna: Hast du Zeit?'],
        memory: const AiMemory(people: [(name: 'Anna', note: 'Formal: Sie')]),
        client: _answering(
          '<reply>Ich bin im Urlaub.</reply>',
          onRequest: (b) => sent = b,
        ),
      );
      expect(_system(sent), contains('Formal: Sie'));
    });

    test('reply chips carry it, and without one say nothing', () async {
      late Map<String, Object?> sent;
      Future<void> ask(AiMemory? memory) => suggestSmartReplies(
        baseUrl: _hosted,
        model: 'gpt',
        chatTitle: 'Anna',
        transcript: const ['Anna: Kommst du?'],
        memory: memory,
        client: _answering('{"replies": ["Ja!"]}', onRequest: (b) => sent = b),
      );
      await ask(const AiMemory(chat: 'No emojis'));
      expect(_system(sent), contains('No emojis'));
      await ask(null);
      expect(_system(sent), isNot(contains('noted')));
    });
  });

  group('mergeFactSuggestions', () {
    test('leaves out what the note says, what waits and what was refused', () {
      final merged = mergeFactSuggestions(
        note: '## Family\n- Has two kids: Mia and Ben',
        pending: const ['Works at Deutsche Bahn'],
        dismissed: const ['Likes football'],
        proposed: const [
          'has two kids',
          'Works at Deutsche Bahn.',
          'likes FOOTBALL',
          'Birthday on 12 March',
          'Birthday on 12 March',
          '   ',
        ],
      );
      expect(merged, ['Works at Deutsche Bahn', 'Birthday on 12 March']);
    });

    test('never holds more than the cap', () {
      final merged = mergeFactSuggestions(
        note: '',
        pending: const [],
        dismissed: const [],
        proposed: [for (var i = 0; i < 20; i++) 'Fact $i'],
      );
      expect(merged, hasLength(kPersonMemoryMaxSuggestions));
    });
  });

  group('MemoryBook', () {
    const keys = ['handle:wa', 'handle:sig'];

    test('a note written for a merged person is found under every handle', () {
      final book = MemoryBook.empty.withNote(keys, 'Calls me Ricky');
      expect(book.noteFor(['handle:sig']), 'Calls me Ricky');
      expect(book.noteFor(['handle:wa']), 'Calls me Ricky');
    });

    test('two notes from before a merge read as one, and save as one', () {
      const book = MemoryBook(
        notes: {'handle:wa': 'Calls me Ricky', 'handle:sig': 'Two kids'},
      );
      expect(book.noteFor(keys), 'Calls me Ricky\n\nTwo kids');
      final saved = book.withNote(keys, book.noteFor(keys));
      expect(saved.notes.values.toSet(), {'Calls me Ricky\n\nTwo kids'});
    });

    test('proposals wait, and only accepting writes them into the note', () {
      var book = MemoryBook.empty
          .withNote(keys, 'Calls me Ricky')
          .withProposals(keys, const ['Has a dog, Bello', 'Likes jazz']);
      expect(book.noteFor(keys), 'Calls me Ricky');
      expect(book.suggestionsFor(keys), ['Has a dog, Bello', 'Likes jazz']);

      book = book.accept(keys, 'Has a dog, Bello');
      expect(book.noteFor(keys), 'Calls me Ricky\n- Has a dog, Bello');
      expect(book.suggestionsFor(keys), ['Likes jazz']);

      book = book.dismiss(keys, 'Likes jazz');
      expect(book.suggestionsFor(keys), isEmpty);
      expect(book.noteFor(keys), isNot(contains('jazz')));
      // And it is not offered again.
      expect(
        book.withProposals(keys, const ['likes jazz']).suggestionsFor(keys),
        isEmpty,
      );
    });

    test('a fact can go into a person\'s memory instead of the chat\'s', () {
      const chat = ['room:!g'];
      var book = MemoryBook.empty
          .withNote(keys, 'Calls me Ricky')
          .withProposals(chat, const ['Anna: has a dog, Bello']);
      book = book.promote(chat, keys, 'Anna: has a dog, Bello');
      expect(book.noteFor(keys), 'Calls me Ricky\n- Anna: has a dog, Bello');
      expect(book.noteFor(chat), isEmpty);
      expect(book.suggestionsFor(chat), isEmpty);
    });

    test('an empty note removes the entry', () {
      final book = MemoryBook.empty.withNote(keys, 'x').withNote(keys, '  ');
      expect(book.notes, isEmpty);
    });

    test('survives a round trip and reads garbage as empty', () {
      final book = MemoryBook.empty
          .withNote(keys, 'Calls me Ricky')
          .withProposals(keys, const ['Likes jazz'])
          .dismiss(keys, 'Likes jazz')
          .withProposals(keys, const ['Has a dog']);
      final back = MemoryBook.decode(book.encode());
      expect(back.noteFor(keys), 'Calls me Ricky');
      expect(back.suggestionsFor(keys), ['Has a dog']);
      expect(
        back.withProposals(keys, const ['Likes jazz']).suggestionsFor(keys),
        ['Has a dog'],
      );
      expect(MemoryBook.decode('not json').isEmpty, isTrue);
      expect(MemoryBook.decode('{"notes": [1, 2]}').isEmpty, isTrue);
      expect(MemoryBook.decode(null).isEmpty, isTrue);
    });

    test('never prints a note', () {
      final book = MemoryBook.empty.withNote(keys, 'secret birthday');
      expect('$book', isNot(contains('secret')));
    });

    test('a restore keeps what is here and adds what is not', () {
      const here = MemoryBook(notes: {'handle:wa': 'mine'});
      final merged = here.mergedWith(
        const MemoryBook(
          notes: {'handle:wa': 'archived', 'handle:tg': 'from archive'},
        ),
      );
      expect(merged.notes, {'handle:wa': 'mine', 'handle:tg': 'from archive'});
    });
  });

  group('personMemoryKeys', () {
    test('a group has none', () {
      expect(
        personMemoryKeys(
          chat: const Chat(
            id: 'g',
            title: 'Family',
            sources: [],
            isGroup: true,
          ),
          handles: const [],
        ),
        isEmpty,
      );
    });

    test('a person is filed under their handles, else under their rooms', () {
      const handle = NetworkHandle(
        id: 'h1',
        network: ChatNetwork.signal,
        remoteId: '+49170',
        matrixUserId: '@signal_1:example.org',
      );
      expect(personMemoryKeys(chat: _anna, handles: const [handle]), [
        'handle:h1',
      ]);
      // A prefix of its own: the person's memory is not the chat's.
      expect(personMemoryKeys(chat: _anna, handles: const []), [
        'dm:!dm:example.org',
      ]);
      expect(chatMemoryKeys(_anna), ['room:!dm:example.org']);
    });

    test('a group member is found through their contact, else by their id', () {
      const handles = [
        NetworkHandle(
          id: 'wa',
          network: ChatNetwork.whatsapp,
          remoteId: '+49170',
          matrixUserId: '@whatsapp_49170:example.org',
        ),
        NetworkHandle(
          id: 'sig',
          network: ChatNetwork.signal,
          remoteId: '+49170',
          matrixUserId: '@signal_1:example.org',
        ),
      ];
      List<NetworkHandle> handlesOf(String id) =>
          id == '@signal_1:example.org' ? handles : const [];
      expect(personKeysForSender('@signal_1:example.org', handlesOf), [
        'handle:wa',
        'handle:sig',
      ]);
      expect(personKeysForSender('@stranger:example.org', handlesOf), [
        'user:@stranger:example.org',
      ]);
    });
  });

  group('memoryPeopleFor', () {
    final graph = IdentityGraph(handles: const []);
    const group = Chat(
      id: '!g:example.org',
      title: 'Family',
      isGroup: true,
      sources: [
        ChatSource(roomId: '!g:example.org', network: ChatNetwork.whatsapp),
      ],
    );

    WeftMessage from(String who, int minute, {bool notice = false}) =>
        WeftMessage(
          eventId: '\$$who$minute',
          roomId: '!g:example.org',
          network: ChatNetwork.whatsapp,
          senderId: '@$who:example.org',
          senderName: who,
          timestamp: DateTime.utc(2026, 11, 20, 12, minute),
          kind: MessageKind.text,
          isOwn: false,
          isBridgeNotice: notice,
          body: 'hi',
        );

    test('a group is whoever spoke, the latest first, once each', () {
      final people = memoryPeopleFor(graph, group, [
        from('anna', 1),
        from('tom', 2),
        from('anna', 3),
        from('bot', 4, notice: true),
        _message('mine', own: true, minute: 5),
      ]);
      expect([for (final p in people) p.name], ['anna', 'tom']);
      expect(people.first.keys, ['user:@anna:example.org']);
    });

    test('a direct chat is the person it is with', () {
      final people = memoryPeopleFor(graph, _anna, const []);
      expect(people, hasLength(1));
      expect(people.single.name, 'Anna');
      expect(people.single.keys, ['dm:!dm:example.org']);
    });
  });

  group('parseCondensed', () {
    test('reads the object or plain text, and nothing from reasoning', () {
      expect(parseCondensed('{"memory": "- Annie\\n- Du"}'), '- Annie\n- Du');
      expect(parseCondensed('```\n- Annie\n```'), '- Annie');
      expect(parseCondensed('<think>shorten'), isNull);
      expect(parseCondensed('{"memory": ""}'), isNull);
    });
  });

  group('parsePersonFacts', () {
    test('reads the object, a fence, or a bare list', () {
      expect(parsePersonFacts('{"facts": ["Likes jazz"]}'), ['Likes jazz']);
      expect(parsePersonFacts('```json\n["Has a dog"]\n```'), ['Has a dog']);
      expect(parsePersonFacts('<think>hmm</think>{"facts": ["A", "a", ""]}'), [
        'A',
      ]);
    });

    test('reads through what local models wrap the list in', () {
      // A fence tagged with something other than json, after a preamble.
      expect(
        parsePersonFacts('Here you go:\n```JSON5\n{"facts": ["Runs"]}\n```'),
        ['Runs'],
      );
      // A template that opened <think> itself leaves only the closing tag,
      // after reasoning that quotes a list of its own.
      expect(
        parsePersonFacts(
          'Maybe ["Likes jazz"]? No, she said blues.\n</think>\n\n'
          '{"facts": ["Likes blues"]}',
        ),
        ['Likes blues'],
      );
      // Prose around the object.
      expect(
        parsePersonFacts('Sure! {"facts": ["Has a cat"]} Hope this helps.'),
        ['Has a cat'],
      );
    });

    test('reads facts written as objects, with the person named', () {
      expect(
        parsePersonFacts(
          '{"facts": [{"person": "Tom", "fact": "Runs the Berlin marathon"}, '
          '{"fact": "Calls everyone du"}, {"text": "Tom: likes jazz", '
          '"name": "Tom"}, 3]}',
        ),
        [
          'Tom: Runs the Berlin marathon',
          'Calls everyone du',
          'Tom: likes jazz',
        ],
      );
    });

    test('an empty list is nothing to keep, no list is no answer', () {
      expect(parsePersonFacts('{"facts": []}'), isEmpty);
      expect(parsePersonFacts('She likes jazz, I think.'), isNull);
      expect(parsePersonFacts('<think>She likes'), isNull);
      expect(parsePersonFacts(''), isNull);
    });
  });

  group('learnPersonFacts', () {
    const endpoint = AutoReplyEndpoint(baseUrl: _hosted, model: 'gpt');
    const keys = ['room:!dm:example.org'];
    const on = PersonMemorySettings(useInAi: true);

    late PersonMemoryNotifier memory;
    setUp(() {
      // No stores in the container: the notifier starts empty and writes to
      // no keychain.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      memory = container.read(personMemoryProvider.notifier);
    });

    Future<PersonFactsResult> learn({
      PersonMemorySettings settings = on,
      AutoReplyEndpoint? via = endpoint,
      List<WeftMessage>? messages,
      http.Client? client,
    }) => learnPersonFacts(
      settings: settings,
      endpoint: via,
      memory: memory,
      chat: _anna,
      people: const [
        (name: 'Anna', keys: ['dm:!dm:example.org']),
      ],
      messages:
          messages ??
          [
            _message('Mia hat morgen Geburtstag!'),
            _message('Oh schön', own: true, minute: 1),
          ],
      client:
          client ??
          MockClient((_) async => fail('nothing may be sent through a gate')),
    );

    test('sends nothing while the memory is off', () async {
      final result = await learn(settings: const PersonMemorySettings());
      expect(result.outcome, PersonFactsOutcome.memoryOff);
    });

    test('sends nothing from an encrypted chat unless allowed', () async {
      final encrypted = [_message('Geheim', encrypted: true)];
      expect(
        (await learn(messages: encrypted)).outcome,
        PersonFactsOutcome.encrypted,
      );

      final allowed = await learn(
        settings: on.copyWith(encryptedChats: true),
        messages: encrypted,
        client: _answering('{"facts": []}'),
      );
      expect(allowed.outcome, PersonFactsOutcome.nothingNew);
    });

    test('sends nothing without an endpoint', () async {
      expect((await learn(via: null)).outcome, PersonFactsOutcome.noEndpoint);
    });

    test('proposes into the chat, and leaves every note alone', () async {
      memory
        ..saveNote(keys, 'Planning the Lisbon trip')
        ..saveNote(const ['dm:!dm:example.org'], 'Calls me Ricky');
      late Map<String, Object?> sent;
      final result = await learn(
        client: _answering(
          '{"facts": ["Tochter Mia hat morgen Geburtstag"]}',
          onRequest: (b) => sent = b,
        ),
      );
      expect(result, (
        outcome: PersonFactsOutcome.proposed,
        added: 1,
        status: null,
      ));
      expect(memory.book.noteFor(keys), 'Planning the Lisbon trip');
      expect(memory.book.suggestionsFor(keys), [
        'Tochter Mia hat morgen Geburtstag',
      ]);
      // The notes go along, so the model can leave out what is known.
      final last = (sent['messages'] as List).last as Map;
      expect(last['content'], contains('Calls me Ricky'));
      expect(last['content'], contains('Planning the Lisbon trip'));
      expect(last['content'], contains('Anna: Mia hat morgen Geburtstag!'));
    });

    test('a failed request is a failure, not "nothing new"', () async {
      final result = await learn(client: _answering('', status: 500));
      expect(result.outcome, PersonFactsOutcome.failed);
      expect(result.status, 500);
    });

    test('asks for room to think: a reasoning model needs it', () async {
      late Map<String, Object?> sent;
      await learn(
        client: _answering('{"facts": []}', onRequest: (b) => sent = b),
      );
      expect(sent['max_tokens'], greaterThanOrEqualTo(2048));
    });

    // What the owner's Qwen behind litellm answered with 400 tokens: all of
    // them in reasoning_content, no content, finish_reason "length".
    test('a model cut off while thinking is not "nothing new"', () async {
      final result = await learn(
        client: _answering(
          null,
          reasoning: 'We need to produce JSON only with facts…',
          finishReason: 'length',
        ),
      );
      expect(result.outcome, PersonFactsOutcome.cutOff);
      expect(memory.book.suggestionsFor(keys), isEmpty);

      final inline = await learn(
        client: _answering('<think>Tom said', finishReason: 'length'),
      );
      expect(inline.outcome, PersonFactsOutcome.cutOff);
    });

    test('an answer with no list is unreadable, not "nothing new"', () async {
      final result = await learn(
        client: _answering('Anna seems to like birthdays.'),
      );
      expect(result.outcome, PersonFactsOutcome.unreadable);
      final empty = await learn(client: _answering(null));
      expect(empty.outcome, PersonFactsOutcome.unreadable);
    });

    test('a timeout says so', () async {
      final result = await learn(
        client: MockClient((_) async => throw TimeoutException('slow')),
      );
      expect(result.outcome, PersonFactsOutcome.timedOut);
    });

    test('a fenced, thought-through answer is proposed', () async {
      final result = await learn(
        client: _answering(
          '<think>Mia is her daughter.</think>\n```json\n'
          '{"facts": ["Tochter Mia hat morgen Geburtstag"]}\n```',
        ),
      );
      expect(result.outcome, PersonFactsOutcome.proposed);
    });

    test('both sides are sent, encrypted messages too when allowed', () async {
      late Map<String, Object?> sent;
      final result = await learn(
        messages: [
          _message('Ich laufe im September den Berlin-Marathon', minute: 1),
          _message('Wow, viel Glück!', own: true, minute: 2),
          _message('Und nenn mich Tommy', encrypted: true, minute: 3),
        ],
        settings: on.copyWith(encryptedChats: true),
        client: _answering('{"facts": []}', onRequest: (b) => sent = b),
      );
      expect(result.outcome, PersonFactsOutcome.nothingNew);
      final last =
          ((sent['messages'] as List).last as Map)['content'] as String;
      expect(
        last,
        contains('Anna: Ich laufe im September den Berlin-Marathon'),
      );
      expect(last, contains('Wow, viel Glück!'));
      expect(last, contains('Anna: Und nenn mich Tommy'));
    });

    test('a facts list the notes already hold is "nothing new"', () async {
      memory.saveNote(keys, '- Tochter Mia hat morgen Geburtstag');
      final result = await learn(
        client: _answering('{"facts": ["Tochter Mia hat morgen Geburtstag"]}'),
      );
      expect(result.outcome, PersonFactsOutcome.nothingNew);
    });
  });
}
