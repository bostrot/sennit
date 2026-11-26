/// Temporary facts, and one memory per direct chat.
///
/// The claims: a fact the model marks temporary is kept until its day and no
/// longer — then it is gone, or once turned into a short past-tense note that
/// goes in its turn; one already over when it is learned is never kept as if
/// it were not; the facts learned before facts were sorted are sorted once;
/// and a direct chat's memory and its person's become one, losing nothing,
/// with the book as it was kept until the move has been read back.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/ai/event_title.dart';
import 'package:weft/services/ai/person_memory.dart';
import 'package:weft_domain/weft_domain.dart';

const _room = ['room:!dm:example.org'];
const _annaKeys = ['handle:wa-anna', 'handle:sig-anna'];
const MemoryPerson _anna = (name: 'Anna', keys: _annaKeys);

/// Thursday 26 Nov 2026, 9:00 — the fake clock every test reads.
final _now = DateTime(2026, 11, 26, 9);

({MemoryBook book, int added, int updated, int dropped}) _learn(
  MemoryBook book,
  MemoryUpdate update, {
  DateTime? now,
}) => book.applyLearning(
  update,
  // A direct chat: the chat's memory is Anna's.
  chatKeys: _annaKeys,
  people: const [_anna],
  numbered: book.numberedFacts(_annaKeys, const [_anna]),
  ownStyleKeys: _room,
  now: now ?? _now,
);

List<String> _texts(Iterable<LearnedFact> facts) => [
  for (final f in facts) f.text,
];

void main() {
  group('parseMemoryUpdate', () {
    test('reads lasting and temporary facts, and what they become', () {
      final update = parseMemoryUpdate(
        '{"add": ['
        '{"fact": "Works at the post office", "about": "Anna"}, '
        '{"fact": "Dentist on 27 Nov at 10", "about": "Anna", '
        '"until": "2026-11-27", "after": "Had a dentist appointment on 27 Nov"}, '
        '{"fact": "Has the flu", "kind": "temporary"}, '
        '{"fact": "Lives in Leipzig", "until": null, "after": "ignored"}, '
        '{"fact": "Likes jazz", "until": "never"}], '
        '"update": [{"id": 3, "fact": "Trip moved to 5 Dec", '
        '"until": "2026-12-05"}], "drop": []}',
      )!;
      final [post, dentist, flu, leipzig, jazz] = update.adds;
      expect(post.until, isNull);
      expect(dentist.until, '2026-11-27');
      expect(dentist.after, 'Had a dentist appointment on 27 Nov');
      // Temporary, with no day it could give.
      expect(flu.until, '?');
      expect(flu.after, isNull);
      // Lasting: no "after" for something that never ends.
      expect(leipzig.until, isNull);
      expect(leipzig.after, isNull);
      expect(jazz.until, isNull);
      expect(update.updates.single.until, '2026-12-05');
    });
  });

  group('factExpiry', () {
    test('a day ends at the midnight after it', () {
      expect(factExpiry('2026-11-27', now: _now), DateTime(2026, 11, 28));
      expect(factExpiry('2026-11-27T10:00', now: _now), DateTime(2026, 11, 28));
    });

    test('no day, or a day that is none, is a week', () {
      expect(factExpiry('?', now: _now), _now.add(kTemporaryFactDefault));
      expect(
        factExpiry('2026-02-30', now: _now),
        _now.add(kTemporaryFactDefault),
      );
    });

    test('lasting is null, and nothing is kept past a year', () {
      expect(factExpiry(null, now: _now), isNull);
      expect(factExpiry('2031-01-01', now: _now), _now.add(kTemporaryFactMax));
    });
  });

  group('learning', () {
    test('a temporary fact is kept with its day, a lasting one without', () {
      final result = _learn(
        MemoryBook.empty,
        const MemoryUpdate(
          adds: [
            MemoryAddition('Works at the post office', about: 'Anna'),
            MemoryAddition(
              'Dentist on 27 Nov at 10',
              about: 'Anna',
              until: '2026-11-27',
              after: 'Had a dentist appointment on 27 Nov',
            ),
          ],
        ),
      );
      final [post, dentist] = result.book.learnedFor(_annaKeys);
      expect(post.temporary, isFalse);
      expect(post.checked, isTrue);
      expect(dentist.until, DateTime(2026, 11, 28));
      expect(dentist.after, 'Had a dentist appointment on 27 Nov');
    });

    test('what was over before it was learned is never kept as now', () {
      final result = _learn(
        MemoryBook.empty,
        const MemoryUpdate(
          adds: [
            // Said last week: "I'm at the doctor tomorrow".
            MemoryAddition('At the doctor on 19 Nov', until: '2026-11-19'),
            MemoryAddition(
              'Trip to Lisbon until 20 Nov',
              until: '2026-11-20',
              after: 'Was in Lisbon until 20 Nov',
            ),
          ],
        ),
      );
      expect(result.added, 1);
      final past = result.book.learnedFor(_annaKeys).single;
      expect(past.text, 'Was in Lisbon until 20 Nov');
      expect(past.past, isTrue);
      expect(past.until, DateTime(2026, 11, 21).add(kPastNoteKeep));
    });

    test('a rewrite keeps the day unless it gives a new one', () {
      var book = _learn(
        MemoryBook.empty,
        const MemoryUpdate(
          adds: [MemoryAddition('Dentist on 27 Nov', until: '2026-11-27')],
        ),
      ).book;
      book = _learn(
        book,
        const MemoryUpdate(
          updates: [
            (id: 1, fact: 'Dentist on 27 Nov at 11', until: null, after: null),
          ],
        ),
      ).book;
      expect(book.learnedFor(_annaKeys).single.until, DateTime(2026, 11, 28));
      book = _learn(
        book,
        const MemoryUpdate(
          updates: [
            (
              id: 1,
              fact: 'Dentist moved to 2 Dec',
              until: '2026-12-02',
              after: null,
            ),
          ],
        ),
      ).book;
      expect(book.learnedFor(_annaKeys).single.until, DateTime(2026, 12, 3));
    });

    test('the prompt dates the conversation and asks for the sorting', () {
      final messages = memoryUpdateRequest(
        transcript: const ['--- 2026-11-25 (Wed) ---', 'Anna: Morgen Zahnarzt'],
        chatTitle: 'Anna',
        people: const ['Anna'],
        today: _now,
      );
      expect(messages.first['content'], contains('"until"'));
      expect(messages.first['content'], contains('"after"'));
      expect(messages.first['content'], contains('in the car'));
      expect(
        messages.last['content'],
        startsWith('Today is 2026-11-26 (Thu).'),
      );
    });

    test('the transcript says which day each message was sent on', () {
      WeftMessage at(DateTime t, String body) => WeftMessage(
        eventId: '\$${t.millisecondsSinceEpoch}',
        roomId: '!dm:example.org',
        network: ChatNetwork.whatsapp,
        senderId: '@anna:example.org',
        senderName: 'Anna',
        timestamp: t,
        kind: MessageKind.text,
        isOwn: false,
        body: body,
      );
      final lines = recentConversationTranscript(
        [
          at(DateTime(2026, 11, 24, 20), 'Morgen Zahnarzt'),
          at(DateTime(2026, 11, 26, 8), 'War gut'),
          at(DateTime(2026, 11, 26, 9), 'Bis später'),
        ],
        maxMessages: 10,
        maxChars: 4000,
        dayMarker: (day) => '--- ${promptDay(day)} ---',
      );
      expect(lines, [
        '--- 2026-11-24 (Tue) ---',
        'Anna: Morgen Zahnarzt',
        '--- 2026-11-26 (Thu) ---',
        'Anna: War gut',
        'Anna: Bis später',
      ]);
    });
  });

  group('expire', () {
    final dentist = LearnedFact(
      'Dentist on 27 Nov at 10',
      at: _now,
      until: DateTime(2026, 11, 28),
      after: 'Had a dentist appointment on 27 Nov',
      checked: true,
    );
    final flu = LearnedFact(
      'Has the flu',
      at: _now,
      until: DateTime(2026, 11, 28),
      checked: true,
    );
    final job = LearnedFact('Works at the post office', at: _now);
    final book = MemoryBook(
      learned: {
        for (final key in _annaKeys) key: [job, dentist, flu],
      },
    );

    test('nothing goes before its day', () {
      final result = book.expire(DateTime(2026, 11, 27, 23, 59));
      expect(result.changed, 0);
      expect(identical(result.book, book), isTrue);
    });

    test('then it becomes what it was worth knowing, once, or goes', () {
      final day = DateTime(2026, 11, 28, 0, 30);
      final after = book.expire(day).book;
      expect(_texts(after.learnedFor(_annaKeys)), [
        'Works at the post office',
        'Had a dentist appointment on 27 Nov',
      ]);
      final note = after.learnedFor(_annaKeys).last;
      expect(note.past, isTrue);
      expect(note.until, DateTime(2026, 11, 28).add(kPastNoteKeep));
      // Every key a person is filed under, alike.
      expect(after.learned['handle:sig-anna'], after.learned['handle:wa-anna']);

      // A month on, the note goes too, and nothing takes its place.
      final later = after.expire(day.add(kPastNoteKeep)).book;
      expect(_texts(later.learnedFor(_annaKeys)), ['Works at the post office']);
    });

    test('a pin keeps a fact from the model, not from the calendar', () {
      final pinned = book.pinLearned(_annaKeys, flu, pinned: true);
      final after = pinned.expire(DateTime(2026, 12, 1)).book;
      expect(
        _texts(after.learnedFor(_annaKeys)),
        isNot(contains('Has the flu')),
      );
    });

    test('an edit keeps the day', () {
      final edited = book.editLearned(
        _annaKeys,
        dentist,
        'Dentist at 11',
        now: _now,
      );
      expect(
        edited.learnedFor(_annaKeys).firstWhere((f) => f.edited).until,
        DateTime(2026, 11, 28),
      );
    });

    test('a backup leaves temporary facts out', () {
      expect(
        book.notesWithLearned['handle:wa-anna'],
        '- Works at the post office',
      );
    });
  });

  group('sorting what was learned before', () {
    final old = MemoryBook(
      learned: {
        'handle:wa-anna': [
          LearnedFact('Works at the post office', at: DateTime(2026, 11, 2)),
          LearnedFact('Has the dentist tomorrow', at: DateTime(2026, 11, 20)),
          LearnedFact('Flies to Lisbon on Friday', at: DateTime(2026, 11, 24)),
          LearnedFact('Is in the car', at: DateTime(2026, 11, 25)),
          LearnedFact(
            'Calls me Ricky',
            at: DateTime(2026, 11, 3),
            pinned: true,
          ),
          LearnedFact('Writes short', at: DateTime(2026, 11, 3), style: true),
          LearnedFact('Likes jazz', at: DateTime(2026, 11, 4)),
        ],
      },
    );

    test('asks about what is not pinned or a style, oldest first', () {
      expect(_texts(old.unchecked), [
        'Works at the post office',
        'Likes jazz',
        'Has the dentist tomorrow',
        'Flies to Lisbon on Friday',
        'Is in the car',
      ]);
      final prompt = factClassPrompt(facts: old.unchecked, today: _now);
      expect(prompt, contains('3. [2026-11-20] Has the dentist tomorrow'));
      expect(prompt, startsWith('Today is 2026-11-26 (Thu).'));
    });

    test('reads the answer, through reasoning and a fence', () {
      final sorted = parseFactClasses(
        '<think>hm</think>```json\n{"facts": ['
        '{"id": 1, "kind": "lasting"}, '
        '{"id": "3", "kind": "temporary", "until": "2026-11-21", '
        '"after": "Was at the dentist on 21 Nov"}, '
        '{"id": 4, "kind": "temporary", "until": "2026-11-27"}, '
        '{"id": 5, "kind": "drop"}]}\n```',
      )!;
      expect(sorted[1]!.until, isNull);
      expect(sorted[3]!.until, '2026-11-21');
      expect(sorted[3]!.after, 'Was at the dentist on 21 Nov');
      expect(sorted[4]!.until, '2026-11-27');
      expect(sorted[5]!.drop, isTrue);
      expect(parseFactClasses('No idea.'), isNull);
      expect(parseFactClasses('[{"id": 2, "kind": "lasting"}]'), {
        2: isA<FactClass>(),
      });
    });

    test('writes it in, and marks everything asked as sorted', () {
      final asked = old.unchecked;
      final sorted = {
        factKey('Works at the post office'): const FactClass.lasting(),
        factKey('Has the dentist tomorrow'): const FactClass.temporary(
          '2026-11-21',
          after: 'Was at the dentist on 21 Nov',
        ),
        factKey('Flies to Lisbon on Friday'): const FactClass.temporary(
          '2026-11-27',
        ),
        factKey('Is in the car'): const FactClass.drop(),
        // "Likes jazz" not answered: kept as it is, and not asked again.
      };
      final book = old.classify(sorted, asked: asked, now: _now);
      final facts = book.learnedFor(['handle:wa-anna']);
      expect(_texts(facts), [
        'Works at the post office',
        'Was at the dentist on 21 Nov',
        'Flies to Lisbon on Friday',
        'Calls me Ricky',
        'Writes short',
        'Likes jazz',
      ]);
      expect(facts[1].past, isTrue);
      expect(facts[2].until, DateTime(2026, 11, 28));
      expect(book.unchecked, isEmpty);
    });
  });

  group('one memory per direct chat', () {
    final old = MemoryBook(
      notes: {
        'room:!dm:example.org': '## Plans\n- Lisbon trip in May\n- My sister',
        'handle:wa-anna': '- My sister',
        'handle:sig-anna': '- My sister',
        'room:!family:example.org': 'Family group',
      },
      learned: {
        'room:!dm:example.org': [
          LearnedFact('Planning a trip to Lisbon', at: _now),
          LearnedFact('Works at the post office', at: _now, pinned: true),
          LearnedFact('Very short, lowercase', at: _now, style: true),
        ],
        'handle:wa-anna': [
          LearnedFact('Works at the post office', at: _now),
          LearnedFact('Writes in full sentences', at: _now, style: true),
        ],
        'handle:sig-anna': [
          LearnedFact('Works at the post office', at: _now),
          LearnedFact('Writes in full sentences', at: _now, style: true),
        ],
      },
      suggestions: {
        'room:!dm:example.org': ['Likes jazz'],
      },
      dismissed: {
        'room:!dm:example.org': ['Owns a cat'],
      },
    );
    const chats = [(chatKeys: _room, personKeys: _annaKeys)];

    test('moves the chat\'s into the person\'s, losing nothing', () {
      final book = old.mergeDirectChats(chats);
      expect(
        book.noteFor(_annaKeys),
        '- My sister\n\n## Plans\n- Lisbon trip in May',
      );
      expect(book.noteFor(_room), isEmpty);
      // Not doubled, and the pinned copy wins.
      final facts = book.learnedFor(_annaKeys);
      expect(_texts(facts), [
        'Works at the post office',
        'Writes in full sentences',
        'Planning a trip to Lisbon',
      ]);
      expect(facts.first.pinned, isTrue);
      expect(book.styleFor(_annaKeys)!.text, 'Writes in full sentences');
      // How the user writes here stays the chat's.
      expect(book.styleFor(_room)!.text, 'Very short, lowercase');
      expect(_texts(book.learnedFor(_room)), ['Very short, lowercase']);
      expect(book.suggestionsFor(_annaKeys), ['Likes jazz']);
      expect(book.suggestionsFor(_room), isEmpty);
      // Not learned back under the person either.
      final learnedBack = book.applyLearning(
        const MemoryUpdate(adds: [MemoryAddition('Owns a cat')]),
        chatKeys: _annaKeys,
        people: const [_anna],
        numbered: const [],
        now: _now,
      );
      expect(learnedBack.added, 0);
      // A group's is its own.
      expect(book.noteFor(['room:!family:example.org']), 'Family group');
    });

    test('keeps the book as it was until the move has been read back', () {
      final moved = old.mergeDirectChats(chats);
      expect(moved.merged, isTrue);
      expect(MemoryBook.fromJson(moved.backup).noteFor(_room), isNotEmpty);
      // The run after: what it reads is moved already, and the backup goes.
      final readBack = MemoryBook.decode(moved.encode());
      expect(readBack.merged, isTrue);
      expect(readBack.backup, isNotNull);
      final next = readBack.mergeDirectChats(chats);
      expect(next.backup, isNull);
      expect(next.merged, isTrue);
      expect(next.noteFor(_annaKeys), moved.noteFor(_annaKeys));
      // And nothing more happens after that.
      expect(identical(next.mergeDirectChats(chats), next), isTrue);
    });

    test('nothing to move needs no backup, and folding twice is once', () {
      final empty = MemoryBook.empty.mergeDirectChats(chats);
      expect(empty.merged, isTrue);
      expect(empty.backup, isNull);
      final once = old.foldChatInto(_room, _annaKeys);
      expect(identical(once.foldChatInto(_room, _annaKeys), once), isTrue);
    });

    test('the prompt gets one memory, under the person\'s name', () {
      final block = memoryPromptBlock(
        const AiMemory(chat: '- My sister', about: 'Anna'),
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(block, endsWith('About Anna:\n- My sister'));
    });
  });
}
