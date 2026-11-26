import 'dart:convert';

import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_remote/weft_remote.dart';

/// Through a JSON string, as the wire carries it.
Map<String, Object?> _wire(Map<String, Object?> j) =>
    jsonDecode(jsonEncode(j)) as Map<String, Object?>;

void main() {
  final at = DateTime.utc(2026, 11, 24, 18, 30);

  final message = WeftMessage(
    eventId: r'$e1',
    roomId: '!r:x',
    network: ChatNetwork.signal,
    senderId: '@a:x',
    senderName: 'Anna',
    timestamp: at,
    kind: MessageKind.poll,
    isOwn: true,
    body: 'Lunch?',
    formattedBody: '<b>Lunch?</b>',
    replyToEventId: r'$e0',
    replyPreview: const ReplyPreview(
      eventId: r'$e0',
      roomId: '!r:x',
      senderId: '@b:x',
      senderName: 'Ben',
      kind: MessageKind.text,
      body: 'Hi',
    ),
    threadRootId: r'$root',
    reactions: [
      ReactionTally(
        key: '👍',
        senderIds: const ['@b:x'],
        firstReactedAt: at,
        byLocalUser: true,
        localEventId: r'$r1',
      ),
    ],
    editHistory: [EditRecord(eventId: r'$ed', body: 'Lunch', timestamp: at)],
    editedAt: at,
    deliveryState: DeliveryState.read,
    poll: const PollData(
      question: 'Lunch?',
      options: [PollOption(id: 'y', text: 'Yes')],
      votes: {'y': 2},
      voters: {
        'y': ['Anna', 'Ben'],
      },
      voterCount: 2,
      ownVotes: {'y'},
      undisclosed: true,
      ended: true,
    ),
    calendarInvite: CalendarInvite(
      uid: 'u1',
      title: 'Lunch',
      start: at,
      responses: [
        const CalendarResponse(
          senderId: '@b:x',
          senderName: 'Ben',
          reply: CalendarReply.accepted,
        ),
      ],
    ),
    mediaWidth: 640,
    mediaHeight: 480,
    encrypted: true,
  );

  test('a message survives the wire field for field', () {
    final back = DomainCodec.messageFrom(_wire(DomainCodec.message(message)));
    expect(DomainCodec.message(back), DomainCodec.message(message));
    expect(back.timestamp.isAtSameMomentAs(at), isTrue);
    expect(back.reactions.single.byLocalUser, isTrue);
    expect(back.poll!.ownVotes, {'y'});
    expect(back.poll!.voters['y'], ['Anna', 'Ben']);
    expect(back.poll!.undisclosed, isTrue);
    expect(back.calendarInvite!.responses.single.reply, CalendarReply.accepted);
  });

  test('a merged chat keeps its legs and its chosen network', () {
    final chat = Chat(
      id: 'contact:1',
      title: 'Anna',
      sources: const [
        ChatSource(roomId: '!a:x', network: ChatNetwork.whatsapp, unread: 2),
        ChatSource(roomId: '!b:x', network: ChatNetwork.signal, muted: true),
      ],
      lastMessage: message,
      unreadCount: 2,
      pinned: true,
      request: ChatRequestState.pending,
      preferredSendNetwork: ChatNetwork.signal,
    );
    final back = DomainCodec.chatFrom(_wire(DomainCodec.chat(chat)));
    expect(DomainCodec.chat(back), DomainCodec.chat(chat));
    expect(back.sendNetwork, ChatNetwork.signal);
  });

  test('a 64-bit avatar hash crosses intact', () {
    const handle = NetworkHandle(
      id: '@a:x',
      network: ChatNetwork.whatsapp,
      remoteId: '+491',
      matrixUserId: '@a:x',
      avatarDHash: 0x0F0F0F0F0F0F0F0F,
    );
    final json = _wire(DomainCodec.handle(handle));
    expect(json['dhash'], isA<String>());
    expect(DomainCodec.handleFrom(json).avatarDHash, 0x0F0F0F0F0F0F0F0F);
  });

  test('unknown enum values and missing optionals do not throw', () {
    final back = DomainCodec.messageFrom({
      'id': r'$x',
      'room': '!r:x',
      'net': 'some-future-network',
      'sender': '@a:x',
      'senderName': 'A',
      'ts': 0,
      'kind': 'hologram',
    });
    expect(back.network, ChatNetwork.unknown);
    expect(back.kind, MessageKind.text);
  });

  test('what a room can do with polls survives the wire', () {
    const support = PollSupport(
      maxOptions: 12,
      optionMaxLength: 100,
      undisclosed: false,
      canEnd: false,
      uniqueOptions: true,
    );
    final back = DomainCodec.pollSupportFrom(
      _wire(DomainCodec.pollSupport(support)),
    );
    expect(back.available, isTrue);
    expect(back.maxOptions, 12);
    expect(back.optionMaxLength, 100);
    expect(back.undisclosed, isFalse);
    expect(back.canEnd, isFalse);
    expect(back.uniqueOptions, isTrue);
    expect(
      DomainCodec.pollSupportFrom(
        _wire(DomainCodec.pollSupport(const PollSupport.unavailable())),
      ).available,
      isFalse,
    );
  });
}
