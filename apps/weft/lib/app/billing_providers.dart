import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/analytics/usage_stats.dart' show ProPurchaseSource;
import '../services/billing/billing_store.dart';
import '../services/billing/entitlements.dart';
import '../services/billing/license_client.dart';
import 'stores.dart';
import 'usage_stats_providers.dart';

/// Where the last confirmed Pro purchase is kept, so a launch with no network
/// still knows what was bought.
const kProOwnershipSetting = 'billing.pro_ownership';

/// The licence key a direct build was unlocked with, and when the licence
/// service last confirmed it.
const kProLicenseSetting = 'billing.pro_license';

/// The build's edition. A provider so tests can be the store build.
final sennitEditionProvider = Provider<SennitEdition>(
  (_) => SennitEdition.current,
);

/// Whether this platform takes payment through a store: Play on Android, the
/// App Store on iOS.
final storeBillingPlatformProvider = Provider<bool>(
  (_) =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS),
);

/// The store, or null in a build that does not charge.
///
/// Decided from the edition and the platform themselves, not from
/// [proControllerProvider]'s state. The controller reads this provider to
/// reach the store, so watching the controller here made each depend on the
/// other: a debug build threw `CircularDependencyError` from
/// `ProController.start` the moment the session came up, on every launch.
/// The answer is the same one — it is how [ProStatus.charges] is defined.
final billingStoreProvider = Provider<BillingStore?>((ref) {
  final charges =
      ref.watch(sennitEditionProvider) == SennitEdition.store &&
      ref.watch(storeBillingPlatformProvider);
  return charges ? InAppPurchaseBillingStore() : null;
});

/// The licence service, or null in a build that is not unlocked by a key.
final licenseClientProvider = Provider<LicenseClient?>(
  (ref) => ref.watch(sennitEditionProvider) == SennitEdition.direct
      ? LicenseClient()
      : null,
);

/// The web page a direct build sends people to to buy a licence, or null.
final licenseCheckoutProvider = Provider<Uri?>(
  (_) => LicenseEndpoints.checkout.isEmpty
      ? null
      : Uri.tryParse(LicenseEndpoints.checkout),
);

/// Decides whether a store purchase is genuine before it unlocks anything.
///
/// Trusts the store's own answer for now. This is the seam for server-side
/// receipt checks — needed before subscriptions are sold on iOS, where a
/// restore can replay transactions of a subscription that has since lapsed.
typedef PurchaseVerifier = Future<bool> Function(StorePurchase purchase);

final purchaseVerifierProvider = Provider<PurchaseVerifier>(
  (_) =>
      (_) async => true,
);

/// What the Pro screen shows while a purchase is under way.
enum CheckoutPhase { idle, pending, failed }

@immutable
class CheckoutState {
  const CheckoutState(this.phase, {this.error});

  static const idle = CheckoutState(CheckoutPhase.idle);

  final CheckoutPhase phase;
  final String? error;
}

class ProCheckout extends Notifier<CheckoutState> {
  @override
  CheckoutState build() => CheckoutState.idle;

  void set(CheckoutState next) => state = next;
}

final proCheckoutProvider = NotifierProvider<ProCheckout, CheckoutState>(
  ProCheckout.new,
);

/// Whether Sennit Pro is unlocked, and the purchase flow that changes it.
class ProController extends Notifier<ProStatus> {
  StreamSubscription<List<StorePurchase>>? _purchases;
  Timer? _expiry;

  @override
  ProStatus build() {
    // Reset as well as cancelled: the notifier outlives a rebuild, and a
    // cancelled subscription left in the field would make [start] a no-op.
    ref.onDispose(() {
      unawaited(_purchases?.cancel());
      _purchases = null;
      _expiry?.cancel();
      _expiry = null;
    });
    final status = ProStatus(
      edition: ref.watch(sennitEditionProvider),
      storeBillingPlatform: ref.watch(storeBillingPlatformProvider),
      ownership: ProOwnership.fromJson(
        storesOrNull(ref)?.settings.getJson(kProOwnershipSetting),
      ),
    );
    _scheduleExpiry(status.ownership);
    return status;
  }

  /// A subscription lapses with the clock, not with a state change, so the
  /// gates that already said yes would keep saying it. At the end of the
  /// grace window this asks the store again — which also covers a launch
  /// that found it unreachable — and re-publishes the state so every gate
  /// re-evaluates; a confirmation that arrives afterwards unlocks again.
  void _scheduleExpiry(ProOwnership? ownership) {
    _expiry?.cancel();
    _expiry = null;
    if (ownership?.product?.kind != ProProductKind.subscription) return;
    final left = ownership!.confirmedAt
        .add(ProOwnership.subscriptionGrace)
        .difference(DateTime.now());
    _expiry = Timer(left.isNegative ? Duration.zero : left, () async {
      _expiry = null;
      try {
        await _store?.restore();
      } on Object catch (error) {
        debugPrint('weft: billing: restore failed: $error');
      }
      if (ref.mounted) state = state.withOwnership(state.ownership);
    });
  }

  BillingStore? get _store => ref.read(billingStoreProvider);

  /// Listens for store updates and asks for a restore, which re-confirms a
  /// live subscription. Safe to call more than once.
  ///
  /// Must run on every launch, not only when the Pro screen opens: a purchase
  /// that finished while the app was closed — a pending one approved later,
  /// or one bought on another device — arrives on this stream and nowhere
  /// else, and Play refunds it if it is never acknowledged.
  Future<void> start() async {
    unawaited(_recheckLicense());
    final store = _store;
    if (store == null || _purchases != null) return;
    _purchases = store.purchases.listen(
      (list) => unawaited(handle(list)),
      onError: (Object error) => debugPrint('weft: billing: $error'),
    );
    try {
      if (await store.isAvailable()) await store.restore();
    } on Object catch (error) {
      debugPrint('weft: billing: restore failed: $error');
    }
  }

  /// Applies one batch of store updates.
  @visibleForTesting
  Future<void> handle(List<StorePurchase> purchases) async {
    final checkout = ref.read(proCheckoutProvider.notifier);
    for (final purchase in purchases) {
      switch (purchase.status) {
        case StorePurchaseStatus.pending:
          checkout.set(const CheckoutState(CheckoutPhase.pending));
        case StorePurchaseStatus.canceled:
          checkout.set(CheckoutState.idle);
        case StorePurchaseStatus.error:
          checkout.set(
            CheckoutState(CheckoutPhase.failed, error: purchase.error),
          );
        case StorePurchaseStatus.purchased || StorePurchaseStatus.restored:
          if (ProProduct.byId(purchase.productId) != null &&
              await ref.read(purchaseVerifierProvider)(purchase)) {
            _record(purchase.productId);
            // A purchase, not a restore on a new device.
            if (purchase.status == StorePurchaseStatus.purchased &&
                ref.mounted) {
              ref
                  .read(usageStatsProvider)
                  .proPurchased(ProPurchaseSource.store);
            }
          }
          checkout.set(CheckoutState.idle);
      }
      if (purchase.needsCompletion) {
        try {
          await _store?.complete(purchase);
        } on Object catch (error) {
          debugPrint('weft: billing: completing a purchase failed: $error');
        }
      }
    }
  }

  void _record(String productId) {
    if (!ref.mounted) return;
    var next = ProOwnership(productId: productId, confirmedAt: DateTime.now());
    final current = state.ownership;
    if (current != null) next = next.strongest(current);
    storesOrNull(ref)?.settings.setJson(kProOwnershipSetting, next.toJson());
    state = state.withOwnership(next);
    _scheduleExpiry(next);
  }

  /// How long a confirmed licence goes before the service is asked again.
  /// The ask only ever takes Pro away on a definite "no" — after a refund,
  /// say — so being offline for a year costs nothing.
  static const licenseRecheck = Duration(days: 30);

  /// The key this install was unlocked with, for the Pro screen to show.
  String? get licenseKey {
    final key = storesOrNull(ref)?.settings.getJson(kProLicenseSetting)?['key'];
    return key is String ? key : null;
  }

  /// Checks a typed licence key with the licence service and, when it is
  /// good, unlocks Pro for good. Anything that is not shaped like a key is
  /// [LicenseVerdict.invalid] without a request.
  Future<LicenseVerdict> activateLicense(String input) async {
    final client = ref.read(licenseClientProvider);
    if (client == null) return LicenseVerdict.unreachable;
    final key = normalizeLicenseKey(input);
    if (key == null) return LicenseVerdict.invalid;
    final verdict = await client.validate(key);
    if (verdict == LicenseVerdict.valid && ref.mounted) {
      _saveLicense(key);
      _record(ProProduct.lifetime.id);
      ref.read(usageStatsProvider).proPurchased(ProPurchaseSource.licence);
    }
    return verdict;
  }

  void _saveLicense(String key) => storesOrNull(ref)?.settings.setJson(
    kProLicenseSetting,
    {'key': key, 'checked': DateTime.now().toUtc().toIso8601String()},
  );

  Future<void> _recheckLicense() async {
    final client = ref.read(licenseClientProvider);
    final settings = storesOrNull(ref)?.settings;
    if (client == null || settings == null) return;
    final saved = settings.getJson(kProLicenseSetting);
    final key = saved?['key'];
    if (key is! String) return;
    final checked = DateTime.tryParse('${saved?['checked']}');
    if (checked != null &&
        DateTime.now().difference(checked) < licenseRecheck) {
      return;
    }
    final verdict = await client.validate(key);
    if (!ref.mounted) return;
    switch (verdict) {
      case LicenseVerdict.valid:
        _saveLicense(key);
      case LicenseVerdict.invalid:
        settings.remove(kProLicenseSetting);
        settings.remove(kProOwnershipSetting);
        state = state.withOwnership(null);
      case LicenseVerdict.unreachable:
        break;
    }
  }

  /// The store's prices for every Pro product, cheapest commitment first.
  Future<List<StoreOffer>> offers() async {
    final store = _store;
    if (store == null || !await store.isAvailable()) return const [];
    final offers = await store.offers(ProProduct.ids);
    final order = [for (final p in ProProduct.all) p.id];
    return offers..sort(
      (a, b) =>
          order.indexOf(a.productId).compareTo(order.indexOf(b.productId)),
    );
  }

  /// Opens the store's purchase sheet. The result arrives through [handle].
  Future<bool> buy(String productId) async {
    final store = _store;
    if (store == null) return false;
    await start();
    ref.read(proCheckoutProvider.notifier).set(CheckoutState.idle);
    return store.buy(productId);
  }

  Future<void> restore() async {
    final store = _store;
    if (store == null) return;
    // The first start restores on its own.
    if (_purchases == null) return start();
    await store.restore();
  }
}

final proControllerProvider = NotifierProvider<ProController, ProStatus>(
  ProController.new,
);

/// Whether [feature] may run. Every paid code path asks this.
bool proUnlocked(Ref ref, ProFeature feature) =>
    ref.watch(proControllerProvider).unlocks(feature);

/// [proUnlocked] for callbacks, which must read rather than watch.
bool proUnlockedNow(Ref ref, ProFeature feature) =>
    ref.read(proControllerProvider).unlocks(feature);
