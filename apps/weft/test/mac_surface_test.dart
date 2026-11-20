import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/inbox/mac_shell.dart';

import 'support/golden_harness.dart';
import 'package:weft/app/localisation.dart';

/// What changes when Sennit is a Mac window.
///
/// The claim these tests defend is that the surface is one decision, made once
/// and carried in the theme: the same shell widget, the same providers and the
/// same components produce a phone layout or a desktop one depending on nothing
/// but which theme was built. What is asserted is the *shape* — a sidebar
/// instead of a rail, a toolbar instead of a scrolling headline, no floating
/// button, system type sizes — because that shape is the whole of what "does
/// not look like a mobile app" means, and every one of those was true of the
/// window before this and wrong.
void main() {
  setUpAll(loadGoldenFonts);

  group('the theme carries the surface', () {
    test('touch is the default', () {
      final theme = WeftTheme.build();
      expect(theme.extension<WeftSurfaceTokens>()?.surface, WeftSurface.touch);
    });

    test('the desktop theme uses the system type scale', () {
      final mac = WeftTheme.build(surface: WeftSurface.mac);
      final touch = WeftTheme.build();

      expect(mac.textTheme.bodyMedium?.fontSize, 13);
      expect(mac.textTheme.labelSmall?.fontSize, 11);
      expect(mac.textTheme.titleSmall?.fontSize, 13);
      // The touch theme states no sizes at all: it takes Material's scale,
      // which is the 14/16 a phone is designed around. Naming a size there
      // would be this platform's decision leaking into the other one.
      expect(touch.textTheme.bodyMedium?.fontSize, isNull);
    });

    test('the desktop theme has no ripple', () {
      final mac = WeftTheme.build(surface: WeftSurface.mac);
      expect(mac.splashFactory, NoSplash.splashFactory);
    });

    test('the desktop theme shrinks every control', () {
      final mac = WeftTheme.build(surface: WeftSurface.mac);
      expect(mac.visualDensity.horizontal, -2);
      expect(mac.visualDensity.vertical, -2);
    });

    test('the density preference still rides on top of it', () {
      final mac = WeftTheme.build(surface: WeftSurface.mac, densityScale: 1);
      expect(mac.visualDensity.vertical, -1);
    });
  });

  group('the shell', () {
    testWidgets('is the desktop one on a Mac', (tester) async {
      await pumpWeft(tester, const InboxShell(), surface: WeftSurface.mac);

      expect(find.byType(MacInboxShell), findsOneWidget);
      expect(find.byType(MacSidebar), findsOneWidget);
    });

    testWidgets('is the phone one everywhere else', (tester) async {
      await pumpWeft(tester, const InboxShell());

      expect(find.byType(MacInboxShell), findsNothing);
      expect(find.byType(NetworkRail), findsOneWidget);
    });

    testWidgets('has no floating action button', (tester) async {
      await pumpWeft(tester, const InboxShell(), surface: WeftSurface.mac);

      expect(
        find.byType(FloatingActionButton),
        findsNothing,
        reason: 'compose lives in the toolbar; a Mac has no FAB',
      );
      expect(find.byTooltip('New conversation'), findsOneWidget);
    });

    testWidgets('the phone shell does have one', (tester) async {
      await pumpWeft(tester, const InboxShell());
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('the sidebar lists the smart folders and the networks', (
      tester,
    ) async {
      await pumpWeft(tester, const InboxShell(), surface: WeftSurface.mac);

      expect(find.text('All conversations'), findsWidgets);
      expect(find.text('Unread'), findsOneWidget);
      expect(find.text('Archived'), findsOneWidget);
      expect(find.text('Networks'), findsOneWidget);
      expect(find.text('WhatsApp'), findsWidgets);
      // The destinations the phone hides in an overflow menu are rows here.
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Messengers'), findsOneWidget);
    });

    testWidgets('selecting a conversation opens it beside the list', (
      tester,
    ) async {
      await pumpWeft(tester, const InboxShell(), surface: WeftSurface.mac);

      expect(find.text('No conversation selected'), findsOneWidget);
      await tester.tap(find.text('Anna Maven').first);
      await tester.pumpAndSettle();

      expect(find.byType(ChatView), findsOneWidget);
      expect(
        find.text('No conversation selected'),
        findsNothing,
        reason: 'the detail pane is the conversation now',
      );
    });

    testWidgets('the sidebar hides and comes back', (tester) async {
      await pumpWeft(tester, const InboxShell(), surface: WeftSurface.mac);

      await tester.tap(find.byTooltip('Hide sidebar'));
      await tester.pumpAndSettle();
      expect(find.byType(MacSidebar), findsNothing);

      await tester.tap(find.byTooltip('Show sidebar'));
      await tester.pumpAndSettle();
      expect(find.byType(MacSidebar), findsOneWidget);
    });

    testWidgets('the search field clears in the reader\'s language', (
      tester,
    ) async {
      await pumpWeft(
        tester,
        const InboxShell(),
        surface: WeftSurface.mac,
        variant: const WeftGoldenVariant(name: 'de', locale: Locale('de')),
      );

      await tester.enterText(find.byType(MacSearchField), 'Anna');
      await tester.pump();

      expect(find.byTooltip('Suche löschen'), findsOneWidget);
      expect(find.byTooltip('Clear search'), findsNothing);

      await tester.tap(find.byTooltip('Suche löschen'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byType(MacSearchField),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        isEmpty,
      );
    });
  });

  group('panels', () {
    // Directly, rather than through a screen that happens to open one: what is
    // being tested is the routing decision, and a real panel would drag half
    // the app's providers in to prove it.
    Future<void> open(
      WidgetTester tester, {
      required WeftSurface surface,
      required bool anchored,
    }) async {
      final theme = WeftTheme.build(surface: surface);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: theme,
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (anchor) => ElevatedButton(
                  onPressed: () => showWeftPanel<void>(
                    context: anchor,
                    anchorContext: anchored ? anchor : null,
                    builder: (_) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('panel body'),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('touch gets a bottom sheet', (tester) async {
      await open(tester, surface: WeftSurface.touch, anchored: true);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('panel body'), findsOneWidget);
    });

    testWidgets('a Mac gets a popover at the control that opened it', (
      tester,
    ) async {
      await open(tester, surface: WeftSurface.mac, anchored: true);

      expect(
        find.byType(BottomSheet),
        findsNothing,
        reason: 'a bottom sheet on a Mac is the loudest tell there is',
      );
      expect(find.text('panel body'), findsOneWidget);

      final button = tester.getRect(find.text('open'));
      final panel = tester.getRect(find.text('panel body'));
      expect(
        (panel.center.dx - button.center.dx).abs(),
        lessThan(40),
        reason: 'a popover points at its control',
      );
      expect(panel.top, greaterThan(button.top));
    });

    testWidgets('a Mac panel with nothing to point at drops from the top', (
      tester,
    ) async {
      await open(tester, surface: WeftSurface.mac, anchored: false);

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('panel body'), findsOneWidget);
      expect(
        tester.getRect(find.text('panel body')).top,
        lessThan(tester.getRect(find.text('open')).top),
        reason: 'a sheet comes down from the title bar, not up from the dock',
      );
    });

    testWidgets('clicking away closes a popover', (tester) async {
      await open(tester, surface: WeftSurface.mac, anchored: true);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('panel body'), findsNothing);
    });
  });

  group('the conversation row', () {
    testWidgets('is the system list row on a Mac', (tester) async {
      await pumpWeft(tester, const InboxShell(), surface: WeftSurface.mac);

      final avatar = tester.widget<WeftAvatar>(find.byType(WeftAvatar).first);
      expect(avatar.size, 32, reason: 'a 46pt avatar is a phone row');
    });

    testWidgets('keeps the phone metrics on touch', (tester) async {
      await pumpWeft(tester, const InboxShell());
      final avatar = tester.widget<WeftAvatar>(find.byType(WeftAvatar).first);
      expect(avatar.size, 46);
    });
  });

  group('the thread', () {
    testWidgets('is capped at a readable width', (tester) async {
      await pumpWeft(
        tester,
        const ChatView(chatId: 'merged:anna'),
        size: const Size(1600, 900),
        surface: WeftSurface.mac,
      );

      final list = tester.getRect(find.byType(ListView).first);
      expect(
        list.width,
        lessThanOrEqualTo(MacMetrics.readingColumn),
        reason: 'a bubble run to 1600pt cannot be read',
      );
    });

    testWidgets('runs the full width on a phone', (tester) async {
      await pumpWeft(
        tester,
        const ChatView(chatId: 'merged:anna'),
        size: const Size(430, 900),
      );

      final list = tester.getRect(find.byType(ListView).first);
      expect(list.width, 430);
    });
  });
}
