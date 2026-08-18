import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/sms_composer_bar.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/seeded_repository.dart';

/// The two things the composer has to say when the next message is an SMS.
///
/// Both are facts the rest of Weft's inbox lets a user stop thinking about:
/// every other network arrives over an encrypted Matrix room and costs nothing
/// per message. A composer that looked identical for SMS would be the app
/// telling a lie by omission about the first, and charging for the second
/// without saying so.
void main() {
  Future<SeededChatRepository> pumpSmsChat(
    WidgetTester tester, {
    ChatNetwork network = ChatNetwork.sms,
  }) async {
    final seeded = SeededChatRepository(
      DemoChatRepository(),
      messages: [
        seededMessage(
          eventId: 'sms:msg:11',
          roomId: 'sms:thread:7',
          network: network,
          body: 'see you at six',
          senderName: '+441234567890',
        ),
      ],
      chatId: 'sms:thread:7',
      title: '+441234567890',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(seeded)],
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: ChatView(chatId: seeded.chatId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return seeded;
  }

  testWidgets('an SMS chat says so before a character is typed', (
    tester,
  ) async {
    await pumpSmsChat(tester);

    expect(find.byType(SmsComposerBar), findsOneWidget);
    expect(find.text('Not encrypted'), findsOneWidget);
    // 160 GSM-7 characters, none of them used yet.
    expect(find.text('160 left'), findsOneWidget);
  });

  testWidgets('a bridged chat gets no such bar', (tester) async {
    await pumpSmsChat(tester, network: ChatNetwork.whatsapp);

    // The indicator is not decoration: showing it on an encrypted conversation
    // would make it meaningless on the one where it matters.
    expect(find.byType(SmsComposerBar), findsNothing);
    expect(find.text('Not encrypted'), findsNothing);
  });

  testWidgets('the count follows what is typed', (tester) async {
    await pumpSmsChat(tester);

    await tester.enterText(find.byType(TextField), 'a' * 150);
    await tester.pump();

    expect(find.text('10 left'), findsOneWidget);
  });

  testWidgets('a second segment is announced as a second message', (
    tester,
  ) async {
    await pumpSmsChat(tester);

    await tester.enterText(find.byType(TextField), 'a' * 161);
    await tester.pump();

    // Not "1 left of 320": a concatenated segment spends part of its payload
    // on the header that says which part it is, so 161 characters costs two
    // segments of 153 rather than 160 + 1.
    expect(find.text('2 messages'), findsOneWidget);
  });

  testWidgets('one pasted curly quote is shown as the reason', (tester) async {
    await pumpSmsChat(tester);

    // The single most common way a message the user thought was free becomes
    // three billable ones. The character is invisible on the keyboard, so the
    // encoding has to be named.
    await tester.enterText(find.byType(TextField), '${'a' * 100}’');
    await tester.pump();

    expect(find.text('2 messages · UCS-2'), findsOneWidget);
  });

  group('SmsComposerBar on its own', () {
    Future<void> pumpBar(WidgetTester tester, String body) => tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(),
        home: Scaffold(body: SmsComposerBar(body: body)),
      ),
    );

    testWidgets('the GSM-7 table is narrower than it looks', (tester) async {
      // `à` is in the table and `á` is not. A composer that guessed from
      // "looks Latin" would be wrong for exactly the characters that cost.
      await pumpBar(tester, 'à');
      expect(find.text('159 left'), findsOneWidget);

      await pumpBar(tester, 'á');
      expect(find.text('69 left · UCS-2'), findsOneWidget);
    });

    testWidgets('an escaped character costs two septets', (tester) async {
      await pumpBar(tester, '{');
      expect(find.text('158 left'), findsOneWidget);
    });
  });
}
