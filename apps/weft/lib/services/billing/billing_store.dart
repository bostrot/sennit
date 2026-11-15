import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// Where a store purchase stands, in the words Braid acts on.
enum StorePurchaseStatus { pending, purchased, restored, canceled, error }

/// One update from the store about one product.
@immutable
class StorePurchase {
  const StorePurchase({
    required this.productId,
    required this.status,
    this.needsCompletion = false,
    this.error,
    this.raw,
  });

  final String productId;
  final StorePurchaseStatus status;

  /// The store wants an acknowledgement. Play refunds a purchase that is not
  /// acknowledged within three days, so this must be answered even when the
  /// purchase is one Braid does not recognise.
  final bool needsCompletion;

  final String? error;

  /// The plugin's own object, handed back on [BillingStore.complete].
  final Object? raw;
}

/// A product as the store prices it for this user.
@immutable
class StoreOffer {
  const StoreOffer({
    required this.productId,
    required this.title,
    required this.price,
  });

  final String productId;
  final String title;

  /// Already formatted in the user's currency by the store.
  final String price;
}

/// The store, behind the few calls Braid makes.
///
/// An interface so the purchase flow is testable without Play or StoreKit:
/// the plugin's types need a platform channel to construct.
abstract interface class BillingStore {
  Stream<List<StorePurchase>> get purchases;
  Future<bool> isAvailable();
  Future<List<StoreOffer>> offers(Set<String> productIds);

  /// Starts the store's own purchase sheet. The outcome arrives on
  /// [purchases], never here; false means the sheet could not be opened.
  Future<bool> buy(String productId);
  Future<void> restore();
  Future<void> complete(StorePurchase purchase);
}

/// Play Billing on Android and StoreKit on iOS, through `in_app_purchase`.
class InAppPurchaseBillingStore implements BillingStore {
  InAppPurchaseBillingStore([InAppPurchase? plugin])
    : _plugin = plugin ?? InAppPurchase.instance;

  final InAppPurchase _plugin;

  /// Products from the last [offers] call. Buying needs the store's own
  /// object, not just an id.
  final Map<String, ProductDetails> _details = {};

  @override
  Stream<List<StorePurchase>> get purchases =>
      _plugin.purchaseStream.map((list) => [for (final p in list) _map(p)]);

  @override
  Future<bool> isAvailable() => _plugin.isAvailable();

  @override
  Future<List<StoreOffer>> offers(Set<String> productIds) async {
    final response = await _plugin.queryProductDetails(productIds);
    if (response.notFoundIDs.isNotEmpty) {
      debugPrint(
        'weft: billing: the store does not know ${response.notFoundIDs}',
      );
    }
    final offers = <StoreOffer>[];
    for (final d in response.productDetails) {
      _details[d.id] = d;
      offers.add(StoreOffer(productId: d.id, title: d.title, price: d.price));
    }
    return offers;
  }

  @override
  Future<bool> buy(String productId) async {
    var details = _details[productId];
    if (details == null) {
      await offers({productId});
      details = _details[productId];
    }
    if (details == null) return false;
    // Non-consumable covers both kinds: Play sells a subscription through the
    // same call, and StoreKit decides from the product itself.
    return _plugin.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: details),
    );
  }

  @override
  Future<void> restore() => _plugin.restorePurchases();

  @override
  Future<void> complete(StorePurchase purchase) async {
    final raw = purchase.raw;
    if (raw is PurchaseDetails) await _plugin.completePurchase(raw);
  }

  static StorePurchase _map(PurchaseDetails p) => StorePurchase(
    productId: p.productID,
    status: switch (p.status) {
      PurchaseStatus.pending => StorePurchaseStatus.pending,
      PurchaseStatus.purchased => StorePurchaseStatus.purchased,
      PurchaseStatus.restored => StorePurchaseStatus.restored,
      PurchaseStatus.canceled => StorePurchaseStatus.canceled,
      PurchaseStatus.error => StorePurchaseStatus.error,
    },
    needsCompletion: p.pendingCompletePurchase,
    error: p.error?.message,
    raw: p,
  );
}
