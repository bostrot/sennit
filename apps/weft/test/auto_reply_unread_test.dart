import 'package:flutter_test/flutter_test.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_snapshot/weft_snapshot.dart';

import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/matrix_chat_repository.dart';

import 'support/auto_reply_fakes.dart';

/// The unread guarantee, which is the whole point of the feature.
///
/// Replying normally marks a chat read on every network here, and on Sennit's
/// own inbox it does so *without any receipt at all* — writing a message moves
/// the room's newest event past every receipt it holds, and `isReadLocally`
/// reads that as the user having caught up. That is right for a message they
/// typed and wrong for one their model sent, and everything below is about the
/// second case.
///
/// Four surfaces have to agree: the room's own count, the inbox row built from
/// it, the receipt on the wire, and the snapshot the widget and the watch read.
void main() {
  const room = '!room:example.org';

  Chat unreadChat({int unread = 3, WeftMessage? last}) => Chat(
    id: room,
    title: 'Grace',
    unreadCount: unread,
    lastMessage: last,
    sources: const [ChatSource(roomId: room, network: ChatNetwork.whatsapp)],
  );

  WeftMessage incoming({String body = 'are you around?'}) => WeftMessage(
    eventId: r'$in',
    roomId: room,
    network: ChatNetwork.whatsapp,
    senderId: '@whatsapp_grace:example.org',
    senderName: 'Grace',
    timestamp: DateTime.utc(2026, 1, 15, 10),
    kind: MessageKind.text,
    isOwn: false,
    body: body,
  );

  WeftMessage ourAutoReply() => WeftMessage(
    eventId: r'$auto-0',
    roomId: room,
    network: ChatNetwork.whatsapp,
    senderId: '@ada:example.org',
    senderName: 'Ada',
    timestamp: DateTime.utc(2026, 1, 15, 10, 1),
    kind: MessageKind.text,
    isOwn: true,
    isAutoReply: true,
    body: 'I am away until Monday.',
  );

  group('the arithmetic the badge is read off', () {
    test('an own newest event reads as caught up — the trap', () {
      // Not a bug: it is what makes a chat the user replied in stop showing a
      // count of their own messages. It is also exactly why suppressing the
      // *receipt* is not enough for an auto-reply.
      expect(
        isReadLocally(
          lastEventId: r'$auto-0',
          lastEventSenderId: '@ada:example.org',
          lastEventTs: 2000,
          ownUserId: '@ada:example.org',
          readUpToEventId: null,
          receiptEventId: null,
          receiptTs: null,
        ),
        isTrue,
      );
      expect(
        roomUnreadCount(
          markedUnread: false,
          notificationCount: 3,
          readLocally: true,
        ),
        0,
        reason: 'this is the badge the auto-reply would have cleared',
      );
    });

    test('the unread flag is checked before that, so the count survives', () {
      expect(
        roomUnreadCount(
          markedUnread: true,
          notificationCount: 3,
          readLocally: true,
        ),
        3,
      );
    });

    test('a flagged room with no server count still shows something', () {
      expect(
        roomUnreadCount(
          markedUnread: true,
          notificationCount: 0,
          readLocally: true,
        ),
        1,
      );
    });

    test('an ordinary unread room is unchanged by any of this', () {
      expect(
        roomUnreadCount(
          markedUnread: false,
          notificationCount: 2,
          readLocally: false,
        ),
        2,
      );
    });
  });

  group('the service cannot mark anything read', () {
    test('the transport it is given has no way to', () {
      // Structural, and deliberately so. `AutoReplyTransport` declares one
      // method; there is no `markRead` on it to call by accident, which is why
      // the send is not a flag on `ChatRepository.send`.
      final harness = buildAutoReplyService(chat: unreadChat());
      expect(harness.transport.receipts, isEmpty);
      addTearDown(harness.incoming.close);
      addTearDown(harness.service.dispose);
    });

    test('a sent auto-reply leaves the unread count untouched', () async {
      final harness = buildAutoReplyService(
        chat: unreadChat(),
        rules: [
          const AutoReplyRule(
            id: 'r',
            name: 'Away',
            prompt: 'Say I am away.',
            enabled: true,
          ),
        ],
      );
      addTearDown(harness.incoming.close);
      addTearDown(harness.service.dispose);

      await harness.service.handleMessage(incoming());

      expect(harness.transport.sent, hasLength(1));
      expect(
        harness.transport.unread,
        isEmpty,
        reason: 'nothing in the send path may write read state',
      );
      expect(harness.transport.receipts, isEmpty);
    });
  });

  group('the surfaces built on the count', () {
    test('the inbox chat still reports its unread messages', () {
      final chat = unreadChat(last: ourAutoReply());
      expect(chat.unreadCount, 3);
      expect(unreadByNetwork([chat]), {ChatNetwork.whatsapp: 3});
    });

    test('the widget and watch snapshot still shows the chat as pending', () {
      // `weft_snapshot` is what the Android widget and the Wear companion read.
      // It builds rows off `Chat.unreadCount`, so the guarantee reaches them
      // through the same number the inbox row uses.
      final snapshot = buildSnapshot(
        chats: [unreadChat(last: ourAutoReply())],
        policy: const SnapshotPolicy(enabled: true),
        now: DateTime.utc(2026, 1, 15, 10, 2),
      );

      expect(snapshot.rows.single.unreadCount, 3);
      expect(snapshot.rows.single.unreadLabel, '3');
      expect(snapshot.totalUnread, 3);
    });

    test('the notification for the message that triggered it still stands', () {
      // The reply must not silence the buzz either. `lastReadAt` stays null
      // because no receipt was written, so a message arriving after the
      // auto-reply is still new.
      final decision = evaluateNotification(
        message: incoming(),
        chat: unreadChat(last: ourAutoReply()),
        policy: NotificationPolicy(),
        now: DateTime.utc(2026, 1, 15, 10, 2),
        lastReadAt: null,
        ownUserIds: const {'@ada:example.org'},
      );

      expect(decision.delivers, isTrue);
    });
  });

  group('the multi-device half', () {
    test('a reply from this device does not clear the badge on another', () {
      // The mechanism is MSC2867 room *account data*, which syncs — so the
      // other device sees `markedUnread` true and reaches the same answer from
      // its own copy of the room. Modelled here as the second device's inputs:
      // it has no `_readUpTo` of its own and no receipt, and the newest event
      // is ours.
      final onTheLaptop = roomUnreadCount(
        markedUnread: true,
        notificationCount: 3,
        readLocally: isReadLocally(
          lastEventId: r'$auto-0',
          lastEventSenderId: '@ada:example.org',
          lastEventTs: 2000,
          ownUserId: '@ada:example.org',
          readUpToEventId: null,
          receiptEventId: null,
          receiptTs: null,
        ),
      );

      expect(onTheLaptop, 3);
    });

    test('a local-only flag would not have survived the trip', () {
      // The counterfactual, kept because it is the reason the flag is account
      // data rather than a field on the repository: without it, the second
      // device sees only "the newest event is mine" and clears.
      final withoutTheFlag = roomUnreadCount(
        markedUnread: false,
        notificationCount: 3,
        readLocally: true,
      );

      expect(withoutTheFlag, 0);
    });

    test('reading the chat on the laptop still clears it everywhere', () {
      // The flag must not be a badge that cannot be got rid of. `markRead`
      // clears `markedUnread` and writes the receipt, and the count goes.
      expect(
        roomUnreadCount(
          markedUnread: false,
          notificationCount: 0,
          readLocally: true,
        ),
        0,
      );
    });
  });
}
