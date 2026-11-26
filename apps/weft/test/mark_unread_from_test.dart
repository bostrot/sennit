import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/data/matrix_chat_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/chat/unread_from.dart';
import 'package:weft_design/weft_design.dart';

import 'support/seeded_repository.dart';

/// Mark unread from here: the conversation goes back to unread with the
/// chosen message as the first one not yet read.
void main() {
  group('unreadFromPlan', () {
    final history = [
      seededMessage(eventId: r'$1', body: 'one', minutesAgo: 50),
      seededMessage(eventId: r'$2', body: 'two', minutesAgo: 40),
      seededMessage(eventId: r'$3', body: 'three', minutesAgo: 30),
      seededMessage(eventId: r'$4', body: 'mine', minutesAgo: 20, isOwn: true),
      seededMessage(eventId: r'$5', body: 'five', minutesAgo: 10),
      seededMessage(
        eventId: r'$other',
        body: 'other leg',
        minutesAgo: 35,
        roomId: '!other:example.org',
      ),
    ];

    test('the marker goes before the message, the badge counts from it', () {
      final plan = unreadFromPlan(history, history[2]);
      expect(plan.before, r'$2');
      // three and five; the user's own message is not unread.
      expect(plan.count, 2);
    });

    test('reads only the message\'s own room', () {
      final plan = unreadFromPlan(history, history[2]);
      expect(plan.before, isNot(r'$other'));
    });

    test('the oldest loaded message has nothing before it', () {
      final plan = unreadFromPlan(history, history[0]);
      expect(plan.before, isNull);
      expect(plan.count, 4);
    });
  });

  group('roomUnreadCount', () {
    test('a room marked unread from a message shows that many', () {
      expect(
        roomUnreadCount(
          markedUnread: true,
          markedCount: 7,
          notificationCount: 0,
          readLocally: true,
        ),
        7,
      );
    });

    test('without the flag the count is ignored', () {
      expect(
        roomUnreadCount(
          markedUnread: false,
          markedCount: 7,
          notificationCount: 0,
          readLocally: true,
        ),
        0,
      );
    });
  });

  testWidgets('the action marks the chat unread from the pressed message', (
    tester,
  ) async {
    clearMessageDocumentCache();
    final demo = DemoChatRepository(uploadTick: Duration.zero);
    addTearDown(demo.dispose);
    final repository = SeededChatRepository(
      demo,
      messages: [
        seededMessage(eventId: r'$a', body: 'first', minutesAgo: 30),
        seededMessage(eventId: r'$b', body: 'second', minutesAgo: 20),
        seededMessage(eventId: r'$c', body: 'third', minutesAgo: 10),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: ChatView(chatId: repository.chatId),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.text('second', findRichText: true).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    final action = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text('Mark unread from here'),
    );
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    await tester.tap(action);
    await tester.pumpAndSettle();

    final call = repository.calls.singleWhere(
      (c) => c.method == 'markUnreadFrom',
    );
    expect(call.eventId, r'$b');
    expect(call.body, r'$a');
    expect(call.key, '2');
    expect(find.text('Marked unread from this message.'), findsOneWidget);
  });

  testWidgets('is not offered on the user\'s own message', (tester) async {
    clearMessageDocumentCache();
    final demo = DemoChatRepository(uploadTick: Duration.zero);
    addTearDown(demo.dispose);
    final repository = SeededChatRepository(
      demo,
      messages: [seededMessage(eventId: r'$a', body: 'mine', isOwn: true)],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: ChatView(chatId: repository.chatId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(
      find.text('mine', findRichText: true).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('Mark unread from here'), findsNothing);
  });
}
