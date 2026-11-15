import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/inbox/requests_screen.dart';
import 'package:weft/features/merge/merge_screen.dart';

import '../support/golden_harness.dart' show loadGoldenFonts;

/// The three action rows the Phase 10 walkthrough found clipped at 2.0× text.
///
/// Every one of them was a `Row` of buttons sized by their labels, on a phone,
/// under a text scaler that doubles those labels. A `Row` that does not fit does
/// not wrap and does not scroll — it paints its overflow stripes and clips, and
/// what got clipped in all three cases was the *last* child: `Accept` on a
/// message request, `Merge` on a suggestion, and the emoji-picker button on the
/// message actions sheet. In each case the destructive or reversible options
/// stayed reachable and the affirmative one did not, which is the worst way
/// round for it to fail.
///
/// ## Why an overflow needs its own test at all
///
/// A `RenderFlex overflowed` is *reported*, never thrown: it goes to
/// `FlutterError.onError`, paints stripes, and lets the frame finish. So the
/// three screens below passed every widget test in this repository while
/// shipping an untappable button, and the golden suites did not catch it either
/// — `a11y_*_large_text` pins the inbox, a chat, search, settings, the surfaces
/// screen and the auto-reply list, and none of those three rows is in any of
/// them.
///
/// The route walk catches it now (`integration_test/route_walk_test.dart`, pass
/// `phone-xl`), which is where it *was* caught, and that run needs a device and
/// four minutes. These are the same assertions in the widget tester, so the
/// regression is a red test in the ordinary suite rather than in a walk somebody
/// has to remember to run on a phone.
///
/// **Real fonts, always** — `test/a11y/text_scale_test.dart` explains why: the
/// placeholder face `flutter_test` otherwise substitutes makes every width a
/// measurement of the placeholder rather than of the text.
void main() {
  setUpAll(loadGoldenFonts);

  final l10n = lookupAppL10n(const Locale('en'));

  /// A phone, at the scale where all three of these broke.
  const phone = Size(412, 915);
  const scale = 2.0;

  /// Pumps [home] as a phone at [textScale], with the demo fixtures behind it.
  Future<void> pumpPhone(
    WidgetTester tester,
    Widget home, {
    double textScale = scale,
  }) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(
            DemoChatRepository(uploadTick: Duration.zero),
          ),
        ],
        child: MaterialApp(
          theme: WeftTheme.build(brightness: Brightness.light),
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          // In the app's `builder` rather than over the `MaterialApp`:
          // `MediaQuery.fromView` rebuilds its data from the view and would drop
          // anything set above it. Same placement the golden harness uses.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Fails if any box in the tree reported an overflow, naming the widest.
  ///
  /// `RenderFlex` writes the amount it could not fit into its own paint, and
  /// `debugNeedsPaint` will not tell you about it — the only handle from a test
  /// is the error the framework reported, so this reads the recorded errors
  /// rather than the tree.
  void expectNoOverflow(WidgetTester tester, String what) {
    final errors = <String>[];
    for (var error = tester.takeException(); error != null;) {
      errors.add('$error');
      error = tester.takeException();
    }
    final overflows = errors
        .where((error) => error.contains('overflowed'))
        .toList();
    expect(
      overflows,
      isEmpty,
      reason: '$what overflows at ${scale}x:\n${overflows.join('\n')}',
    );
    // Anything else that was thrown is still a failure, just not this one's.
    expect(errors, isEmpty, reason: '$what threw at ${scale}x');
  }

  /// Whether [finder]'s box is wholly inside the window.
  ///
  /// The point of every case below: a control that is *built* is not a control
  /// that can be pressed. A clipped `FilledButton` is in the tree, answers
  /// `findsOneWidget`, and has its centre off the right edge of the screen where
  /// no tap will ever land.
  void expectOnScreen(WidgetTester tester, Finder finder, String what) {
    expect(finder, findsWidgets, reason: '$what is not on screen at all');
    final rect = tester.getRect(finder.first);
    expect(
      rect.right,
      lessThanOrEqualTo(phone.width),
      reason:
          '$what is clipped at ${scale}x: it ends at ${rect.right} in a '
          '${phone.width}pt window',
    );
    expect(
      rect.left,
      greaterThanOrEqualTo(0.0),
      reason: '$what starts off screen',
    );
  }

  testWidgets('a message request keeps Accept on screen at 2.0x', (
    tester,
  ) async {
    await pumpPhone(tester, const RequestsScreen());
    expectNoOverflow(tester, 'the message requests card');
    expectOnScreen(
      tester,
      find.text(l10n.requestAccept),
      'the request card\'s Accept button',
    );
    // The other three with it: a wrap that pushed one of them off the *bottom*
    // of the card would satisfy the assertion above and still lose a control.
    for (final label in [
      l10n.requestRead,
      l10n.requestBlock,
      l10n.requestDecline,
    ]) {
      expectOnScreen(tester, find.text(label), 'the request card\'s "$label"');
    }
  });

  testWidgets('a merge suggestion keeps Merge on screen at 2.0x', (
    tester,
  ) async {
    await pumpPhone(tester, const MergeScreen());
    expectNoOverflow(tester, 'the merge suggestion card');
    expectOnScreen(
      tester,
      find.text(l10n.mergeAccept),
      'the suggestion card\'s Merge button',
    );
    expectOnScreen(
      tester,
      find.text(l10n.mergeNotSamePerson),
      'the suggestion card\'s reject button',
    );
  });

  // ------------------------------------------------- and 1.0x, which is the
  // half of this that the first fix broke.
  //
  // A `Row` fills the width it is given; a `Wrap` sizes to its widest run. So
  // swapping one for the other keeps every child on screen and quietly moves
  // the group: `WrapAlignment.end` and `spaceBetween` distribute *free* space,
  // and a shrink-wrapped `Wrap` has none. The re-walk photographed the merge
  // card's *Merge* button 85 points in from the trailing margin it used to sit
  // against — no overflow, no failing test, just wrong. These pin the ordinary
  // scale so the large-text fix cannot pay for itself out of it.

  testWidgets('a merge suggestion still ends at the card edge at 1.0x', (
    tester,
  ) async {
    await pumpPhone(tester, const MergeScreen(), textScale: 1.0);

    final button = tester.getRect(
      find
          .ancestor(
            of: find.text(l10n.mergeAccept),
            matching: find.byType(FilledButton),
          )
          .first,
    );
    final card = tester.getRect(find.byType(Card).first);
    expect(
      card.right - button.right,
      // 16 with the fix — the card's own [WeftSpace.md] padding and no more.
      // 85 without it. [WeftSpace.huge] sits between the two by a wide margin
      // in both directions, so this fails on the regression and not on a
      // button-padding change.
      lessThan(WeftSpace.huge),
      reason:
          'Merge sits ${card.right - button.right} points in from the card '
          'edge — the Wrap shrank to its widest run and had no free space to '
          'push it to the end',
    );
  });

  testWidgets('a message request still splits its two groups at 1.0x', (
    tester,
  ) async {
    await pumpPhone(tester, const RequestsScreen(), textScale: 1.0);

    final read = tester.getRect(
      find
          .ancestor(
            of: find.text(l10n.requestRead),
            matching: find.byType(TextButton),
          )
          .first,
    );
    final accept = tester.getRect(
      find
          .ancestor(
            of: find.text(l10n.requestAccept),
            matching: find.byType(FilledButton),
          )
          .first,
    );
    final card = tester.getRect(find.byType(Card).first);

    expect(
      card.right - accept.right,
      lessThan(WeftSpace.huge),
      reason: 'the verdict group is not against the card\'s trailing edge',
    );
    expect(
      accept.left - read.right,
      // ~199 with the fix; the two groups collapse to a few points without it.
      greaterThan(WeftSpace.huge),
      reason:
          'Read and the verdicts are ${accept.left - read.right} points apart '
          '— they have collapsed into one group',
    );
  });

  testWidgets('the message actions sheet keeps every reaction reachable at '
      '2.0x', (tester) async {
    await pumpPhone(tester, const InboxShell());
    await tester.tap(find.byType(ChatTile).first);
    await tester.pumpAndSettle();

    // One that can actually be pressed: the topmost bubble built is usually
    // half under the conversation's bar, and a press at its centre lands on
    // the bar instead.
    await tester.longPress(find.byType(WeftFocusable).hitTestable().last);
    await tester.pumpAndSettle();

    expectNoOverflow(tester, 'the message actions sheet');
    expectOnScreen(
      tester,
      find.byTooltip(l10n.messageActionMoreReactions),
      'the sheet\'s emoji picker button',
    );
  });
}
