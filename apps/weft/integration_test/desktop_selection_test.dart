import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kDoubleTapMinTime, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/localisation.dart';
import 'package:weft/app/session_providers.dart' show kDemoMode;
import 'package:weft/app/shortcuts.dart';
import 'package:weft/features/chat/message_actions_sheet.dart';
import 'package:weft/main.dart';

/// Desktop text selection, against a real clipboard.
///
///   cd apps/weft
///   flutter test integration_test/desktop_selection_test.dart -d macos \
///     --dart-define=WEFT_DEMO=true
///
/// ## Why this exists next to the widget tests
///
/// `test/desktop_selection_test.dart` pins the wiring — which handler answers
/// ⌘C, what a `SelectedContent` projects to, that a phone gets none of it. It
/// cannot pin the two things that only a machine has. The first is the
/// **clipboard**: under the test binding `Clipboard.setData` is a mocked method
/// call, and "the right string reached a mock" is not "the right string is on
/// the pasteboard". The second is the **rasteriser**: word and paragraph
/// selection are resolved from laid-out glyph runs, and the fonts a real Mac
/// lays out are not the ones `loadGoldenFonts` registers.
///
/// So this walks the same ground with `Clipboard.getData` as the assertion.
///
/// ## What it deliberately does not cover
///
/// The ⌘C **accelerator** itself. On macOS `PlatformMenuBar` hands the chord to
/// AppKit, which invokes the Edit menu item directly — the key event never
/// reaches Flutter's focus tree, so no test binding can press it. What the menu
/// item then *does* is `WeftMenuBar._copy`, and that is asked here the way the
/// menu asks it: an intent looked up from `primaryFocus`. The remaining gap is
/// "does AppKit deliver the chord", which is `PlatformMenuBar`'s business and
/// is not something this phase changed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    expect(
      kDemoMode,
      isTrue,
      reason:
          'Run with --dart-define=WEFT_DEMO=true: without it the app reaches '
          'for a homeserver and never leaves the splash.',
    );
    expect(
      weftHasPointer,
      isTrue,
      reason:
          'This file is about what a pointer does. Give it a desktop target: '
          '-d macos, -d windows or -d linux.',
    );
  });

  final l10n = lookupAppL10n(const Locale('en'));

  testWidgets(
    'a pointer selects, copies and still reaches every verb',
    (tester) async {
      tester.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      tester.view.viewInsets = FakeViewPadding.zero;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const ProviderScope(child: WeftApp()));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      // Into a conversation. On the Mac window the thread is a pane, so this is
      // a tap on a row rather than a route push.
      await tester.tap(find.byType(ChatTile).first, warnIfMissed: false);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.byType(SelectionArea), findsOneWidget);

      /// The painted bubbles, newest first — see `route_walk_test.dart` for why
      /// the focusable rather than the row.
      Finder bubbles() => find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_MessageBubble',
        ),
        matching: find.byType(WeftFocusable),
      );

      Rect rectOf(Element element) {
        final box = element.renderObject! as RenderBox;
        return box.localToGlobal(Offset.zero) & box.size;
      }

      final rows = bubbles().evaluate().toList();
      expect(
        rows.length,
        greaterThanOrEqualTo(2),
        reason: 'the demo thread is meant to have a conversation in it',
      );

      Future<void> setClipboard(String text) =>
          Clipboard.setData(ClipboardData(text: text));
      Future<String?> clipboard() async =>
          (await Clipboard.getData(Clipboard.kTextPlain))?.text;

      // The whole file's assertion is the pasteboard, so a target without one
      // has nothing to say rather than something to fail. A headless Linux
      // runner with no clipboard owner on the X display is that target; a
      // skip, named, is the honest report of it.
      await setClipboard('pasteboard probe');
      if (await clipboard() != 'pasteboard probe') {
        markTestSkipped(
          'this target has no working pasteboard — nothing here is decidable',
        );
        return;
      }

      /// ⌘C, dispatched the way the Edit menu dispatches it.
      Future<void> copy() async {
        final context = primaryFocus?.context;
        expect(context, isNotNull, reason: 'nothing had focus to copy from');
        const intent = CopyMessageIntent();
        final action = Actions.maybeFind<CopyMessageIntent>(
          context!,
          intent: intent,
        );
        expect(action, isNotNull, reason: 'Edit ▸ Copy found no handler');
        if (action!.isEnabled(intent)) {
          Actions.of(context).invokeAction(action, intent, context);
        }
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
      }

      // ------------------------------------------------- drag across two bubbles
      final from = rectOf(rows[1]).topLeft + const Offset(14, 14);
      final to = rectOf(rows.first).bottomRight - const Offset(14, 14);

      Future<void> drag(Offset start, Offset end) async {
        final mouse = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        for (var step = 1; step <= 6; step++) {
          await mouse.moveTo(Offset.lerp(start, end, step / 6)!);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await mouse.up();
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
      }

      // One more frame first. The bubbles join the selection area on the frame
      // after they are laid out, and a settled thread schedules none — a drag
      // into it finds nothing to select. A real mouse gets that frame from its
      // own hover; this test used to get it from an agenda chip resolving.
      await tester.pump();
      await setClipboard('nothing yet');
      await drag(from, to);
      await copy();

      final dragged = await clipboard();
      expect(dragged, isNotNull);
      expect(
        dragged,
        isNot('nothing yet'),
        reason: 'the drag put nothing on the real pasteboard',
      );
      expect(
        dragged!.contains('\n'),
        isTrue,
        reason: 'two messages copy as two lines — see WeftSelectionLine',
      );
      expect(
        RegExp(r'^\d{1,2}:\d{2}$', multiLine: true).hasMatch(dragged),
        isFalse,
        reason:
            'the clock under a bubble is chrome, not something anybody wrote',
      );

      // ------------------------------------------------------------ right-click
      //
      // On the selection: Sennit's own menu, with every verb it had before, and
      // no second menu from the framework underneath it.
      await tester.tapAt(
        rectOf(rows.first).center,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.byType(PopupMenuItem<MessageActionChoice>), findsWidgets);
      expect(find.text(l10n.messageActionReply), findsOneWidget);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);

      // Copy from it takes the selection rather than the bubble it was raised on.
      await setClipboard('nothing yet');
      await tester.tap(find.text(l10n.messageActionCopy));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(await clipboard(), dragged);

      // ------------------------------------------------ double- and triple-click
      //
      // Resolved from real glyph runs, which is the half of this a widget test
      // cannot reach. Assertions are about *shape* rather than about a
      // particular word: the demo fixtures are free to change their sentences.
      final word = rectOf(rows.first).centerLeft + const Offset(24, 0);
      await tester.tapAt(word, pointer: 11, kind: PointerDeviceKind.mouse);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(word, pointer: 11, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      await copy();
      final doubled = (await clipboard())!.trim();
      expect(doubled, isNotEmpty);
      expect(
        doubled,
        isNot(contains(' ')),
        reason: 'a double-click is one word',
      );

      await tester.tapAt(word, pointer: 12, kind: PointerDeviceKind.mouse);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(word, pointer: 12, kind: PointerDeviceKind.mouse);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(word, pointer: 12, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      await copy();
      final tripled = (await clipboard())!.trim();
      expect(
        tripled.length,
        greaterThanOrEqualTo(doubled.length),
        reason: 'a triple-click takes at least the word a double-click did',
      );

      // ------------------------------------------------- ⌘V into the composer
      //
      // The path Phase 06 landed, asked here because a selection now sits
      // between the key and the field.
      await setClipboard('pasted from the pasteboard');
      final field = find.byType(TextField).last;
      // `showKeyboard` rather than a tap, because what has to be true is that
      // the *caret* is in the composer: `_paste` resolves `primaryFocus` and
      // hands the text case straight back to the framework, so a tap that
      // landed without focusing would paste into nothing at all.
      await tester.showKeyboard(field);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(
        primaryFocus?.debugLabel,
        contains('composer'),
        reason: 'the caret has to be in the composer for ⌘V to mean anything',
      );
      await tester.runAsync(() async {
        Actions.invoke(tester.element(field), const PasteIntoComposerIntent());
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(
        find.text('pasted from the pasteboard'),
        findsOneWidget,
        reason: '⌘V into the composer is not regressed by the selection area',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
