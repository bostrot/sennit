import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft_domain/weft_domain.dart';

/// The repository half of rich content: reacting, un-reacting, editing,
/// redacting and replying, and where each of them lands.
///
/// Driven through [DemoChatRepository] because it runs the *real* aggregation
/// out of `weft_richtext` over in-memory fixtures — the tallies and edit
/// histories asserted here are built by the same functions the Matrix path
/// uses, with no homeserver in the way. What is genuinely Matrix-shaped
/// (`m.annotation` and `m.replace` extraction) is tested in
/// `packages/weft_matrix/test/mapping_test.dart`.
void main() {
  /// Anna is the merged fixture: three legs, and her Signal leg spoke last, so
  /// the chat's default send network is Signal. Every routing assertion below
  /// deliberately picks a message on one of the *other* two.
  const mergedChat = 'merged:anna';
  const telegramRoom = '!anna_tg_room:example.org';

  late DemoChatRepository repository;

  setUp(() => repository = DemoChatRepository(uploadTick: Duration.zero));
  tearDown(() => repository.dispose());

  /// Every message loaded across a chat's legs, watermark and all.
  ///
  /// Read per source rather than through `view()` on purpose: the merged view
  /// hides messages below the watermark, and this is about what the relations
  /// did to a specific event, not about what is safe to render yet.
  Future<List<WeftMessage>> loadedOf(String chatId) async {
    final timeline = await repository.timelineFor(chatId);
    for (var round = 0; round < 6; round++) {
      await timeline.loadMore(count: 30);
    }
    return [for (final source in timeline.sources) ...source.loaded];
  }

  Future<WeftMessage> messageIn(String chatId, String roomId) async {
    final loaded = await loadedOf(chatId);
    return loaded.firstWhere((m) => m.roomId == roomId && !m.isOwn);
  }

  Future<WeftMessage> reload(String chatId, String eventId) async {
    final loaded = await loadedOf(chatId);
    return loaded.firstWhere((m) => m.eventId == eventId);
  }

  group('react', () {
    test('a reaction lands on the message it names, as one person', () async {
      final target = await messageIn(mergedChat, telegramRoom);
      await repository.react(mergedChat, target.eventId, '👍');

      final reacted = await reload(mergedChat, target.eventId);
      expect(reacted.reactions, hasLength(1));
      expect(reacted.reactions.single.key, '👍');
      expect(reacted.reactions.single.count, 1);
      expect(reacted.reactions.single.byLocalUser, isTrue);
      // The id `unreact` redacts. There is no recovering it from the tally
      // afterwards, which is why aggregation carries it.
      expect(reacted.reactions.single.localEventId, isNotNull);
    });

    test('reacting twice with the same key is still one person', () async {
      // Two taps in the same frame, or a timeline replaying an annotation
      // across a pagination boundary: either way they reacted once.
      final target = await messageIn(mergedChat, telegramRoom);
      await repository.react(mergedChat, target.eventId, '👍');
      await repository.react(mergedChat, target.eventId, '👍');

      final reacted = await reload(mergedChat, target.eventId);
      expect(reacted.reactions.single.count, 1);

      // And one un-react clears it. A second annotation the tally had deduped
      // away would survive the redaction and put the chip straight back, which
      // reads as the tap having done nothing.
      await repository.unreact(
        mergedChat,
        reacted.reactions.single.localEventId!,
      );
      expect((await reload(mergedChat, target.eventId)).reactions, isEmpty);
    });

    test('no other message in the conversation gains a chip', () async {
      final target = await messageIn(mergedChat, telegramRoom);
      await repository.react(mergedChat, target.eventId, '👍');

      final others = (await loadedOf(
        mergedChat,
      )).where((m) => m.eventId != target.eventId);
      expect(others.every((m) => m.reactions.isEmpty), isTrue);
    });

    test('an event that is not in this chat is refused, not sent', () async {
      // The failure this prevents is invisible rather than loud: an annotation
      // pointed at an event the destination room has never heard of is stored
      // happily by the homeserver and rendered by nobody, including the sender.
      expect(
        () => repository.react(mergedChat, r'$not-here:example.org', '👍'),
        throwsStateError,
      );
    });
  });

  group('unreact', () {
    test('redacting the local annotation removes the tally', () async {
      final target = await messageIn(mergedChat, telegramRoom);
      await repository.react(mergedChat, target.eventId, '👍');

      final reacted = await reload(mergedChat, target.eventId);
      await repository.unreact(
        mergedChat,
        reacted.reactions.single.localEventId!,
      );

      expect((await reload(mergedChat, target.eventId)).reactions, isEmpty);
    });

    test('only the named annotation goes', () async {
      final target = await messageIn(mergedChat, telegramRoom);
      await repository.react(mergedChat, target.eventId, '👍');
      await repository.react(mergedChat, target.eventId, '🎉');

      final reacted = await reload(mergedChat, target.eventId);
      final thumbs = reacted.reactions.firstWhere((r) => r.key == '👍');
      await repository.unreact(mergedChat, thumbs.localEventId!);

      final after = await reload(mergedChat, target.eventId);
      expect(after.reactions.map((r) => r.key), ['🎉']);
    });
  });

  group('editMessage', () {
    test('the newest version is what the bubble reads', () async {
      final target = await messageIn(mergedChat, telegramRoom);
      await repository.editMessage(mergedChat, target.eventId, 'Friday, 14:00');

      final edited = await reload(mergedChat, target.eventId);
      expect(edited.body, 'Friday, 14:00');
      expect(edited.isEdited, isTrue);
      // Oldest first, the original included: the words that were replaced exist
      // nowhere else once the timeline has resolved the edit.
      expect(edited.editHistory.map((r) => r.body).first, target.body);
      expect(edited.editHistory.last.body, 'Friday, 14:00');
    });

    test('a second edit appends rather than replacing the history', () async {
      final target = await messageIn(mergedChat, telegramRoom);
      await repository.editMessage(mergedChat, target.eventId, 'Friday');
      await repository.editMessage(mergedChat, target.eventId, 'Saturday');

      final edited = await reload(mergedChat, target.eventId);
      expect(edited.body, 'Saturday');
      expect(edited.editHistory, hasLength(3));
    });

    test('an event that is not in this chat is refused', () async {
      expect(
        () => repository.editMessage(mergedChat, r'$not-here:example.org', 'x'),
        throwsStateError,
      );
    });
  });

  group('redact', () {
    test('a deleted message keeps no text, tally or history', () async {
      final target = await messageIn(mergedChat, telegramRoom);
      await repository.react(mergedChat, target.eventId, '👍');
      await repository.editMessage(mergedChat, target.eventId, 'Friday');
      await repository.redact(mergedChat, target.eventId);

      final deleted = await reload(mergedChat, target.eventId);
      expect(deleted.redacted, isTrue);
      expect(deleted.body, isEmpty);
      // Both are gone from the server too — a count over "message deleted"
      // would be a tally of something nobody can read.
      expect(deleted.reactions, isEmpty);
      expect(deleted.editHistory, isEmpty);
    });
  });

  group('sendReply', () {
    test('a reply rides the leg its target lives on', () async {
      // Anna's Signal leg spoke last, so the chat's default send network is
      // Signal — and this reply answers a Telegram message. Sending it down
      // the default leg would produce an `m.in_reply_to` naming an event that
      // room has never heard of: a quote of nothing, for everyone.
      final chat = (await repository.watchChats().first).firstWhere(
        (c) => c.id == mergedChat,
      );
      expect(chat.sendNetwork, ChatNetwork.signal);

      final target = await messageIn(mergedChat, telegramRoom);
      await repository.sendReply(
        mergedChat,
        'Yes, see you then',
        replyToEventId: target.eventId,
      );

      final reply = (await loadedOf(
        mergedChat,
      )).firstWhere((m) => m.body == 'Yes, see you then');
      expect(reply.roomId, telegramRoom);
      expect(reply.network, ChatNetwork.telegram);
      expect(reply.replyToEventId, target.eventId);
    });

    test('a reply to something unreachable still sends', () async {
      // The target has scrolled out of every loaded timeline, or the leg is
      // gone. Losing what the user typed is worse than losing the quote.
      await repository.sendReply(
        mergedChat,
        'sent anyway',
        replyToEventId: r'$not-here:example.org',
        via: ChatNetwork.whatsapp,
      );

      final chats = await repository.watchChats().first;
      final chat = chats.firstWhere((c) => c.id == mergedChat);
      expect(chat.lastMessage?.body, 'sent anyway');
      expect(chat.lastMessage?.network, ChatNetwork.whatsapp);
    });
  });
}
