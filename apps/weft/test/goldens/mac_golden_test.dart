import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';

import '../support/golden_harness.dart';

/// The desktop window, pinned.
///
/// The phone's goldens cannot catch a regression here: they are captured on
/// the touch surface, and every value this layout depends on — the type scale,
/// the control density, the row metrics, the pane widths — is a different one.
/// A change that quietly put a 46pt avatar or a 16pt title back in the window
/// would pass the whole rest of the suite.
///
/// Captured at 1280×800, the smallest display Braid is expected to ship
/// against, because that is where the three panes are tightest.
void main() {
  setUpAll(loadGoldenFonts);

  const window = Size(1280, 800);

  Future<void> shell(WidgetTester tester, {required WeftThemeMode mode}) =>
      pumpWeft(
        tester,
        const InboxShell(),
        size: window,
        mode: mode,
        surface: WeftSurface.mac,
      );

  group('macOS goldens', () {
    testWidgets('the window, dark', (tester) async {
      await shell(tester, mode: WeftThemeMode.dark);
      await expectLater(
        find.byType(InboxShell),
        matchesGoldenFile('mac_window_dark.png'),
      );
    });

    testWidgets('the window, light', (tester) async {
      await shell(tester, mode: WeftThemeMode.light);
      await expectLater(
        find.byType(InboxShell),
        matchesGoldenFile('mac_window_light.png'),
      );
    });

    testWidgets('a conversation, dark', (tester) async {
      await pumpWeft(
        tester,
        const ChatView(chatId: 'merged:anna'),
        size: window,
        surface: WeftSurface.mac,
      );
      await expectLater(
        find.byType(ChatView),
        matchesGoldenFile('mac_chat_dark.png'),
      );
    });

    testWidgets('a conversation, light', (tester) async {
      await pumpWeft(
        tester,
        const ChatView(chatId: 'merged:anna'),
        size: window,
        mode: WeftThemeMode.light,
        surface: WeftSurface.mac,
      );
      await expectLater(
        find.byType(ChatView),
        matchesGoldenFile('mac_chat_light.png'),
      );
    });

    // A live selection across two bubbles, which is the one state on this
    // screen that nothing else can hold anyone to.
    //
    // The selection highlight is painted by the framework in
    // `ColorScheme.primary` and lands on two different fills — the own
    // bubble's primary tint and the peer bubble's neutral one — so "is the
    // selected text still readable" has two answers per theme and four in
    // total. That is precisely the kind of thing a picture catches and an
    // assertion does not.
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      testWidgets('a selection across two messages, $suffix', (tester) async {
        await pumpWeft(
          tester,
          const ChatView(chatId: 'merged:anna'),
          size: window,
          mode: mode,
          surface: WeftSurface.mac,
        );

        // Two bubbles' worth, dragged the way a reader drags: from inside the
        // older message to inside the newer one.
        final bodies = find.byType(RichTextView);
        final from = tester.getTopLeft(bodies.at(1)) + const Offset(2, 6);
        final to = tester.getBottomRight(bodies.first) - const Offset(2, 6);
        final mouse = await tester.startGesture(
          from,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        for (var i = 1; i <= 4; i++) {
          await mouse.moveTo(Offset.lerp(from, to, i / 4)!);
          await tester.pump();
        }
        await mouse.up();
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(ChatView),
          matchesGoldenFile('mac_chat_selection_$suffix.png'),
        );
      });
    }

    // The glass has an opaque fallback, and it is the one case where a
    // translucent bar could put unreadable text over a photograph. Pinning it
    // is what stops the fallback from silently rotting.
    testWidgets('high contrast drops the translucency', (tester) async {
      await pumpWeft(
        tester,
        const InboxShell(),
        size: window,
        surface: WeftSurface.mac,
        variant: const WeftGoldenVariant(
          name: 'high_contrast',
          highContrast: true,
        ),
      );
      await expectLater(
        find.byType(InboxShell),
        matchesGoldenFile('mac_window_high_contrast.png'),
      );
    });
  });
}
