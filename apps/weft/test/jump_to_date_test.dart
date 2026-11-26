import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/jump_to_date.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/seeded_repository.dart';

/// Jump to date: the day divider opens a date picker, and the conversation
/// scrolls to the first message of the day picked — or of the next day that
/// has one.
void main() {
  final today = DateUtils.dateOnly(DateTime.now());
  DateTime daysAgo(int days, {int hour = 12}) =>
      DateTime(today.year, today.month, today.day - days, hour);

  group('firstMessageOnOrAfter', () {
    WeftMessage at(String id, DateTime when) =>
        seededMessage(eventId: id, body: id, timestamp: when);

    test('is the oldest message of the day', () {
      final messages = [
        at('late', daysAgo(3, hour: 20)),
        at('early', daysAgo(3, hour: 8)),
        at('before', daysAgo(4, hour: 23)),
        at('after', daysAgo(2, hour: 1)),
      ];
      expect(firstMessageOnOrAfter(messages, daysAgo(3))?.eventId, 'early');
    });

    test('is the next day with messages when the day has none', () {
      final messages = [at('old', daysAgo(9)), at('next', daysAgo(5))];
      expect(firstMessageOnOrAfter(messages, daysAgo(7))?.eventId, 'next');
    });

    test('is null when everything is older', () {
      expect(firstMessageOnOrAfter([at('old', daysAgo(9))], daysAgo(1)), null);
    });

    test('reachesBefore says whether the day is loaded', () {
      final messages = [at('a', daysAgo(5)), at('b', daysAgo(2))];
      expect(reachesBefore(messages, daysAgo(4)), isTrue);
      expect(reachesBefore(messages, daysAgo(5)), isFalse);
    });
  });

  group('in the conversation', () {
    late DemoChatRepository demo;

    setUp(() {
      clearMessageDocumentCache();
      demo = DemoChatRepository(uploadTick: Duration.zero);
    });
    tearDown(() => demo.dispose());

    /// Six messages a day for thirty days, except the days in [quiet].
    List<WeftMessage> history({Set<int> quiet = const {}}) => [
      for (var day = 0; day < 30; day++)
        if (!quiet.contains(day))
          for (var n = 0; n < 6; n++)
            seededMessage(
              eventId: '\$d${day}n$n',
              body: 'day $day message $n',
              isOwn: n.isOdd,
              timestamp: daysAgo(day, hour: 9 + n),
            ),
    ];

    Future<void> pumpChat(
      WidgetTester tester,
      List<WeftMessage> messages,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = SeededChatRepository(demo, messages: messages);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(brightness: Brightness.light),
            home: ChatView(chatId: repository.chatId),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Taps today's divider and types [day] into the picker's text field.
    Future<void> jumpTo(WidgetTester tester, DateTime day) async {
      await tester.tap(find.byTooltip('Jump to date').first);
      await tester.pumpAndSettle();
      expect(find.text('Jump to date'), findsWidgets);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(TextField),
        ),
        DateFormat.yMd('en_US').format(day),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    testWidgets('scrolls to the first message of the day picked', (
      tester,
    ) async {
      await pumpChat(tester, history());
      expect(find.text('day 20 message 0', findRichText: true), findsNothing);

      await jumpTo(tester, daysAgo(20));

      expect(find.text('day 20 message 0', findRichText: true), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      // The highlight fades after a few seconds.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('lands on the next day with messages, and says so', (
      tester,
    ) async {
      await pumpChat(tester, history(quiet: {12}));

      await jumpTo(tester, daysAgo(12));

      expect(find.text('day 11 message 0', findRichText: true), findsOneWidget);
      expect(
        find.text(
          'No messages that day. Showing '
          '${DateFormat.yMMMd().format(daysAgo(11))}.',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
    });
  });
}
