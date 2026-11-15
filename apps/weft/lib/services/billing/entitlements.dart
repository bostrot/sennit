import 'package:flutter/foundation.dart';

/// Which build this is: the open-source one, the one the stores carry, or
/// the one downloaded from the release page.
///
/// Chosen at build time with `--dart-define=BRAID_EDITION=store` or
/// `=direct`. Anything else — including no define at all — is [community],
/// which unlocks every feature and never touches a store. That default is
/// deliberate: a source checkout, a contributor's debug build and an
/// F-Droid-style rebuild all get the whole app, and only the release pipeline
/// opts into charging. See `docs/decisions/adr-004-sennit-pro.md`.
enum SennitEdition {
  community,

  /// Uploaded to Play and the App Store; Pro is an in-app purchase.
  store,

  /// Downloaded from the release page; Pro is a licence key bought on the
  /// web. The stores do not allow this route, which is why it is its own
  /// edition rather than a second button in [store].
  direct;

  static SennitEdition parse(String value) =>
      switch (value.trim().toLowerCase()) {
        'store' => store,
        'direct' => direct,
        _ => community,
      };

  static final SennitEdition current = parse(
    const String.fromEnvironment('BRAID_EDITION'),
  );
}

/// What Sennit Pro unlocks.
///
/// One purchase unlocks all of them; the split exists so every gate names what
/// it guards, and so a later plan (a hosted AI endpoint, say) can unlock a
/// different set without touching the gates themselves.
enum ProFeature {
  /// Anything that sends a conversation to the user's LLM endpoint:
  /// auto-replies, reply suggestions on notifications, the to-do assistant.
  aiReplies,

  /// Meaning-based search, on-device or through an embedding endpoint.
  /// Keyword search stays free.
  semanticSearch,

  /// Voice-note transcription, on-device or through an endpoint.
  transcription,

  /// The MCP server that lets the user's own agents read and send.
  mcpServer,

  /// Home Assistant, paperless-ngx and the shared calendar.
  integrations,
}

/// How a product is sold.
enum ProProductKind { lifetime, subscription }

/// The store products Sennit Pro is sold as.
///
/// The ids must match what is set up in Play Console and App Store Connect —
/// the same id on both, which is what lets one table serve both stores.
@immutable
class ProProduct {
  const ProProduct._(this.id, this.kind);

  /// A one-time purchase (non-consumable on both stores).
  static const lifetime = ProProduct._(
    'braid_pro_lifetime',
    ProProductKind.lifetime,
  );

  /// A monthly auto-renewing subscription.
  static const monthly = ProProduct._(
    'braid_pro_monthly',
    ProProductKind.subscription,
  );

  static const all = [lifetime, monthly];

  static Set<String> get ids => {for (final p in all) p.id};

  static ProProduct? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  final String id;
  final ProProductKind kind;
}

/// A purchase this device has seen confirmed by the store.
///
/// A subscription's renewal date is not something the store plugin reports
/// without server-side receipt checks, so a subscription counts for
/// [subscriptionGrace] after the store last confirmed it. Every launch asks
/// the store to restore purchases, which re-confirms a live subscription; a
/// cancelled one stops counting at most that long after it lapses.
@immutable
class ProOwnership {
  const ProOwnership({required this.productId, required this.confirmedAt});

  static const subscriptionGrace = Duration(days: 7);

  final String productId;
  final DateTime confirmedAt;

  ProProduct? get product => ProProduct.byId(productId);

  bool isActive(DateTime now) => switch (product?.kind) {
    ProProductKind.lifetime => true,
    ProProductKind.subscription =>
      now.difference(confirmedAt) <= subscriptionGrace,
    null => false,
  };

  /// The stronger of two records: a lifetime purchase beats a subscription,
  /// and otherwise the more recent confirmation wins.
  ProOwnership strongest(ProOwnership other) {
    final mine = product?.kind == ProProductKind.lifetime;
    final theirs = other.product?.kind == ProProductKind.lifetime;
    if (mine != theirs) return mine ? this : other;
    return confirmedAt.isAfter(other.confirmedAt) ? this : other;
  }

  Map<String, Object?> toJson() => {
    'product': productId,
    'confirmed': confirmedAt.toUtc().toIso8601String(),
  };

  /// Null for anything that is not a record this code wrote.
  static ProOwnership? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final id = json['product'];
    final confirmed = json['confirmed'];
    if (id is! String || confirmed is! String) return null;
    final at = DateTime.tryParse(confirmed);
    if (at == null || ProProduct.byId(id) == null) return null;
    return ProOwnership(productId: id, confirmedAt: at);
  }

  @override
  bool operator ==(Object other) =>
      other is ProOwnership &&
      other.productId == productId &&
      other.confirmedAt == confirmedAt;

  @override
  int get hashCode => Object.hash(productId, confirmedAt);
}

/// Everything a gate needs to answer "may this run?".
@immutable
class ProStatus {
  const ProStatus({
    required this.edition,
    required this.storeBillingPlatform,
    this.ownership,
  });

  final SennitEdition edition;

  /// Whether this platform sells Pro through a store at all — Android and
  /// iOS. A store build on a desktop has no way to take the payment, so
  /// locking features there would lock them for good.
  final bool storeBillingPlatform;

  final ProOwnership? ownership;

  /// Whether this build asks for payment at all. False means every gate is
  /// open and no Pro screen is shown.
  bool get charges => sellsInStore || sellsByLicense;

  /// Pro is bought through Play or the App Store here.
  bool get sellsInStore =>
      edition == SennitEdition.store && storeBillingPlatform;

  /// Pro is unlocked with a licence key here, on every platform.
  bool get sellsByLicense => edition == SennitEdition.direct;

  bool unlocks(ProFeature feature, {DateTime? now}) {
    if (!charges) return true;
    return ownership?.isActive(now ?? DateTime.now()) ?? false;
  }

  /// True when the user owns Pro, as opposed to getting it for free.
  bool owned({DateTime? now}) =>
      ownership?.isActive(now ?? DateTime.now()) ?? false;

  ProStatus withOwnership(ProOwnership? next) => ProStatus(
    edition: edition,
    storeBillingPlatform: storeBillingPlatform,
    ownership: next,
  );
}

/// Thrown by a paid service asked to start without Pro.
class ProFeatureLocked implements Exception {
  const ProFeatureLocked(this.feature);

  final ProFeature feature;

  @override
  String toString() => 'ProFeatureLocked(${feature.name})';
}
