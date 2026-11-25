import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// An inbox row for a conversation with something typed and not sent.
void main() {
  final chat = Chat(
    id: 'chat:anna',
    title: 'Anna Maven',
    sources: const [
      ChatSource(roomId: '!signal:example.org', network: ChatNetwork.signal),
    ],
    lastMessage: WeftMessage(
      eventId: r'$last',
      roomId: '!signal:example.org',
      network: ChatNetwork.signal,
      senderId: '@me:example.org',
      senderName: 'Me',
      timestamp: DateTime(2026, 8, 18, 14, 32),
      kind: MessageKind.text,
      isOwn: true,
      body: 'the last thing sent',
      deliveryState: DeliveryState.read,
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    String? draft,
    bool typing = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(),
        home: Scaffold(
          body: ChatTile(
            chat: chat,
            onTap: () {},
            draft: draft,
            typing: typing,
          ),
        ),
      ),
    );
  }

  testWidgets('the draft takes the preview line, labelled', (tester) async {
    await pump(tester, draft: 'see you\nat six');
    expect(find.text('Draft: see you at six'), findsOneWidget);
    expect(find.text('the last thing sent'), findsNothing);
    // A tick next to words that have not been sent would say they were.
    expect(find.byIcon(Icons.done_all_rounded), findsNothing);
  });

  testWidgets('a blank draft is no draft', (tester) async {
    await pump(tester, draft: '  \n ');
    expect(find.text('the last thing sent'), findsOneWidget);
    expect(find.textContaining('Draft:'), findsNothing);
  });

  testWidgets('someone typing still wins', (tester) async {
    await pump(tester, draft: 'see you', typing: true);
    expect(find.text('typing…'), findsOneWidget);
    expect(find.textContaining('Draft:'), findsNothing);
  });

  testWidgets('a screen reader hears the draft too', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, draft: 'see you');
    expect(
      tester.getSemantics(find.byType(ChatTile)).label,
      contains('Draft: see you'),
    );
    semantics.dispose();
  });
}
