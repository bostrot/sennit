import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';

import 'package:weft/app/billing_providers.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/settings.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/settings/pro_screen.dart';
import 'package:weft/services/billing/billing_store.dart';
import 'package:weft/services/billing/entitlements.dart';

import '../support/golden_harness.dart';

/// Renders the Sennit Pro purchase screen as a store build shows it, for the
/// review screenshot App Store Connect asks for on the in-app purchase.
///
/// Written to `tooling/store/screenshots/iap_review_pro.png` at the 6.9"
/// iPhone size (1320×2868). The store is a fake that offers the lifetime
/// product at its real price.
class _OfferingStore implements BillingStore {
  @override
  Stream<List<StorePurchase>> get purchases => const Stream.empty();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<StoreOffer>> offers(Set<String> productIds) async => [
    if (productIds.contains(ProProduct.lifetime.id))
      StoreOffer(
        productId: ProProduct.lifetime.id,
        title: 'Sennit Pro',
        price: '€14.99',
      ),
  ];

  @override
  Future<bool> buy(String productId) async => true;

  @override
  Future<void> restore() async {}

  @override
  Future<void> complete(StorePurchase purchase) async {}
}

void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('iap review screenshot', (tester) async {
    const logical = Size(440, 956);
    const scale = 3.0;
    tester.view.physicalSize = logical;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    debugDisableShadows = false;
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          child: ProviderScope(
            overrides: [
              storesProvider.overrideWithValue(stores),
              chatRepositoryProvider.overrideWithValue(DemoChatRepository()),
              sennitEditionProvider.overrideWithValue(SennitEdition.store),
              storeBillingPlatformProvider.overrideWithValue(true),
              billingStoreProvider.overrideWithValue(_OfferingStore()),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: weftLocalizationsDelegates,
              supportedLocales: weftSupportedLocales,
              theme: const WeftAppearance(
                mode: WeftThemeMode.light,
              ).themeFor(Brightness.light),
              home: const ProScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: scale);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('../../tooling/store/screenshots/iap_review_pro.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    } finally {
      debugDisableShadows = true;
    }
  });
}
