import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/data/chat_repository.dart';

/// Which networks have something waiting, for the rail's badges.
///
/// A merged conversation shows one badge in the inbox — the sum of its legs,
/// which is the right answer to "how much is waiting from this person". The
/// rail asks a different question, and answering it from that sum meant a
/// single WhatsApp message lit up Signal, Telegram and Instagram as well: the
/// rail claimed something was waiting on three networks where nothing was, and
/// filtering to any of them showed an inbox with no unread chat in it.
void main() {
  WeftMessage message(ChatNetwork network) => WeftMessage(
    eventId: '\$e-${network.id}',
    roomId: '!r-${network.id}:example.org',
    network: network,
    senderId: '@them:example.org',
    senderName: 'Them',
    timestamp: DateTime(2026, 8, 27, 10),
    kind: MessageKind.text,
    isOwn: false,
    body: 'hello',
  );

  ChatSource leg(ChatNetwork network, {int unread = 0}) => ChatSource(
    roomId: '!r-${network.id}:example.org',
    network: network,
    unread: unread,
  );

  test('a one-network chat counts against that network', () {
    final counts = unreadByNetwork([
      Chat(
        id: 'a',
        title: 'Anna',
        sources: [leg(ChatNetwork.whatsapp, unread: 3)],
        unreadCount: 3,
        lastMessage: message(ChatNetwork.whatsapp),
      ),
    ]);

    expect(counts, {ChatNetwork.whatsapp: 3});
  });

  test('a merged chat counts only the legs that are waiting', () {
    final counts = unreadByNetwork([
      Chat(
        id: 'merged:anna',
        title: 'Anna',
        sources: [
          leg(ChatNetwork.whatsapp, unread: 2),
          leg(ChatNetwork.signal),
          leg(ChatNetwork.telegram),
        ],
        unreadCount: 2,
        lastMessage: message(ChatNetwork.whatsapp),
      ),
    ]);

    expect(
      counts,
      {ChatNetwork.whatsapp: 2},
      reason: 'nothing arrived on Signal or Telegram, so neither is waiting',
    );
  });

  test('a merged chat waiting on two legs counts both, separately', () {
    final counts = unreadByNetwork([
      Chat(
        id: 'merged:anna',
        title: 'Anna',
        sources: [
          leg(ChatNetwork.whatsapp, unread: 2),
          leg(ChatNetwork.signal, unread: 1),
          leg(ChatNetwork.telegram),
        ],
        unreadCount: 3,
        lastMessage: message(ChatNetwork.signal),
      ),
    ]);

    expect(counts, {ChatNetwork.whatsapp: 2, ChatNetwork.signal: 1});
  });

  test('a read conversation counts nowhere', () {
    final counts = unreadByNetwork([
      Chat(
        id: 'merged:anna',
        title: 'Anna',
        sources: [leg(ChatNetwork.whatsapp), leg(ChatNetwork.signal)],
        lastMessage: message(ChatNetwork.whatsapp),
      ),
    ]);

    expect(counts, isEmpty);
  });

  test('several chats add up per network', () {
    final counts = unreadByNetwork([
      Chat(
        id: 'a',
        title: 'Anna',
        sources: [leg(ChatNetwork.whatsapp, unread: 2)],
        unreadCount: 2,
        lastMessage: message(ChatNetwork.whatsapp),
      ),
      Chat(
        id: 'b',
        title: 'Ben',
        sources: [leg(ChatNetwork.whatsapp, unread: 5)],
        unreadCount: 5,
        lastMessage: message(ChatNetwork.whatsapp),
      ),
    ]);

    expect(counts, {ChatNetwork.whatsapp: 7});
  });

  test('a chat whose legs say nothing still lands somewhere', () {
    // Not every repository folds chats out of rooms — the demo one builds them
    // directly — and a badge dropped on the floor is a worse answer than one
    // attributed to the network the newest message came on.
    final counts = unreadByNetwork([
      Chat(
        id: 'a',
        title: 'Anna',
        sources: [leg(ChatNetwork.whatsapp), leg(ChatNetwork.signal)],
        unreadCount: 4,
        lastMessage: message(ChatNetwork.signal),
      ),
    ]);

    expect(counts, {ChatNetwork.signal: 4});
  });
}
