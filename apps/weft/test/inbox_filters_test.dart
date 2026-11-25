import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/attachment_fixtures.dart';

/// The inbox's quick filters beyond unread, groups and people: the chats
/// waiting on an answer, and the archive narrowed to the networks picked.
void main() {
  WeftMessage message({
    bool isOwn = false,
    MessageKind kind = MessageKind.text,
    bool notice = false,
    ChatNetwork network = ChatNetwork.whatsapp,
  }) => WeftMessage(
    eventId: r'$1',
    roomId: '!room:example.org',
    network: network,
    senderId: isOwn ? '@me:example.org' : '@them:example.org',
    senderName: isOwn ? 'Me' : 'Them',
    timestamp: DateTime.utc(2026, 11, 25, 12),
    kind: kind,
    isOwn: isOwn,
    isBridgeNotice: notice,
    body: 'hi',
  );

  Chat chat(
    String id, {
    WeftMessage? last,
    bool isGroup = false,
    int? peers,
    bool archived = false,
    ChatNetwork network = ChatNetwork.whatsapp,
  }) => Chat(
    id: id,
    title: id,
    sources: [ChatSource(roomId: id, network: network)],
    lastMessage: last,
    isGroup: isGroup,
    participantCount: peers,
    archived: archived,
  );

  group('needsReply', () {
    test('someone else spoke last, read or not', () {
      expect(needsReply(chat('!a', last: message())), isTrue);
      expect(
        needsReply(
          Chat(
            id: '!b',
            title: 'b',
            sources: const [],
            lastMessage: message(),
            unreadCount: 3,
          ),
        ),
        isTrue,
      );
    });

    test('not when the user answered or nothing was said', () {
      expect(needsReply(chat('!a', last: message(isOwn: true))), isFalse);
      expect(needsReply(chat('!a')), isFalse);
      expect(
        needsReply(chat('!a', last: message(kind: MessageKind.event))),
        isFalse,
      );
      expect(needsReply(chat('!a', last: message(notice: true))), isFalse);
    });

    test('small groups count, big or unknown ones do not', () {
      expect(
        needsReply(chat('!g', last: message(), isGroup: true, peers: 4)),
        isTrue,
      );
      expect(
        needsReply(chat('!g', last: message(), isGroup: true, peers: 40)),
        isFalse,
      );
      expect(needsReply(chat('!g', last: message(), isGroup: true)), isFalse);
    });
  });

  group('visible chats', () {
    late WeftStores stores;
    late StubChatRepository repository;
    late ProviderContainer container;

    final chats = [
      chat('!waiting', last: message()),
      chat('!answered', last: message(isOwn: true)),
      chat('!wa-old', last: message(), archived: true),
      chat(
        '!signal-old',
        last: message(network: ChatNetwork.signal),
        archived: true,
        network: ChatNetwork.signal,
      ),
    ];

    setUp(() async {
      stores = WeftStores.inMemory();
      repository = StubChatRepository();
      container = ProviderContainer(
        overrides: [
          storesProvider.overrideWithValue(stores),
          chatRepositoryProvider.overrideWithValue(repository),
          chatsProvider.overrideWith((ref) => Stream.value(chats)),
        ],
      );
      container.listen(visibleChatsProvider, (_, _) {});
      await container.read(chatsProvider.future);
    });

    tearDown(() {
      container.dispose();
      repository.dispose();
      stores.dispose();
    });

    List<String> visible() => [
      for (final c in container.read(visibleChatsProvider)) c.id,
    ];

    test('needs reply keeps only the chats waiting on the user', () {
      container
          .read(inboxQuickFilterProvider.notifier)
          .toggle(InboxQuickFilter.needsReply);
      expect(visible(), ['!waiting']);
    });

    test('the archive narrows to the network picked', () {
      container.read(showArchivedProvider.notifier).toggle();
      expect(visible(), unorderedEquals(['!wa-old', '!signal-old']));

      container.read(networkFilterProvider.notifier).toggle(ChatNetwork.signal);
      expect(visible(), ['!signal-old']);
    });
  });
}
