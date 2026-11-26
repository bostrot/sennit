import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';

void main() {
  WeftMessage at(int hour, {String? reactionKey}) => WeftMessage(
    eventId: '\$$hour${reactionKey ?? ''}',
    roomId: '!r',
    network: ChatNetwork.whatsapp,
    senderId: '@a:x',
    senderName: 'A',
    timestamp: DateTime(2026, 11, 20, hour),
    kind: MessageKind.text,
    isOwn: false,
    reactionKey: reactionKey,
  );

  Chat chat(
    String id, {
    WeftMessage? message,
    WeftMessage? reaction,
    DateTime? activityAt,
  }) => Chat(
    id: id,
    title: id,
    sources: [ChatSource(roomId: id, network: ChatNetwork.whatsapp)],
    lastMessage: message,
    lastReaction: reaction,
    activityAt: activityAt,
  );

  group('Chat.lastActivityAt', () {
    test('is the newer of the message and the reaction', () {
      expect(
        chat(
          'a',
          message: at(10),
          reaction: at(12, reactionKey: '👍'),
        ).lastActivityAt,
        DateTime(2026, 11, 20, 12),
      );
      expect(
        chat(
          'a',
          message: at(12),
          reaction: at(10, reactionKey: '👍'),
        ).lastActivityAt,
        DateTime(2026, 11, 20, 12),
      );
    });

    test('activityAt counts where no preview stands for it', () {
      final reacted = DateTime(2026, 11, 20, 15);
      // A reaction still encrypted: known to have happened, nothing to show.
      expect(
        chat('a', message: at(10), activityAt: reacted).lastActivityAt,
        reacted,
      );
      expect(
        chat('a', message: at(16), activityAt: reacted).lastActivityAt,
        DateTime(2026, 11, 20, 16),
      );
      expect(chat('a', activityAt: reacted).lastActivityAt, reacted);
    });

    test('lastActivity is what the row previews', () {
      final reaction = at(12, reactionKey: '👍');
      expect(
        chat('a', message: at(10), reaction: reaction).lastActivity,
        reaction,
      );
      expect(
        chat('a', message: at(13), reaction: reaction).lastActivity!.eventId,
        r'$13',
      );
    });
  });

  test('byActivity is newest first with unknowns last, whatever the start', () {
    final chats = [
      chat('none'),
      chat('ten', message: at(10)),
      chat(
        'reacted',
        message: at(9),
        reaction: at(11, reactionKey: '❤️'),
      ),
      chat('none2'),
      chat('eight', message: at(8)),
    ];
    for (final start in [chats, chats.reversed.toList()]) {
      final sorted = [...start]..sort(Chat.byActivity);
      expect(sorted.take(3).map((c) => c.id), ['reacted', 'ten', 'eight']);
      expect(sorted.skip(3).map((c) => c.id).toSet(), {'none', 'none2'});
    }
  });

  test('a new reaction is a change the row has to redraw for', () {
    final before = chat('a', message: at(10));
    final after = chat(
      'a',
      message: at(10),
      reaction: at(12, reactionKey: '👍'),
    );
    expect(before.sameContentAs(after), isFalse);
    expect(after.sameContentAs(after.copyWith()), isTrue);
  });
}
