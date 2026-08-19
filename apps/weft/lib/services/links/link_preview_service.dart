import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_richtext/weft_richtext.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/session_providers.dart';
import '../../app/stores.dart';

/// The privacy gate on link previews.
///
/// Shaped after `TranscriptionSettings` on purpose, because it is the same
/// question in a different place: a master switch that is off until someone
/// turns it on, and a per-network exclusion for the conversations that must
/// stay out of it whatever the master switch says. Weft has two of these gates
/// now and they behave identically, which is worth more than either of them
/// being individually clever.
@immutable
class LinkPreviewSettings {
  const LinkPreviewSettings({
    this.enabled = false,
    this.excludedNetworks = const {},
  });

  /// Reads the gate out of the settings store.
  factory LinkPreviewSettings.fromStore(SettingsStore settings) {
    final excluded = settings.getJson(WeftSettings.linkPreviewExcludedNetworks);
    final networks = excluded?['networks'];
    return LinkPreviewSettings(
      enabled: settings.getBool(WeftSettings.linkPreviewEnabled),
      excludedNetworks: {
        if (networks is List)
          for (final id in networks)
            if (id is String) id,
      },
    );
  }

  /// Off, with nothing excluded. The state an app that has never been
  /// configured is in, and the state a failure to read the settings falls back
  /// to — a gate that opens when it cannot find its own configuration is not a
  /// gate.
  static const LinkPreviewSettings off = LinkPreviewSettings();

  final bool enabled;

  /// Network ids never previewed, whatever [enabled] says.
  final Set<String> excludedNetworks;

  bool allows(ChatNetwork network) =>
      enabled && !excludedNetworks.contains(network.id);

  void writeTo(SettingsStore settings) {
    settings.setBool(WeftSettings.linkPreviewEnabled, value: enabled);
    settings.setJson(WeftSettings.linkPreviewExcludedNetworks, {
      'networks': excludedNetworks.toList()..sort(),
    });
  }

  LinkPreviewSettings copyWith({
    bool? enabled,
    Set<String>? excludedNetworks,
  }) => LinkPreviewSettings(
    enabled: enabled ?? this.enabled,
    excludedNetworks: excludedNetworks ?? this.excludedNetworks,
  );

  @override
  bool operator ==(Object other) =>
      other is LinkPreviewSettings &&
      other.enabled == enabled &&
      setEquals(other.excludedNetworks, excludedNetworks);

  @override
  int get hashCode =>
      Object.hash(enabled, Object.hashAllUnordered(excludedNetworks));

  @override
  String toString() =>
      'LinkPreviewSettings(enabled: $enabled, excluded: $excludedNetworks)';
}

/// Gate, cache and fetch, in that order.
///
/// The order is the design. Nothing asks the homeserver anything until the
/// setting says yes for *this network*, and nothing asks twice for a url the
/// cache already has an answer for — including the answer "there is nothing
/// there", which is the one a naive cache drops and then re-asks forever.
class LinkPreviewService {
  LinkPreviewService({
    required this.settings,
    this.cache,
    this.fetch,
    this.successTtl = const Duration(days: 7),
    this.missTtl = const Duration(hours: 6),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LinkPreviewSettings settings;

  /// Null in a context with no database — a widget test, mainly. The service
  /// still works; it just forgets between calls.
  final LinkPreviewStore? cache;

  /// Null in demo mode and before the session is up. A service with no fetcher
  /// answers from the cache and otherwise answers nothing, which is exactly
  /// what a card with no homeserver behind it should show.
  final LinkPreviewFetch? fetch;

  /// How long a real preview is trusted. Long, because a shared article's title
  /// does not change and a re-request would be a second disclosure of the same
  /// fact.
  final Duration successTtl;

  /// How long "nothing there" is trusted. Shorter, because it is the answer a
  /// rate-limited or briefly-broken homeserver also gives, and pinning that for
  /// a week would make a transient failure look permanent.
  final Duration missTtl;

  final DateTime Function() _now;

  /// Requests in flight, so a list that builds the same bubble twice in one
  /// frame makes one request rather than two.
  final Map<String, Future<LinkPreview?>> _inFlight = {};

  /// Whether [network] may be previewed at all right now.
  bool allows(ChatNetwork network) => settings.allows(network);

  /// The preview for [url], or null when there is none to show.
  ///
  /// Null covers every "no card" case deliberately — gate closed, network
  /// excluded, no homeserver, request refused, page with no tags — because the
  /// card has exactly one thing to do about all of them, which is not to draw.
  Future<LinkPreview?> previewFor(
    String url, {
    required ChatNetwork network,
  }) async {
    if (!settings.allows(network)) return null;

    final safe = previewableUrl(url);
    if (safe == null) return null;

    final cached = cache?.read(safe);
    if (cached != null &&
        !cached.isStale(cached.isMiss ? missTtl : successTtl, now: _now())) {
      final json = cached.preview;
      return json == null ? null : LinkPreview.fromJson(safe, json);
    }

    final fetcher = fetch;
    if (fetcher == null) return null;

    return _inFlight[safe] ??= _fetchAndCache(safe, fetcher);
  }

  Future<LinkPreview?> _fetchAndCache(
    String url,
    LinkPreviewFetch fetcher,
  ) async {
    try {
      final preview = await fetcher(Uri.parse(url));
      final worth = preview != null && preview.hasContent ? preview : null;
      cache?.write(url, worth?.toJson(), at: _now());
      return worth;
    } finally {
      // `remove` hands back the Future the map was holding, which is this one:
      // nothing is waiting on it here, and awaiting it would be awaiting self.
      unawaited(_inFlight.remove(url));
    }
  }
}

/// The gate as the app reads it.
///
/// Fails closed. Until the database is open nobody can say whether the user
/// opted in, and the honest answer to that is "they did not" — the same reason
/// [LinkPreviewSettings.off] is the default rather than a guess. See
/// [storesOrNull] for why the read is guarded at all.
final linkPreviewSettingsProvider = Provider<LinkPreviewSettings>((ref) {
  ref.watch(settingsRevisionProvider);
  final stores = storesOrNull(ref);
  return stores == null
      ? LinkPreviewSettings.off
      : LinkPreviewSettings.fromStore(stores.settings);
});

/// Where previews come from, or null when there is nowhere to ask.
final linkPreviewFetchProvider = Provider<LinkPreviewFetch?>((ref) {
  if (kDemoMode) return null;
  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) return null;
  return homeserverLinkPreviews(session.client);
});

final linkPreviewServiceProvider = Provider<LinkPreviewService>((ref) {
  return LinkPreviewService(
    settings: ref.watch(linkPreviewSettingsProvider),
    cache: storesOrNull(ref)?.linkPreviews,
    fetch: ref.watch(linkPreviewFetchProvider),
  );
});

/// One bubble's link, and the network it arrived on.
///
/// The network is part of the key rather than read from somewhere at fetch
/// time because it is what the *exclusion* is checked against: the same article
/// forwarded from Signal and from Slack is two questions when Signal is
/// excluded, and a key that dropped it would answer the second with the first.
@immutable
class LinkPreviewRequest {
  const LinkPreviewRequest(this.url, this.network);

  final String url;
  final ChatNetwork network;

  @override
  bool operator ==(Object other) =>
      other is LinkPreviewRequest &&
      other.url == url &&
      other.network == network;

  @override
  int get hashCode => Object.hash(url, network);

  @override
  String toString() => 'LinkPreviewRequest($url, ${network.id})';
}

/// The preview for one message's link, or null.
final linkPreviewProvider =
    FutureProvider.family<LinkPreview?, LinkPreviewRequest>((
      ref,
      request,
    ) async {
      return ref
          .watch(linkPreviewServiceProvider)
          .previewFor(request.url, network: request.network);
    });

/// Whether the homeserver serves media from the authenticated endpoints.
///
/// Asked once and reused. Guessing wrong 404s the preview thumbnail, which
/// looks exactly like a page that had no image — so the card degrades to text
/// rather than breaking, but it degrades for the wrong reason and the reader
/// cannot tell.
final authenticatedMediaProvider = FutureProvider<bool>((ref) async {
  if (kDemoMode) return true;
  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) return true;
  try {
    return await session.client.authenticatedMediaSupported();
  } on Object catch (_) {
    return true;
  }
});

/// The preview image as something an `Image` can load, or null.
///
/// Goes through the ordinary media path: an `mxc://` uri resolved against this
/// homeserver, with the bearer token every authenticated media request needs.
/// The image is one the homeserver already fetched and re-hosted — loading it
/// tells the site nothing, which is the property the whole feature is built on
/// and would be quietly lost if this ever resolved a remote url.
final linkPreviewImageProvider = Provider.family<ImageProvider?, String>((
  ref,
  mxc,
) {
  if (kDemoMode) return null;
  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) return null;

  final url = mxcToThumbnailUrl(
    session.client,
    mxc,
    authenticatedMedia: ref.watch(authenticatedMediaProvider).value ?? true,
    size: 240,
  );
  if (url == null) return null;

  return NetworkImage(url, headers: mediaAuthHeaders(session.client));
});
