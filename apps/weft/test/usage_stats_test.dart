import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/app/usage_stats_providers.dart';
import 'package:weft/features/settings/settings_screen.dart';
import 'package:weft/features/settings/settings_search.dart';
import 'package:weft/features/settings/usage_stats_consent.dart';
import 'package:weft/services/analytics/usage_stats.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart' show ChatNetwork;
import 'package:weft_store/weft_store.dart' show WeftSettings;

import 'support/golden_harness.dart';

/// Anonymous usage statistics.
///
/// What has to hold: nothing leaves the device until the user said yes, and
/// the moment they take it back nothing more does; the question comes once;
/// the switch in Settings is the same answer and survives a restart; and no
/// screen name can carry a chat.
void main() {
  final en = lookupAppL10n(const Locale('en'));

  late WeftStores stores;
  late List<({String name, String page, Map<String, String> props})> sent;
  setUp(() {
    stores = WeftStores.inMemory();
    sent = [];
  });
  tearDown(() => stores.dispose());

  Future<void> record({
    required String name,
    required String page,
    required Map<String, String> props,
  }) async => sent.add((name: name, page: page, props: props));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        storesProvider.overrideWithValue(stores),
        usageSenderProvider.overrideWithValue(record),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('sending', () {
    test('nothing is sent while the setting is off, its default', () {
      final stats = container().read(usageStatsProvider);
      stats
        ..screen('/settings')
        ..bridgeConnected(ChatNetwork.whatsapp)
        ..aiUsed(AiUsage.translate)
        ..deviceSyncOn()
        ..proPurchased(ProPurchaseSource.store);
      expect(sent, isEmpty);
    });

    test('switching it off stops the very next event', () {
      final c = container();
      final stats = c.read(usageStatsProvider);
      stores.settings.setBool(WeftSettings.usageStats, value: true);
      c.read(settingsRevisionProvider.notifier).bump();
      stats.bridgeConnected(ChatNetwork.signal);
      expect(sent, hasLength(1));

      stores.settings.setBool(WeftSettings.usageStats, value: false);
      c.read(settingsRevisionProvider.notifier).bump();
      stats.aiUsed(AiUsage.quickMessage);
      expect(sent, hasLength(1));
    });

    test('events carry fixed values, the version and the platform', () {
      final c = container();
      stores.settings.setBool(WeftSettings.usageStats, value: true);
      c.read(settingsRevisionProvider.notifier).bump();
      c.read(usageStatsProvider)
        ..bridgeConnected(ChatNetwork.messenger)
        ..aiUsed(AiUsage.transcribe)
        ..screen('/chat');

      expect(sent[0].name, 'Bridge connected');
      expect(sent[0].props['network'], 'facebook');
      expect(sent[0].props.keys, containsAll(['app_version', 'platform']));
      expect(sent[1].name, 'AI used');
      expect(sent[1].props['feature'], 'transcribe');
      expect(sent[2].name, 'pageview');
      expect(sent[2].page, '/chat');
    });
  });

  group('screen names', () {
    testWidgets('named after the page widget, never the route name', (
      tester,
    ) async {
      final pages = <String>[];
      final stats = UsageStats(
        allowed: () => true,
        send: ({required name, required page, required props}) async =>
            pages.add(page),
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [UsageStatsObserver(() => stats)],
          home: const SizedBox(),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            // The chat route's name carries the room; it must not leak.
            settings: const RouteSettings(name: '/chat/!room:example.org'),
            builder: (_) => const _PersonDetailsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(pages, ['/', '/person-details']);
    });
  });

  group('consent', () {
    Future<void> pumpAsk(WidgetTester tester, List<bool> shown) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => shown.add(
                  await askUsageStatsOnce(
                    context,
                    stores.settings,
                    onChanged: () {},
                  ),
                ),
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('asked once; allowing turns the setting on', (tester) async {
      final shown = <bool>[];
      await pumpAsk(tester, shown);
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();

      expect(find.byType(UsageStatsConsentDialog), findsOneWidget);
      expect(find.text(en.usageStatsConsentAllow), findsOneWidget);
      expect(find.text(en.usageStatsConsentDecline), findsOneWidget);
      await tester.tap(find.text(en.usageStatsConsentAllow));
      await tester.pumpAndSettle();
      expect(stores.settings.getBool(WeftSettings.usageStats), isTrue);

      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      expect(find.byType(UsageStatsConsentDialog), findsNothing);
      expect(shown, [true, false]);
    });

    testWidgets('declining or dismissing leaves it off', (tester) async {
      final shown = <bool>[];
      await pumpAsk(tester, shown);
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.usageStatsConsentDecline));
      await tester.pumpAndSettle();

      expect(stores.settings.getBool(WeftSettings.usageStats), isFalse);
      expect(stores.settings.getBool(WeftSettings.usageStatsAsked), isTrue);
    });

    testWidgets('both answers carry the same weight', (tester) async {
      final shown = <bool>[];
      await pumpAsk(tester, shown);
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();

      final allow = tester.getSize(
        find.widgetWithText(FilledButton, en.usageStatsConsentAllow),
      );
      final decline = tester.getSize(
        find.widgetWithText(FilledButton, en.usageStatsConsentDecline),
      );
      expect(allow, decline);
    });
  });

  group('settings switch', () {
    testWidgets('is off by default, found by search, and persists', (
      tester,
    ) async {
      await pumpWeft(
        tester,
        const SettingsScreen(),
        size: const Size(500, 2400),
        stores: stores,
      );
      await tester.enterText(
        find.byType(SettingsSearchField),
        en.settingsUsageStatsTitle,
      );
      await tester.pumpAndSettle();

      final toggle = find.widgetWithText(
        SwitchListTile,
        en.settingsUsageStatsTitle,
      );
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(stores.settings.getBool(WeftSettings.usageStats), isTrue);
      // Answered here, so the first-start question never comes.
      expect(stores.settings.getBool(WeftSettings.usageStatsAsked), isTrue);
    });
  });
}

class _PersonDetailsScreen extends StatelessWidget {
  const _PersonDetailsScreen();

  @override
  Widget build(BuildContext context) => const Scaffold();
}
