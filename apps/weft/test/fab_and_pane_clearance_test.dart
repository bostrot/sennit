import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/inbox/mac_shell.dart';
import 'package:weft/features/merge/merge_screen.dart';

import 'support/golden_harness.dart';

/// Two ways a pane can eat a control, both found by the Phase 10 walkthrough.
///
/// Neither is an overflow, so neither paints stripes and neither fails anything.
/// They are the quieter failure: a widget that is laid out correctly, inside a
/// box that is the right size, in a place nobody can reach it.
///
/// **A floating button is not free.** `Scaffold` floats a FAB *over* the body,
/// 16 points from the bottom edge, and a 56pt button therefore covers the last
/// 72 points of whatever scrolls underneath. A list that ends with its own
/// padding and no more leaves its final row under that button for ever — there
/// is no further to scroll. On the merge screen every row carries an *Unmerge*
/// button, so the last contact in the list simply could not be unmerged.
///
/// **A fixed pane is not free either.** The Mac shell's sidebar and list are
/// fixed widths and the conversation is `Expanded`, so the thread pays for
/// every point the other two take. At the 720pt minimum window
/// `macos/Runner/MainFlutterWindow.swift` allows, it was paying 528 of them and
/// keeping 192.
void main() {
  setUpAll(loadGoldenFonts);

  group('a list under a floating action button', () {
    /// The bottom of the viewport a FAB makes unusable.
    ///
    /// Read off the button that is actually on screen rather than assumed, so a
    /// Material change to the FAB's size fails this instead of silently making
    /// the clearance too small again.
    double fabIntrusion(WidgetTester tester, Size window) {
      final fab = tester.getRect(find.byType(FloatingActionButton).first);
      return window.height - fab.top;
    }

    /// Scrolls the list [row] is in to its very end.
    ///
    /// The list *containing the row*, rather than `find.byType(Scrollable)
    /// .first`, which is the mistake this helper exists to stop repeating: the
    /// inbox's filter chips are a horizontally scrolling row and they come
    /// first in the tree, so jumping "the first scrollable" to its maximum
    /// scrolls the chips sideways and leaves the conversations exactly where
    /// they were — while the test reads as though it scrolled to the bottom.
    Future<void> scrollToEnd(WidgetTester tester, Finder row) async {
      final list = find.ancestor(of: row, matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(list.first).position;
      // A list that does not scroll cannot put anything under the FAB, so an
      // assertion about its last row would pass whatever the padding was. That
      // is not a subtle failure mode — it is *the* failure mode for this test,
      // and the first version of the merge case below had it: at 1.0× the
      // fixtures are shorter than the window, so the row cleared the button by
      // hundreds of points with no bottom padding at all.
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason:
            'nothing to scroll — this case proves nothing about the FAB. Give '
            'it more content, a smaller window or a larger text scale.',
      );
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
    }

    testWidgets('the merge screen can scroll its last row clear', (
      tester,
    ) async {
      const window = Size(412, 915);
      // At 2.0×, which is where the walk photographed the FAB sitting on top of
      // the last *Unmerge* button. It is also the only scale at which this
      // screen's fixtures are taller than a phone — at 1.0× the list does not
      // scroll, so there is no "last row against the bottom" to ask about.
      await pumpWeft(
        tester,
        const MergeScreen(),
        size: window,
        variant: const WeftGoldenVariant(name: 'large_text', textScale: 2.0),
      );

      final unmerge = find.text('Unmerge');
      expect(
        unmerge,
        findsWidgets,
        reason: 'the demo fixtures carry at least one merged contact',
      );
      // To the very end, which is the only place the question is asked: a row
      // in the middle of a scroll is *behind* the FAB and that is fine, because
      // one flick moves it.
      await scrollToEnd(tester, unmerge.first);
      final last = tester.getRect(unmerge.last);
      expect(
        last.bottom,
        lessThanOrEqualTo(window.height - fabIntrusion(tester, window)),
        reason:
            'the last Unmerge button is under the FAB with nowhere left to '
            'scroll: it ends at ${last.bottom} and the FAB starts at '
            '${window.height - fabIntrusion(tester, window)}',
      );
    });

    testWidgets('the inbox clears its compose button in both layouts', (
      tester,
    ) async {
      // Both, and this is the assertion that says why. The one-pane layout
      // hands the button to `Scaffold`; the two-pane one positions it into the
      // inbox pane's own `Stack` at the same inset (`inbox_shell.dart:234`) —
      // so the second is not in the `floatingActionButton` slot, is easy to
      // miss, and covers the last conversation just as completely. The first
      // attempt at this fix reserved the clearance only when narrow.
      for (final window in [const Size(412, 915), const Size(1400, 900)]) {
        await pumpWeft(tester, const InboxShell(), size: window);
        expect(
          find.byType(FloatingActionButton),
          findsOneWidget,
          reason: 'a $window inbox composes from a floating button',
        );

        await scrollToEnd(tester, find.byType(ChatTile).first);

        final fab = tester.getRect(find.byType(FloatingActionButton).first);
        final last = tester.getRect(find.byType(ChatTile).last);
        expect(
          last.bottom,
          lessThanOrEqualTo(fab.top),
          reason:
              'at $window the last conversation ends at ${last.bottom}, under '
              'a compose button that starts at ${fab.top}, with nowhere left '
              'to scroll',
        );
      }
    });
  });

  group('the Mac window at its minimum size', () {
    /// The smallest window `MainFlutterWindow.swift` will allow, and one
    /// comfortable one to prove the squeeze does nothing when it need not.
    const minimum = 720.0;
    const roomy = 1400.0;

    /// What the thread is left with, given what the other two panes took.
    double detail(double available, (double, double) panes) =>
        available - panes.$1 - panes.$2;

    test('the thread keeps its minimum at the narrowest window', () {
      final panes = macPaneWidths(
        available: minimum,
        sidebar: MacMetrics.sidebarWidth,
        list: MacMetrics.listWidth,
      );

      expect(
        detail(minimum, panes),
        greaterThanOrEqualTo(MacMetrics.detailMinWidth),
        reason:
            'at the 720pt minimum window the thread was left 192pt — less '
            'than the conversation list beside it is allowed to shrink to',
      );
      // The sidebar pays first, and neither pane is pushed below its own floor.
      expect(panes.$1, greaterThanOrEqualTo(MacMetrics.sidebarMinWidth));
      expect(panes.$2, greaterThanOrEqualTo(MacMetrics.listMinWidth));
      expect(
        panes.$1,
        lessThan(MacMetrics.sidebarWidth),
        reason: 'the sidebar is the pane that gives way first',
      );
    });

    test('a hidden sidebar puts the whole squeeze on the list', () {
      final panes = macPaneWidths(
        available: minimum,
        sidebar: 0,
        list: MacMetrics.listMaxWidth,
      );

      expect(panes.$1, 0);
      expect(
        detail(minimum, panes),
        greaterThanOrEqualTo(MacMetrics.detailMinWidth),
      );
    });

    test('the dragged widths are untouched when there is room', () {
      expect(
        macPaneWidths(
          available: roomy,
          sidebar: MacMetrics.sidebarWidth,
          list: MacMetrics.listWidth,
        ),
        (MacMetrics.sidebarWidth, MacMetrics.listWidth),
      );
    });

    testWidgets('the window actually draws the squeezed sidebar', (
      tester,
    ) async {
      await pumpWeft(
        tester,
        const InboxShell(),
        size: const Size(minimum, 480),
        surface: WeftSurface.mac,
      );

      expect(
        tester.getSize(find.byType(MacSidebar).first).width,
        lessThan(MacMetrics.sidebarWidth),
        reason: 'the shell computed a squeeze and then ignored it',
      );
    });

    testWidgets('does not squeeze the conversation list', (tester) async {
      // The sidebar alone covers the shortfall at 720, and that is the point of
      // `detailMinWidth` being 240 rather than the 300 the arithmetic allows:
      // the list's own toolbar does not fit at `listMinWidth` — a focused
      // search field puts it 36 points over — so a target that drove the list
      // there would trade one visible bug for another. MW-09 in the
      // walkthrough; reachable by dragging the splitter, not by resizing.
      await pumpWeft(
        tester,
        const InboxShell(),
        size: const Size(minimum, 480),
        surface: WeftSurface.mac,
      );

      expect(
        macPaneWidths(
          available: minimum,
          sidebar: MacMetrics.sidebarWidth,
          list: MacMetrics.listWidth,
        ).$2,
        MacMetrics.listWidth,
      );
    });

    testWidgets('and leaves it alone in a roomy one', (tester) async {
      await pumpWeft(
        tester,
        const InboxShell(),
        size: const Size(roomy, 900),
        surface: WeftSurface.mac,
      );

      expect(
        tester.getSize(find.byType(MacSidebar).first).width,
        MacMetrics.sidebarWidth,
      );
    });
  });
}
