import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// An inbox row whose newest activity is a reaction, and a merged row.
void main() {
  final message = WeftMessage(
    eventId: r'$photo',
    roomId: '!wa:example.org',
    network: ChatNetwork.whatsapp,
    senderId: '@me:example.org',
    senderName: 'Me',
    timestamp: DateTime(2026, 11, 20, 10),
    kind: MessageKind.text,
    isOwn: true,
    body: 'see you at six',
    deliveryState: DeliveryState.read,
  );

  WeftMessage reaction({required bool own, String body = 'see you at six'}) =>
      WeftMessage(
        eventId: r'$reaction',
        roomId: '!wa:example.org',
        network: ChatNetwork.whatsapp,
        senderId: own ? '@me:example.org' : '@whatsapp_1:example.org',
        senderName: own ? 'Me' : 'Anna',
        timestamp: DateTime(2026, 11, 20, 12),
        kind: MessageKind.text,
        isOwn: own,
        reactionKey: '👍',
        body: body,
      );

  Chat chat({WeftMessage? lastReaction, bool merged = false}) => Chat(
    id: merged ? 'merged:anna' : '!wa:example.org',
    title: 'Anna',
    sources: [
      const ChatSource(
        roomId: '!wa:example.org',
        network: ChatNetwork.whatsapp,
      ),
      if (merged)
        const ChatSource(
          roomId: '!signal:example.org',
          network: ChatNetwork.signal,
        ),
    ],
    lastMessage: message,
    lastReaction: lastReaction,
  );

  Future<void> pump(WidgetTester tester, Chat chat) => tester.pumpWidget(
    MaterialApp(
      theme: WeftTheme.build(),
      home: Scaffold(
        body: ChatTile(chat: chat, onTap: () {}),
      ),
    ),
  );

  testWidgets('their reaction is the preview, with what it was put on', (
    tester,
  ) async {
    await pump(tester, chat(lastReaction: reaction(own: false)));
    expect(find.text('Reacted 👍 to “see you at six”'), findsOneWidget);
    // The ticks belong to the message, and the message is not on the line.
    expect(find.byIcon(Icons.done_all_rounded), findsNothing);
    expect(find.byIcon(Icons.reply_rounded), findsNothing);
  });

  testWidgets('my reaction says so', (tester) async {
    await pump(tester, chat(lastReaction: reaction(own: true)));
    expect(find.text('You reacted 👍 to “see you at six”'), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsNothing);
  });

  testWidgets('a reaction to a message not at hand names the emoji alone', (
    tester,
  ) async {
    await pump(tester, chat(lastReaction: reaction(own: false, body: '')));
    expect(find.text('Reacted 👍'), findsOneWidget);
  });

  testWidgets('an older reaction leaves the message on the line', (
    tester,
  ) async {
    final older = WeftMessage(
      eventId: r'$old',
      roomId: '!wa:example.org',
      network: ChatNetwork.whatsapp,
      senderId: '@whatsapp_1:example.org',
      senderName: 'Anna',
      timestamp: DateTime(2026, 11, 20, 9),
      kind: MessageKind.text,
      isOwn: false,
      reactionKey: '👍',
    );
    await pump(tester, chat(lastReaction: older));
    expect(find.text('see you at six'), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
  });

  testWidgets('a merged row carries no "Merged" pill', (tester) async {
    await pump(tester, chat(merged: true));
    expect(find.text('Merged'), findsNothing);
    expect(find.byIcon(Icons.merge_rounded), findsNothing);
    // Still said to a screen reader, with the networks named.
    expect(
      find.bySemanticsLabel(RegExp('merged across 2 networks')),
      findsOneWidget,
    );
  });
}
