/// Searching the settings screen.
///
/// Three claims: every typed word has to appear somewhere in a row's title,
/// description or the screens above it; a row from a screen further down is
/// found and opens that screen; and a switch on the settings screen itself is
/// found as the switch, so it can be flipped from the result.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/notifications_screen.dart';
import 'package:weft/features/settings/settings_screen.dart';
import 'package:weft/features/settings/settings_search.dart';

import 'support/golden_harness.dart';

void main() {
  final en = lookupAppL10n(const Locale('en'));
  const tall = Size(500, 2400);

  group('matching', () {
    const quiet = SettingsSearchEntry(
      title: 'Quiet hours',
      subtitle: 'A time of day that recurs',
      trail: ['Notifications'],
    );
    const previews = SettingsSearchEntry(
      title: 'Link previews',
      subtitle: 'Cards under links',
    );

    test('every word must appear, in any order and case', () {
      expect(quiet.matches('QUIET'), isTrue);
      expect(previews.matches('previews link'), isTrue);
      expect(previews.matches('link sound'), isFalse);
    });

    test('description and trail count', () {
      expect(quiet.matches('recurs'), isTrue);
      expect(quiet.matches('notifications quiet'), isTrue);
    });

    test('title hits come before description hits', () {
      const describes = SettingsSearchEntry(
        title: 'Reply reminders',
        subtitle: 'Held during quiet hours',
      );
      final hits = searchSettings([describes, quiet], 'quiet');
      expect(hits.map((e) => e.title), ['Quiet hours', 'Reply reminders']);
    });

    test('an empty query finds nothing', () {
      expect(searchSettings([quiet, previews], '  '), isEmpty);
    });
  });

  group('settings screen', () {
    Future<void> pump(WidgetTester tester) => pumpWeft(
      tester,
      const SettingsScreen(),
      size: tall,
      stores: WeftStores.inMemory(),
    );

    Future<void> type(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(SettingsSearchField), query);
      await tester.pumpAndSettle();
    }

    testWidgets('finds a row on a deeper screen and opens it', (tester) async {
      await pump(tester);
      expect(find.text(en.notificationsQuietHoursTitle), findsNothing);

      await type(tester, en.notificationsQuietHoursTitle.toLowerCase());
      expect(find.text(en.notificationsQuietHoursTitle), findsOneWidget);
      // The sections are gone while a search is showing.
      expect(find.text(en.settingsSectionChats), findsNothing);

      await tester.tap(find.text(en.notificationsQuietHoursTitle));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsScreen), findsOneWidget);
    });

    testWidgets('a switch on the screen is found as the switch', (
      tester,
    ) async {
      await pump(tester);
      await type(tester, en.settingsReadReceiptsTitle);

      final toggle = find.widgetWithText(
        SwitchListTile,
        en.settingsReadReceiptsTitle,
      );
      expect(toggle, findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    });

    testWidgets('says so when nothing matches, and clears back', (
      tester,
    ) async {
      await pump(tester);
      await type(tester, 'zzzz no such setting');
      expect(find.text(en.settingsSearchNoResults), findsOneWidget);

      await tester.tap(find.byTooltip(en.settingsSearchClear));
      await tester.pumpAndSettle();
      expect(find.text(en.settingsSearchNoResults), findsNothing);
      expect(find.text(en.settingsSectionChats), findsOneWidget);
    });
  });
}
