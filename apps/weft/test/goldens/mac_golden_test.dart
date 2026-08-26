import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/chat/chat_view.dart';
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

  Future<void> shell(
    WidgetTester tester, {
    required WeftThemeMode mode,
  }) => pumpWeft(
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
