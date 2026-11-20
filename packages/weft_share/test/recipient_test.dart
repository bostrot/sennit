import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_share/weft_share.dart';

import 'support/fixtures.dart';

List<String> idsOf(List<Chat> chats) => [for (final c in chats) c.id];

void main() {
  group('rankMessageRecipients', () {
    test('an exact title beats a word prefix, which beats a substring', () {
      final matches = rankMessageRecipients([
        chat(id: 'sub', title: 'Joanna'),
        chat(id: 'prefix', title: 'Anna Maria'),
        chat(id: 'exact', title: 'anna'),
      ], 'Anna');

      expect(idsOf(matches), ['exact', 'prefix', 'sub']);
    });

    test('ties keep the inbox order', () {
      final matches = rankMessageRecipients([
        chat(id: 'first', title: 'Alex Kim'),
        chat(id: 'second', title: 'Alex Roe'),
      ], 'alex');

      expect(idsOf(matches), ['first', 'second']);
    });

    test('leaves out archived chats and unanswered requests', () {
      final matches = rankMessageRecipients([
        chat(id: 'archived', title: 'Anna', archived: true),
        chat(id: 'pending', title: 'Anna', request: ChatRequestState.pending),
        chat(id: 'declined', title: 'Anna', request: ChatRequestState.declined),
        chat(id: 'accepted', title: 'Anna', request: ChatRequestState.accepted),
      ], 'Anna');

      expect(idsOf(matches), ['accepted']);
    });

    test('collapses whitespace and ignores case', () {
      final matches = rankMessageRecipients([
        chat(id: 'am', title: 'Anna  Maria'),
      ], ' anna maria ');

      expect(idsOf(matches), ['am']);
    });

    test('an empty query matches nothing', () {
      expect(
        rankMessageRecipients([chat(id: 'a', title: 'Anna')], '  '),
        isEmpty,
      );
    });

    test('caps the list', () {
      final matches = rankMessageRecipients([
        for (var i = 0; i < 9; i++) chat(id: 'a$i', title: 'Anna $i'),
      ], 'anna');

      expect(matches, hasLength(kMaxRecipientMatches));
    });
  });

  group('resolveMessageRecipient', () {
    test('one exact title wins over looser matches', () {
      final result = resolveMessageRecipient([
        chat(id: 'alexandra', title: 'Alexandra'),
        chat(id: 'alex', title: 'Alex'),
      ], 'alex');

      expect(result, isA<RecipientResolved>());
      expect((result as RecipientResolved).chat.id, 'alex');
    });

    test('the only match of any kind is chosen', () {
      final result = resolveMessageRecipient([
        chat(id: 'alexandra', title: 'Alexandra Kim'),
        chat(id: 'bob', title: 'Bob'),
      ], 'alex');

      expect((result as RecipientResolved).chat.id, 'alexandra');
    });

    test('two loose matches are the user\'s call', () {
      final result = resolveMessageRecipient([
        chat(id: 'alexandra', title: 'Alexandra'),
        chat(id: 'alexis', title: 'Alexis'),
      ], 'al');

      expect(result, isA<RecipientAmbiguous>());
      expect(idsOf((result as RecipientAmbiguous).candidates), [
        'alexandra',
        'alexis',
      ]);
    });

    test('two chats with the same title are ambiguous', () {
      // One person is one merged chat, so two exact matches are two people.
      final result = resolveMessageRecipient([
        chat(id: 'work', title: 'Sam'),
        chat(id: 'home', title: 'Sam'),
        chat(id: 'samira', title: 'Samira'),
      ], 'sam');

      expect(idsOf((result as RecipientAmbiguous).candidates), [
        'work',
        'home',
      ]);
    });

    test('a merged contact resolves to its one merged chat', () {
      final result = resolveMessageRecipient([
        chat(
          id: 'merged:anna',
          title: 'Anna',
          networks: const [ChatNetwork.whatsapp, ChatNetwork.signal],
        ),
      ], 'Anna');

      expect((result as RecipientResolved).chat.id, 'merged:anna');
    });

    test('no match, or no name, finds nothing', () {
      expect(
        resolveMessageRecipient([chat(id: 'a', title: 'Anna')], 'Zoe'),
        isA<RecipientNotFound>(),
      );
      expect(
        resolveMessageRecipient([chat(id: 'a', title: 'Anna')], ''),
        isA<RecipientNotFound>(),
      );
    });

    test('a pending request is never resolved', () {
      expect(
        resolveMessageRecipient([
          chat(id: 'p', title: 'Anna', request: ChatRequestState.pending),
        ], 'Anna'),
        isA<RecipientNotFound>(),
      );
    });
  });
}
