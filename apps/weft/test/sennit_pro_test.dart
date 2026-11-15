/// Sennit Pro: what a store build locks, what unlocks it, and what never locks.
///
/// Three layers, each pinned on its own. The model decides from an edition,
/// a platform and a purchase record; the controller turns store updates into
/// that record and acknowledges every purchase, since Play refunds one that is
/// left unacknowledged; and the gates make a locked feature go quiet even
/// when its settings are filled in, because a user who configured an endpoint
/// before Pro existed must not keep using it through the back door.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';

import 'package:weft/app/auto_reply_providers.dart';
import 'package:weft/app/billing_providers.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/mcp_service.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/search_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/settings/integrations_screen.dart';
import 'package:weft/features/settings/pro_screen.dart';
import 'package:weft/features/settings/settings_screen.dart';
import 'package:weft/services/billing/billing_store.dart';
import 'package:weft/services/billing/entitlements.dart';
import 'package:weft/services/billing/license_client.dart';

/// A licence service that knows one key, and can be switched off.
class _FakeLicenses {
  static const good = 'BRAID-ABCDE-FGHJK-LMNPQ-RSTUV';
  final asked = <String>[];
  bool online = true;
  bool revoked = false;

  LicenseClient get client => LicenseClient(
    api: Uri.parse('https://licences.example/braid/'),
    httpClient: MockClient((request) async {
      expect(request.url.path, '/braid/validate');
      final key = request.url.queryParameters['license']!;
      asked.add(key);
      if (!online) return http.Response('bad gateway', 502);
      return http.Response('{"valid": ${key == good && !revoked}}', 200);
    }),
  );
}

class _FakeStore implements BillingStore {
  final controller = StreamController<List<StorePurchase>>.broadcast();
  bool available = true;
  int restores = 0;
  final bought = <String>[];
  final completed = <StorePurchase>[];
  List<StoreOffer> catalogue = const [
    StoreOffer(
      productId: 'braid_pro_monthly',
      title: 'Monthly',
      price: '€2.99',
    ),
    StoreOffer(
      productId: 'braid_pro_lifetime',
      title: 'Lifetime',
      price: '€24.99',
    ),
  ];

  @override
  Stream<List<StorePurchase>> get purchases => controller.stream;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<StoreOffer>> offers(Set<String> productIds) async => [
    for (final o in catalogue)
      if (productIds.contains(o.productId)) o,
  ];

  @override
  Future<bool> buy(String productId) async {
    bought.add(productId);
    return true;
  }

  @override
  Future<void> restore() async => restores++;

  @override
  Future<void> complete(StorePurchase purchase) async =>
      completed.add(purchase);

  Future<void> close() => controller.close();
}

StorePurchase _purchase(
  String id, {
  StorePurchaseStatus status = StorePurchaseStatus.purchased,
  bool needsCompletion = true,
  String? error,
}) => StorePurchase(
  productId: id,
  status: status,
  needsCompletion: needsCompletion,
  error: error,
);

void main() {
  final t0 = DateTime.utc(2026, 10, 22, 12);

  group('the model', () {
    test('only an explicit store define is the store edition', () {
      expect(SennitEdition.parse('store'), SennitEdition.store);
      expect(SennitEdition.parse(' Store '), SennitEdition.store);
      expect(SennitEdition.parse(''), SennitEdition.community);
      expect(SennitEdition.parse('pro'), SennitEdition.community);
      expect(SennitEdition.parse('direct'), SennitEdition.direct);
      // Tests and source builds carry no define.
      expect(SennitEdition.current, SennitEdition.community);
    });

    test(
      'a community build or a store build without a store charges no one',
      () {
        for (final status in const [
          ProStatus(
            edition: SennitEdition.community,
            storeBillingPlatform: true,
          ),
          ProStatus(edition: SennitEdition.store, storeBillingPlatform: false),
        ]) {
          expect(status.charges, isFalse);
          for (final f in ProFeature.values) {
            expect(status.unlocks(f), isTrue, reason: f.name);
          }
        }
      },
    );

    test('a direct build charges on every platform, by licence key', () {
      for (final phone in [true, false]) {
        final status = ProStatus(
          edition: SennitEdition.direct,
          storeBillingPlatform: phone,
        );
        expect(status.charges, isTrue);
        expect(status.sellsByLicense, isTrue);
        expect(status.sellsInStore, isFalse);
        expect(status.unlocks(ProFeature.aiReplies), isFalse);
      }
    });

    test('a typed key is tidied, and anything else costs no request', () {
      expect(
        normalizeLicenseKey('  braid-abcde-fghjk-lmnpq-rstuv '),
        _FakeLicenses.good,
      );
      expect(normalizeLicenseKey('BRAID-ABCDE'), isNull);
      expect(normalizeLicenseKey('WSLM-ABCDE-FGHJK-LMNPQ-RSTUV'), isNull);
      expect(normalizeLicenseKey(''), isNull);
    });

    test('a store build on a phone locks every Pro feature until bought', () {
      const locked = ProStatus(
        edition: SennitEdition.store,
        storeBillingPlatform: true,
      );
      expect(locked.charges, isTrue);
      for (final f in ProFeature.values) {
        expect(locked.unlocks(f), isFalse, reason: f.name);
      }
      final owned = locked.withOwnership(
        ProOwnership(productId: ProProduct.lifetime.id, confirmedAt: t0),
      );
      expect(owned.unlocks(ProFeature.mcpServer), isTrue);
    });

    test(
      'a lifetime purchase never lapses; a subscription does after grace',
      () {
        final lifetime = ProOwnership(
          productId: ProProduct.lifetime.id,
          confirmedAt: t0,
        );
        final monthly = ProOwnership(
          productId: ProProduct.monthly.id,
          confirmedAt: t0,
        );
        final years = t0.add(const Duration(days: 3650));
        expect(lifetime.isActive(years), isTrue);

        final edge = t0.add(ProOwnership.subscriptionGrace);
        expect(monthly.isActive(edge), isTrue);
        expect(monthly.isActive(edge.add(const Duration(minutes: 1))), isFalse);
      },
    );

    test('lifetime beats a subscription, whichever was confirmed later', () {
      final lifetime = ProOwnership(
        productId: ProProduct.lifetime.id,
        confirmedAt: t0,
      );
      final later = ProOwnership(
        productId: ProProduct.monthly.id,
        confirmedAt: t0.add(const Duration(days: 1)),
      );
      expect(later.strongest(lifetime), lifetime);
      expect(lifetime.strongest(later), lifetime);
    });

    test('the saved record round-trips, and junk reads as nothing', () {
      final record = ProOwnership(
        productId: ProProduct.monthly.id,
        confirmedAt: t0,
      );
      expect(ProOwnership.fromJson(record.toJson()), record);
      expect(ProOwnership.fromJson(null), isNull);
      expect(
        ProOwnership.fromJson({'product': 'x', 'confirmed': '$t0'}),
        isNull,
      );
      expect(
        ProOwnership.fromJson({
          'product': ProProduct.lifetime.id,
          'confirmed': 'yesterday',
        }),
        isNull,
      );
    });
  });

  group('the controller and the gates', () {
    late WeftStores stores;
    late _FakeStore store;
    late ProviderContainer container;
    var verified = true;

    setUp(() {
      verified = true;
      stores = WeftStores.inMemory();
      store = _FakeStore();
      container = ProviderContainer(
        overrides: [
          storesProvider.overrideWithValue(stores),
          sennitEditionProvider.overrideWithValue(SennitEdition.store),
          storeBillingPlatformProvider.overrideWithValue(true),
          billingStoreProvider.overrideWithValue(store),
          purchaseVerifierProvider.overrideWithValue((_) async => verified),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await store.close();
      stores.dispose();
    });

    ProController controller() =>
        container.read(proControllerProvider.notifier);
    ProStatus status() => container.read(proControllerProvider);

    test(
      'start listens and restores, once however often it is called',
      () async {
        await controller().start();
        await controller().start();
        expect(store.restores, 1);
        expect(store.controller.hasListener, isTrue);
      },
    );

    test('a purchase unlocks, is saved and is acknowledged', () async {
      expect(status().unlocks(ProFeature.aiReplies), isFalse);
      await controller().handle([_purchase(ProProduct.lifetime.id)]);

      expect(status().unlocks(ProFeature.aiReplies), isTrue);
      expect(store.completed, hasLength(1));
      final saved = ProOwnership.fromJson(
        stores.settings.getJson(kProOwnershipSetting),
      );
      expect(saved?.productId, ProProduct.lifetime.id);

      // And a fresh launch reads it back without asking the store.
      final relaunch = ProviderContainer(
        overrides: [
          storesProvider.overrideWithValue(stores),
          sennitEditionProvider.overrideWithValue(SennitEdition.store),
          storeBillingPlatformProvider.overrideWithValue(true),
          billingStoreProvider.overrideWithValue(null),
        ],
      );
      addTearDown(relaunch.dispose);
      expect(
        relaunch.read(proControllerProvider).unlocks(ProFeature.mcpServer),
        isTrue,
      );
    });

    test('purchases arriving on the stream are handled after start', () async {
      await controller().start();
      store.controller.add([
        _purchase(ProProduct.monthly.id, status: StorePurchaseStatus.restored),
      ]);
      await pumpEventQueue();
      expect(status().owned(), isTrue);
    });

    test(
      'an unknown product unlocks nothing but is still acknowledged',
      () async {
        await controller().handle([_purchase('someone_elses_product')]);
        expect(status().owned(), isFalse);
        expect(store.completed, hasLength(1));
      },
    );

    test('a purchase the verifier rejects unlocks nothing', () async {
      verified = false;
      await controller().handle([_purchase(ProProduct.lifetime.id)]);
      expect(status().owned(), isFalse);
      expect(stores.settings.getJson(kProOwnershipSetting), isNull);
    });

    test('a later subscription does not replace a lifetime purchase', () async {
      await controller().handle([_purchase(ProProduct.lifetime.id)]);
      await controller().handle([_purchase(ProProduct.monthly.id)]);
      expect(status().ownership?.productId, ProProduct.lifetime.id);
    });

    test('pending and failed purchases are reported to the screen', () async {
      await controller().handle([
        _purchase(
          ProProduct.monthly.id,
          status: StorePurchaseStatus.pending,
          needsCompletion: false,
        ),
      ]);
      expect(container.read(proCheckoutProvider).phase, CheckoutPhase.pending);
      expect(store.completed, isEmpty);

      await controller().handle([
        _purchase(
          ProProduct.monthly.id,
          status: StorePurchaseStatus.error,
          error: 'declined',
        ),
      ]);
      final checkout = container.read(proCheckoutProvider);
      expect(checkout.phase, CheckoutPhase.failed);
      expect(checkout.error, 'declined');
      expect(status().owned(), isFalse);
    });

    test('a lapsed subscription locks and asks the store again', () async {
      stores.settings.setJson(
        kProOwnershipSetting,
        ProOwnership(
          productId: ProProduct.monthly.id,
          confirmedAt: DateTime.now().subtract(const Duration(days: 8)),
        ).toJson(),
      );
      expect(status().unlocks(ProFeature.aiReplies), isFalse);
      await pumpEventQueue();
      expect(store.restores, 1);

      // The store confirms it is still live: unlocked again.
      await controller().handle([
        _purchase(ProProduct.monthly.id, status: StorePurchaseStatus.restored),
      ]);
      expect(status().unlocks(ProFeature.aiReplies), isTrue);
    });

    test('offers come back in the order Pro lists them', () async {
      final offers = await controller().offers();
      expect(offers.map((o) => o.productId), [
        ProProduct.lifetime.id,
        ProProduct.monthly.id,
      ]);
      store.available = false;
      expect(await controller().offers(), isEmpty);
    });

    test('a configured endpoint stays unused until Pro is bought', () async {
      stores.settings
        ..setString(WeftSettings.llmBaseUrl, 'http://nas.local:11434/v1')
        ..setString(WeftSettings.llmModel, 'llama3')
        ..setString(WeftSettings.homeAssistantUrl, 'http://ha.local:8123')
        ..setBool(WeftSettings.embeddingEnabled, value: true)
        ..setString(WeftSettings.embeddingBaseUrl, 'http://nas.local:11434/v1');
      stores.homeAssistantToken = 'token';

      expect(container.read(autoReplyEndpointProvider), isNull);
      expect(container.read(homeAssistantProvider), isNull);
      expect(container.read(embeddingProviderProvider), isNull);
      expect(
        await container.read(transcriptionProviderProvider.future),
        isNull,
      );
      await expectLater(
        container.read(mcpServiceProvider).start(),
        throwsA(isA<ProFeatureLocked>()),
      );

      await controller().handle([_purchase(ProProduct.lifetime.id)]);

      expect(container.read(autoReplyEndpointProvider), isNotNull);
      expect(container.read(homeAssistantProvider), isNotNull);
      expect(container.read(embeddingProviderProvider), isNotNull);
    });
  });

  group('a licence key in a direct build', () {
    late WeftStores stores;
    late _FakeLicenses licences;
    late ProviderContainer container;

    setUp(() {
      stores = WeftStores.inMemory();
      licences = _FakeLicenses();
      container = ProviderContainer(
        overrides: [
          storesProvider.overrideWithValue(stores),
          sennitEditionProvider.overrideWithValue(SennitEdition.direct),
          storeBillingPlatformProvider.overrideWithValue(false),
          licenseClientProvider.overrideWithValue(licences.client),
        ],
      );
    });

    tearDown(() {
      container.dispose();
      stores.dispose();
    });

    ProController controller() =>
        container.read(proControllerProvider.notifier);
    ProStatus status() => container.read(proControllerProvider);

    void backdateCheck() => stores.settings.setJson(kProLicenseSetting, {
      'key': _FakeLicenses.good,
      'checked': DateTime.now()
          .subtract(ProController.licenseRecheck * 2)
          .toUtc()
          .toIso8601String(),
    });

    test('a good key unlocks for good and is remembered', () async {
      expect(status().unlocks(ProFeature.mcpServer), isFalse);
      expect(
        await controller().activateLicense(' braid-abcde-fghjk-lmnpq-rstuv'),
        LicenseVerdict.valid,
      );
      expect(status().unlocks(ProFeature.mcpServer), isTrue);
      expect(controller().licenseKey, _FakeLicenses.good);
      expect(
        ProOwnership.fromJson(
          stores.settings.getJson(kProOwnershipSetting),
        )?.product,
        ProProduct.lifetime,
      );
    });

    test('an unknown key and a mistyped one unlock nothing', () async {
      expect(
        await controller().activateLicense('BRAID-22222-22222-22222-22222'),
        LicenseVerdict.invalid,
      );
      expect(
        await controller().activateLicense('nonsense'),
        LicenseVerdict.invalid,
      );
      expect(licences.asked, ['BRAID-22222-22222-22222-22222']);
      expect(status().owned(), isFalse);
    });

    test('an unreachable service is not a verdict on the key', () async {
      licences.online = false;
      expect(
        await controller().activateLicense(_FakeLicenses.good),
        LicenseVerdict.unreachable,
      );
      expect(status().owned(), isFalse);
    });

    test('a fresh licence is not asked about again on launch', () async {
      await controller().activateLicense(_FakeLicenses.good);
      licences.asked.clear();
      await controller().start();
      await pumpEventQueue();
      expect(licences.asked, isEmpty);
    });

    test(
      'a stale licence is re-checked, and survives the server being down',
      () async {
        await controller().activateLicense(_FakeLicenses.good);
        backdateCheck();
        licences.online = false;
        await controller().start();
        await pumpEventQueue();
        expect(licences.asked.last, _FakeLicenses.good);
        expect(status().owned(), isTrue);
      },
    );

    test('a licence the service has deactivated locks again', () async {
      await controller().activateLicense(_FakeLicenses.good);
      backdateCheck();
      licences.revoked = true;
      await controller().start();
      await pumpEventQueue();
      expect(status().owned(), isFalse);
      expect(controller().licenseKey, isNull);
      expect(stores.settings.getJson(kProOwnershipSetting), isNull);
    });
  });

  group('the screens', () {
    final en = lookupAppL10n(const Locale('en'));

    Future<_FakeStore> pump(
      WidgetTester tester,
      Widget home, {
      SennitEdition edition = SennitEdition.store,
    }) async {
      tester.view.physicalSize = const Size(600, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      final store = _FakeStore();
      addTearDown(store.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesProvider.overrideWithValue(stores),
            // The settings screen asks which networks exist.
            chatRepositoryProvider.overrideWithValue(DemoChatRepository()),
            sennitEditionProvider.overrideWithValue(edition),
            storeBillingPlatformProvider.overrideWithValue(true),
            billingStoreProvider.overrideWithValue(store),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: home,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return store;
    }

    testWidgets('a locked row leads to the Pro screen, not its own', (
      tester,
    ) async {
      await pump(tester, const SettingsScreen());

      // AI, integrations and MCP each carry the badge.
      expect(find.byType(ProBadge), findsNWidgets(3));
      expect(find.text(en.proTitle), findsOneWidget);

      await tester.tap(find.text(en.settingsMcpTitle));
      await tester.pumpAndSettle();
      expect(find.byType(ProScreen), findsOneWidget);
    });

    testWidgets('a community build shows no badge and no Pro row', (
      tester,
    ) async {
      await pump(
        tester,
        const SettingsScreen(),
        edition: SennitEdition.community,
      );
      expect(find.byType(ProBadge), findsNothing);
      expect(find.text(en.proTitle), findsNothing);
    });

    testWidgets('the Pro screen shows store prices and buys the one tapped', (
      tester,
    ) async {
      final store = await pump(tester, const ProScreen());

      expect(find.text(en.proBuyLifetime('€24.99')), findsOneWidget);
      expect(find.text(en.proBuyMonthly('€2.99')), findsOneWidget);
      expect(find.text(en.proSubscriptionNote), findsOneWidget);

      await tester.tap(find.text(en.proBuyLifetime('€24.99')));
      await tester.pumpAndSettle();
      expect(store.bought, [ProProduct.lifetime.id]);

      await tester.tap(find.text(en.proRestore));
      await tester.pumpAndSettle();
      expect(store.restores, greaterThan(0));
    });

    testWidgets('a direct build asks for a licence key instead of the store', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      final licences = _FakeLicenses();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesProvider.overrideWithValue(stores),
            sennitEditionProvider.overrideWithValue(SennitEdition.direct),
            storeBillingPlatformProvider.overrideWithValue(false),
            licenseClientProvider.overrideWithValue(licences.client),
            licenseCheckoutProvider.overrideWithValue(
              Uri.parse('https://shop.example/braid'),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: const ProScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(en.proBuyDirect), findsOneWidget);
      expect(find.text(en.proRestore), findsNothing);

      await tester.enterText(
        find.byType(TextField),
        'BRAID-22222-22222-22222-22222',
      );
      await tester.tap(find.text(en.proLicenseActivate));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text(en.proLicenseInvalid), findsOneWidget);

      await tester.enterText(find.byType(TextField), _FakeLicenses.good);
      await tester.tap(find.text(en.proLicenseActivate));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text(en.proOwnedLifetime), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });
}
