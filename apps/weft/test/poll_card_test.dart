import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/chat/poll_card.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

void main() {
  const options = [
    PollOption(id: 'a', text: 'Pizza'),
    PollOption(id: 'b', text: 'Sushi'),
    PollOption(id: 'c', text: 'Salad'),
  ];

  PollData poll({
    Map<String, int> votes = const {'a': 2, 'b': 1},
    Map<String, List<String>> voters = const {
      'a': ['Ann', 'Bob'],
      'b': ['Cat'],
    },
    Set<String> mine = const {},
    bool ended = false,
    bool undisclosed = false,
    int maxSelections = 1,
  }) => PollData(
    question: 'Lunch where?',
    options: options,
    votes: votes,
    voters: voters,
    voterCount: voters.values.expand((v) => v).toSet().length,
    ownVotes: mine,
    ended: ended,
    undisclosed: undisclosed,
    maxSelections: maxSelections,
  );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: weftLocalizationsDelegates,
        supportedLocales: weftSupportedLocales,
        theme: WeftTheme.build(),
        home: Scaffold(
          body: Center(child: SizedBox(width: 320, child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('PollCard', () {
    testWidgets('shows the question, the answers and the counts', (
      tester,
    ) async {
      await pump(tester, PollCard(poll: poll(), own: false));

      expect(find.text('Lunch where?'), findsOneWidget);
      for (final option in options) {
        expect(find.text(option.text), findsOneWidget);
      }
      expect(find.text('2'), findsOneWidget);
      // People, not selections.
      expect(find.text('3 votes'), findsOneWidget);
      expect(find.text('View votes'), findsOneWidget);
    });

    testWidgets('a tap sends the new selection', (tester) async {
      Set<String>? sent;
      await pump(
        tester,
        PollCard(
          poll: poll(mine: {'a'}),
          own: false,
          onVote: (answers) => sent = answers,
        ),
      );

      await tester.tap(find.text('Sushi'));
      expect(sent, {'b'});

      // Tapping the current answer of a single-choice poll changes nothing.
      sent = null;
      await tester.tap(find.text('Pizza'));
      expect(sent, isNull);
    });

    testWidgets('multiple choice toggles, up to the limit', (tester) async {
      Set<String>? sent;
      await pump(
        tester,
        PollCard(
          poll: poll(mine: {'a'}, maxSelections: 2),
          own: false,
          onVote: (answers) => sent = answers,
        ),
      );
      expect(find.text('Choose up to 2'), findsOneWidget);

      await tester.tap(find.text('Sushi'));
      expect(sent, {'a', 'b'});
      await tester.tap(find.text('Pizza'));
      expect(sent, <String>{});
    });

    testWidgets('an undisclosed poll hides the tally until it ends', (
      tester,
    ) async {
      await pump(
        tester,
        PollCard(poll: poll(undisclosed: true, mine: {'a'}), own: false),
      );
      expect(find.text('Results show when the poll ends'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      expect(find.text('View votes'), findsNothing);

      await pump(
        tester,
        PollCard(poll: poll(undisclosed: true, ended: true), own: false),
      );
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Final result · 3 votes'), findsOneWidget);
    });

    testWidgets('a closed poll ignores taps', (tester) async {
      var taps = 0;
      await pump(
        tester,
        PollCard(poll: poll(ended: true), own: false, onVote: (_) => taps++),
      );
      await tester.tap(find.text('Salad'));
      expect(taps, 0);
    });

    testWidgets('the creator can end it', (tester) async {
      var ended = 0;
      await pump(
        tester,
        PollCard(poll: poll(), own: true, onEnd: () => ended++),
      );
      await tester.tap(find.text('End poll'));
      expect(ended, 1);

      await pump(tester, PollCard(poll: poll(), own: true));
      expect(find.text('End poll'), findsNothing);
    });

    testWidgets('lists who voted for what', (tester) async {
      await pump(tester, PollCard(poll: poll(), own: false));
      await tester.tap(find.text('View votes'));
      await tester.pumpAndSettle();

      expect(find.text('Ann, Bob'), findsOneWidget);
      expect(find.text('Cat'), findsOneWidget);
      expect(find.text('No votes yet'), findsOneWidget);
    });

    testWidgets('right to left in Arabic, bars growing from the right', (
      tester,
    ) async {
      await pump(
        tester,
        PollCard(poll: poll(), own: false),
        locale: const Locale('ar'),
      );
      expect(tester.takeException(), isNull);

      final row = find.widgetWithText(PollOptionRow, 'Pizza');
      final bar = find.descendant(
        of: row,
        matching: find.byType(FractionallySizedBox),
      );
      final rowBox = tester.getRect(row);
      final barBox = tester.getRect(
        find.descendant(of: bar, matching: find.byType(DecoratedBox)).first,
      );
      expect(barBox.right, moreOrLessEquals(rowBox.right));
      expect(barBox.width, lessThan(rowBox.width));
      // The check sits at the start, which is the right.
      final check = tester.getCenter(
        find.descendant(of: row, matching: find.byType(Icon)),
      );
      expect(check.dx, greaterThan(rowBox.center.dx));
    });
  });

  group('PollComposerDialog', () {
    Future<PollDraft?> open(
      WidgetTester tester, {
      PollSupport support = const PollSupport(),
      Locale locale = const Locale('en'),
      required Future<void> Function() fill,
    }) async {
      PollDraft? result;
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<PollDraft>(
                context: context,
                builder: (_) => PollComposerDialog(support: support),
              );
            },
            child: const Text('open'),
          ),
        ),
        locale: locale,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await fill();
      return result;
    }

    Finder field(String label) => find.widgetWithText(TextField, label);

    testWidgets('pops the question, answers and kind', (tester) async {
      final draft = await open(
        tester,
        fill: () async {
          await tester.enterText(field('Question'), ' Lunch where? ');
          await tester.enterText(field('Option 1'), 'Pizza');
          await tester.enterText(field('Option 2'), 'Sushi');
          await tester.tap(find.text('Add option'));
          await tester.pumpAndSettle();
          await tester.enterText(field('Option 3'), 'Salad');
          await tester.tap(find.text('Allow multiple answers'));
          await tester.tap(find.text('Hide results until the poll ends'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Create poll'));
          await tester.pumpAndSettle();
        },
      );

      expect(draft, isNotNull);
      expect(draft!.question, 'Lunch where?');
      expect(draft.options, ['Pizza', 'Sushi', 'Salad']);
      expect(draft.multipleChoice, isTrue);
      expect(draft.undisclosed, isTrue);
    });

    testWidgets('stops adding answers at the network\'s limit', (tester) async {
      await open(
        tester,
        support: const PollSupport(maxOptions: 3, undisclosed: false),
        fill: () async {
          await tester.tap(find.text('Add option'));
          await tester.pumpAndSettle();
        },
      );
      expect(field('Option 3'), findsOneWidget);
      expect(find.text('Add option'), findsNothing);
      // WhatsApp and friends have no hidden results: no switch to offer.
      expect(find.text('Hide results until the poll ends'), findsNothing);
    });

    testWidgets('offers twenty answers where nothing limits it', (
      tester,
    ) async {
      await open(
        tester,
        fill: () async {
          for (var i = 0; i < 25; i++) {
            final add = find.text('Add option');
            if (add.evaluate().isEmpty) break;
            await tester.ensureVisible(add);
            await tester.tap(add);
            await tester.pumpAndSettle();
          }
        },
      );
      expect(find.byType(TextField), findsNWidgets(21));
    });

    testWidgets('refuses two answers with the same text', (tester) async {
      final draft = await open(
        tester,
        fill: () async {
          await tester.enterText(field('Question'), 'Lunch?');
          await tester.enterText(field('Option 1'), 'Pizza');
          await tester.enterText(field('Option 2'), 'pizza');
          await tester.tap(find.text('Create poll'));
          await tester.pumpAndSettle();
        },
      );
      expect(draft, isNull);
      expect(find.text('Each option needs different text.'), findsOneWidget);
    });

    testWidgets('a multiple-choice-only network locks the switch on', (
      tester,
    ) async {
      final draft = await open(
        tester,
        support: const PollSupport(multipleChoiceOnly: true),
        fill: () async {
          await tester.enterText(field('Question'), 'Lunch?');
          await tester.enterText(field('Option 1'), 'Pizza');
          await tester.enterText(field('Option 2'), 'Sushi');
          await tester.tap(find.text('Allow multiple answers'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Create poll'));
          await tester.pumpAndSettle();
        },
      );
      expect(draft!.multipleChoice, isTrue);
    });

    testWidgets('lays out in Arabic without overflow', (tester) async {
      await open(
        tester,
        locale: const Locale('ar'),
        fill: () async {
          await tester.tap(find.text('إضافة خيار'));
          await tester.pumpAndSettle();
        },
      );
      expect(tester.takeException(), isNull);
      expect(find.text('السماح بعدة إجابات'), findsOneWidget);
    });
  });
}
