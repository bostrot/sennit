/// Automatic memory: how what the model learned is written into a chat's and
/// its people's memory without anyone accepting it, and how the user stays in
/// charge of it.
///
/// The claims that matter: a note the user wrote is never touched, a pinned or
/// edited fact is never changed or dropped, a deleted fact is not learned back,
/// and the last automatic update can be taken back whole.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/ai/person_memory.dart';

const _chat = ['room:!dm:example.org'];
const _annaKeys = ['handle:wa-anna', 'handle:sig-anna'];
const MemoryPerson _anna = (name: 'Anna Schmidt', keys: _annaKeys);

final _monday = DateTime(2026, 11, 23, 9);
final _tuesday = DateTime(2026, 11, 24, 9);

({MemoryBook book, int added, int updated, int dropped}) _apply(
  MemoryBook book,
  MemoryUpdate update, {
  List<NumberedFact>? numbered,
  DateTime? now,
}) => book.applyLearning(
  update,
  chatKeys: _chat,
  people: const [_anna],
  numbered: numbered ?? book.numberedFacts(_chat, const [_anna]),
  now: now ?? _tuesday,
);

List<String> _texts(List<LearnedFact> facts) => [for (final f in facts) f.text];

void main() {
  group('applyLearning', () {
    test('files a fact under the person it is about, else the chat', () {
      final result = _apply(
        MemoryBook.empty,
        const MemoryUpdate(
          adds: [
            MemoryAddition('Birthday on 3 June', about: 'Anna'),
            MemoryAddition('Planning a trip to Lisbon in May'),
            MemoryAddition('Prefers du', about: 'Someone Else'),
          ],
        ),
      );
      expect(result.added, 3);
      // "Anna" finds "Anna Schmidt", and every handle of hers gets it.
      for (final key in _annaKeys) {
        expect(_texts(result.book.learnedFor([key])), ['Birthday on 3 June']);
      }
      // Nobody called that in this chat: the chat's, not lost.
      expect(_texts(result.book.learnedFor(_chat)), [
        'Planning a trip to Lisbon in May',
        'Prefers du',
      ]);
      expect(result.book.learnedFor(_chat).first.at, _tuesday);
      expect(result.book.learnedFor(_chat).first.pinned, isFalse);
    });

    test('never touches a note, and leaves out what it already says', () {
      final book = MemoryBook.empty
          .withNote(_chat, '- Lisbon trip in May')
          .withNote(_annaKeys, '- Birthday 3 June\n- My sister');
      final result = _apply(
        book,
        const MemoryUpdate(
          adds: [
            MemoryAddition('lisbon trip in may!'),
            MemoryAddition('My sister', about: 'Anna'),
            MemoryAddition('Has a dog called Bruno', about: 'Anna'),
          ],
        ),
      );
      expect(result.added, 1);
      expect(result.book.notes, book.notes);
      expect(_texts(result.book.learnedFor(_annaKeys)), [
        'Has a dog called Bruno',
      ]);
    });

    test('dedupes against what was learned, and lets more detail in', () {
      var book = _apply(
        MemoryBook.empty,
        const MemoryUpdate(
          adds: [MemoryAddition('Has two kids', about: 'Anna')],
        ),
        now: _monday,
      ).book;
      final again = _apply(
        book,
        const MemoryUpdate(
          adds: [
            MemoryAddition('- has two kids.', about: 'Anna'),
            MemoryAddition('Has two kids: Mia and Ben', about: 'Anna'),
          ],
        ),
      );
      book = again.book;
      expect(again.added, 0);
      expect(again.updated, 1);
      expect(_texts(book.learnedFor(_annaKeys)), ['Has two kids: Mia and Ben']);
      expect(book.learnedFor(_annaKeys).single.at, _tuesday);
    });

    test('rewrites and drops by number, never a pinned fact', () {
      var book = _apply(
        MemoryBook.empty,
        const MemoryUpdate(
          adds: [
            MemoryAddition('Works at the post office', about: 'Anna'),
            MemoryAddition('Meeting on Saturday'),
            MemoryAddition('Calls me Ricky'),
          ],
        ),
        now: _monday,
      ).book;
      final ricky = book.learnedFor(_chat).last;
      book = book.pinLearned(_chat, ricky, pinned: true);

      final numbered = book.numberedFacts(_chat, const [_anna]);
      // Pinned facts are not offered to the model at all.
      expect(
        _texts([for (final n in numbered) LearnedFact(n.text, at: _monday)]),
        ['Meeting on Saturday', 'Works at the post office'],
      );
      expect(numbered.last.about, 'Anna Schmidt');

      final result = _apply(
        book,
        const MemoryUpdate(
          updates: [
            (
              id: 2,
              fact: 'Works at Deutsche Bahn since November',
              until: null,
              after: null,
            ),
            (id: 9, fact: 'Out of range', until: null, after: null),
          ],
          drops: [1],
        ),
        numbered: [
          ...numbered,
          // A model that numbers the pinned one anyway gets nowhere.
          (keys: _chat, about: null, text: 'Calls me Ricky', until: null),
        ],
      );
      expect(result.updated, 1);
      expect(result.dropped, 1);
      expect(_texts(result.book.learnedFor(_chat)), ['Calls me Ricky']);
      expect(_texts(result.book.learnedFor(_annaKeys)), [
        'Works at Deutsche Bahn since November',
      ]);

      final pinnedDrop = _apply(
        result.book,
        const MemoryUpdate(drops: [1]),
        numbered: const [
          (keys: _chat, about: null, text: 'Calls me Ricky', until: null),
        ],
      );
      expect(pinnedDrop.dropped, 0);
      expect(identical(pinnedDrop.book, result.book), isTrue);
    });

    test('keeps the newest facts per layer, and every pinned one', () {
      var book = MemoryBook.empty;
      for (var i = 0; i < kPersonLearnedLimit + 4; i++) {
        book = _apply(
          book,
          MemoryUpdate(adds: [MemoryAddition('Fact number $i', about: 'Anna')]),
          now: _monday.add(Duration(minutes: i)),
        ).book;
        if (i == 0) {
          book = book.pinLearned(
            _annaKeys,
            book.learnedFor(_annaKeys).single,
            pinned: true,
          );
        }
      }
      final facts = _texts(book.learnedFor(_annaKeys));
      expect(facts, hasLength(kPersonLearnedLimit));
      expect(facts.first, 'Fact number 0');
      expect(facts.last, 'Fact number ${kPersonLearnedLimit + 3}');
      expect(facts, isNot(contains('Fact number 1')));
    });

    test('nothing to change is no update, and nothing to undo', () {
      final result = _apply(MemoryBook.empty, const MemoryUpdate());
      expect(result.book.undo, isNull);
      expect(result.book.isEmpty, isTrue);
    });
  });

  group('the user stays in charge', () {
    MemoryBook learned() => _apply(
      MemoryBook.empty,
      const MemoryUpdate(
        adds: [
          MemoryAddition('Likes jazz', about: 'Anna'),
          MemoryAddition('Planning Lisbon'),
        ],
      ),
      now: _monday,
    ).book;

    test('an edited fact is pinned, and the model leaves it alone', () {
      var book = learned();
      final jazz = book.learnedFor(_annaKeys).single;
      book = book.editLearned(_annaKeys, jazz, 'Likes blues', now: _tuesday);
      final edited = book.learnedFor(_annaKeys).single;
      expect(edited.text, 'Likes blues');
      expect(edited.pinned, isTrue);
      expect(edited.edited, isTrue);
      expect(edited.at, _tuesday);
      expect(book.numberedFacts(_chat, const [_anna]).map((n) => n.text), [
        'Planning Lisbon',
      ]);
    });

    test('a deleted fact is not learned back', () {
      var book = learned();
      book = book.deleteLearned(_annaKeys, book.learnedFor(_annaKeys).single);
      expect(book.learnedFor(_annaKeys), isEmpty);
      final again = _apply(
        book,
        const MemoryUpdate(adds: [MemoryAddition('likes jazz', about: 'Anna')]),
      );
      expect(again.added, 0);
      expect(again.book.learnedFor(_annaKeys), isEmpty);
    });

    test('an empty edit deletes', () {
      var book = learned();
      book = book.editLearned(
        _chat,
        book.learnedFor(_chat).single,
        '  ',
        now: _tuesday,
      );
      expect(book.learnedFor(_chat), isEmpty);
    });

    test('undo puts the last update back and keeps it from returning', () {
      final before = learned();
      final after = _apply(
        before,
        const MemoryUpdate(
          adds: [MemoryAddition('Has a cat', about: 'Anna')],
          drops: [1],
        ),
      ).book;
      expect(_texts(after.learnedFor(_chat)), isEmpty);
      expect(after.undoTouches(_chat), isTrue);
      expect(after.undoTouches(_annaKeys), isTrue);

      final undone = after.undoAutomatic();
      expect(undone.undo, isNull);
      expect(_texts(undone.learnedFor(_chat)), ['Planning Lisbon']);
      expect(_texts(undone.learnedFor(_annaKeys)), ['Likes jazz']);
      // What it added is unwanted now.
      final again = _apply(
        undone,
        const MemoryUpdate(adds: [MemoryAddition('Has a cat', about: 'Anna')]),
      );
      expect(again.added, 0);
    });

    test('undo keeps what the user pinned since the update', () {
      final after = _apply(
        learned(),
        const MemoryUpdate(adds: [MemoryAddition('Has a cat', about: 'Anna')]),
      ).book;
      final cat = after.learnedFor(_annaKeys).last;
      final edited = after.editLearned(
        _annaKeys,
        cat,
        'Has a cat called Mo',
        now: _tuesday.add(const Duration(hours: 1)),
      );
      final undone = edited.undoAutomatic();
      expect(_texts(undone.learnedFor(_annaKeys)), [
        'Likes jazz',
        'Has a cat called Mo',
      ]);
    });

    test('forgetting a person drops their learned facts and undo', () {
      final book = learned().forget(_annaKeys);
      expect(book.learnedFor(_annaKeys), isEmpty);
      expect(book.undoTouches(_annaKeys), isFalse);
      expect(book.undoTouches(_chat), isTrue);
    });
  });

  group('what the prompts and the backup see', () {
    test('memoryFor is the note, then the learned facts it lacks', () {
      final book = _apply(
        MemoryBook.empty.withNote(_annaKeys, 'My sister'),
        const MemoryUpdate(
          adds: [
            MemoryAddition('Birthday 3 June', about: 'Anna'),
            MemoryAddition('Formal: Sie', about: 'Anna'),
          ],
        ),
      ).book;
      expect(
        book.memoryFor(_annaKeys),
        'My sister\n\n- Birthday 3 June\n- Formal: Sie',
      );
      expect(MemoryBook.empty.memoryFor(_annaKeys), isEmpty);
      expect(
        book.notesWithLearned['handle:wa-anna'],
        book.memoryFor(_annaKeys),
      );
    });

    test('learned facts, pins and undo survive the keychain', () {
      var book = _apply(
        MemoryBook.empty,
        const MemoryUpdate(adds: [MemoryAddition('Likes jazz', about: 'Anna')]),
      ).book;
      book = book.pinLearned(
        _annaKeys,
        book.learnedFor(_annaKeys).single,
        pinned: true,
      );
      final back = MemoryBook.decode(book.encode());
      expect(back.learnedFor(_annaKeys), book.learnedFor(_annaKeys));
      expect(back.learnedFor(_annaKeys).single.pinned, isTrue);
      expect(back.undoTouches(_annaKeys), isTrue);
      expect(back.undoAutomatic().learnedFor(_annaKeys), isEmpty);
      // An older blob without any of it still reads.
      expect(MemoryBook.decode('{"version": 1, "notes": {"a": "b"}}').notes, {
        'a': 'b',
      });
      expect(book.toString(), isNot(contains('jazz')));
    });
  });

  group('parseMemoryUpdate', () {
    test('reads adds, updates and drops, through reasoning and fences', () {
      final update = parseMemoryUpdate(
        '<think>Anna moved.</think>\n```json\n'
        '{"add": [{"fact": "Moved to Hamburg", "about": "Anna"}, '
        '{"fact": "Plans a party", "about": "chat"}, "Likes tea"], '
        '"update": [{"id": "2", "fact": "Works remotely"}, {"id": 3}], '
        '"drop": [1, "4", {"id": 5}]}\n```',
      )!;
      expect(
        [for (final a in update.adds) (a.fact, a.about)],
        [
          ('Moved to Hamburg', 'Anna'),
          ('Plans a party', null),
          ('Likes tea', null),
        ],
      );
      expect(update.updates, [
        (id: 2, fact: 'Works remotely', until: null, after: null),
      ]);
      expect(update.drops, [1, 4, 5]);
    });

    test('reads the older facts list as additions', () {
      final update = parseMemoryUpdate('{"facts": ["Has a dog"]}')!;
      expect(update.adds.single.fact, 'Has a dog');
      expect(update.updates, isEmpty);
    });

    test('nothing changing is empty, nothing readable is null', () {
      expect(
        parseMemoryUpdate('{"add": [], "update": [], "drop": []}')!.isEmpty,
        isTrue,
      );
      expect(parseMemoryUpdate('Anna seems nice.'), isNull);
      expect(parseMemoryUpdate('<think>Anna'), isNull);
    });
  });

  group('memoryUpdateRequest', () {
    test('numbers what was learned, and marks what is fixed', () {
      final messages = memoryUpdateRequest(
        transcript: const ['Anna: Ich bin jetzt bei der Bahn'],
        chatTitle: 'Anna',
        people: const ['Anna'],
        today: DateTime(2026, 11, 26),
        fixed: 'About Anna:\n- My sister',
        numbered: [
          (
            keys: _annaKeys,
            about: 'Anna',
            text: 'Works at the post office',
            until: null,
          ),
          (
            keys: _annaKeys,
            about: 'Anna',
            text: 'Dentist on 27 Nov',
            until: DateTime(2026, 11, 28),
          ),
        ],
      );
      final last = messages.last['content']!;
      expect(last, contains('Anna: Ich bin jetzt bei der Bahn'));
      expect(last, contains('People: Anna'));
      expect(
        last,
        contains('The user wrote (fixed):\nAbout Anna:\n- My sister'),
      );
      expect(last, contains('1. [Anna] Works at the post office\n'));
      expect(last, contains('2. [Anna] Dentist on 27 Nov (until 2026-11-27)'));
      expect(last, startsWith('Today is 2026-11-26 (Thu).'));
      expect(messages.first['content'], contains('"drop"'));
    });
  });
}
