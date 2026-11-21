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
/// Three questions, asked in this order: is the feature on at all, is this
/// network excluded, and — only for a room that is end-to-end encrypted — has
/// the user also agreed to previews there. The first defaults to on and the
/// third to off, the split Element makes, for the reason the Matrix spec
/// itself gives: asking the homeserver about a link tells it the url, and in an
/// encrypted room that is something it would otherwise never see. In a room
/// that is not encrypted the homeserver already holds the message, link and
/// all, so a preview discloses nothing new to it.
///
/// The per-network exclusion is shaped after `TranscriptionSettings` on
/// purpose: the conversations that must stay out of it whatever the master
/// switch says.
@immutable
class LinkPreviewSettings {
  const LinkPreviewSettings({
    this.enabled = true,
    this.encryptedRooms = false,
    this.excludedNetworks = const {},
  });

  /// Reads the gate out of the settings store.
  factory LinkPreviewSettings.fromStore(SettingsStore settings) {
    final excluded = settings.getJson(WeftSettings.linkPreviewExcludedNetworks);
    final networks = excluded?['networks'];
    return LinkPreviewSettings(
      enabled: settings.getBool(
        WeftSettings.linkPreviewEnabled,
        fallback: true,
      ),
      encryptedRooms: settings.getBool(WeftSettings.linkPreviewEncryptedRooms),
      excludedNetworks: {
        if (networks is List)
          for (final id in networks)
            if (id is String) id,
      },
    );
  }

  /// Everything off. What the app falls back to when it cannot read its own
  /// settings — a gate that opens when it cannot find its own configuration
  /// is not a gate — and the state "turn link previews off" writes.
  static const LinkPreviewSettings off = LinkPreviewSettings(enabled: false);

  /// The master switch. Off means no card of any kind: none asked of the
  /// homeserver, and none drawn from what a bridge attached either.
  final bool enabled;

  /// Whether the homeserver may also be asked about links in end-to-end
  /// encrypted rooms. Off unless the user turns it on.
  final bool encryptedRooms;

  /// Network ids never previewed, whatever [enabled] says.
  final Set<String> excludedNetworks;

  /// Whether a card may be drawn at all for a message on [network] — from a
  /// preview the sender attached, which costs no request.
  bool showsCards(ChatNetwork network) =>
      enabled && !excludedNetworks.contains(network.id);

  /// Whether the homeserver may be *asked* about a link on [network], in a room
  /// that is [encrypted] or not.
  bool allows(ChatNetwork network, {bool encrypted = false}) =>
      showsCards(network) && (!encrypted || encryptedRooms);

  void writeTo(SettingsStore settings) {
    settings.setBool(WeftSettings.linkPreviewEnabled, value: enabled);
    settings.setBool(
      WeftSettings.linkPreviewEncryptedRooms,
      value: encryptedRooms,
    );
    settings.setJson(WeftSettings.linkPreviewExcludedNetworks, {
      'networks': excludedNetworks.toList()..sort(),
    });
  }

  LinkPreviewSettings copyWith({
    bool? enabled,
    bool? encryptedRooms,
    Set<String>? excludedNetworks,
  }) => LinkPreviewSettings(
    enabled: enabled ?? this.enabled,
    encryptedRooms: encryptedRooms ?? this.encryptedRooms,
    excludedNetworks: excludedNetworks ?? this.excludedNetworks,
  );

  @override
  bool operator ==(Object other) =>
      other is LinkPreviewSettings &&
      other.enabled == enabled &&
      other.encryptedRooms == encryptedRooms &&
      setEquals(other.excludedNetworks, excludedNetworks);

  @override
  int get hashCode => Object.hash(
    enabled,
    encryptedRooms,
    Object.hashAllUnordered(excludedNetworks),
  );

  @override
  String toString() =>
      'LinkPreviewSettings(enabled: $enabled, encrypted: $encryptedRooms, '
      'excluded: $excludedNetworks)';
}

/// What this run of the app already knows, in front of the disk cache.
///
/// Outlives [LinkPreviewService], which is rebuilt whenever the gate changes:
/// without this every rebuild would forget the answers and the requests in
/// flight, and a card scrolled back into view would go through an empty frame
/// (and a sqlite read) before redrawing what it showed a second ago.
///
/// Bounded, oldest-first eviction. The disk cache behind it is the complete
/// record; this only has to cover what is on screen and what was just on it.
class LinkPreviewMemoryCache {
  LinkPreviewMemoryCache({this.capacity = 256});

  final int capacity;

  final _entries = <String, CachedLinkPreview>{};

  /// Requests in flight, so a list that builds the same bubble twice in one
  /// frame — or a service rebuilt mid-request — makes one request, not two.
  final Map<String, Future<LinkPreview?>> inFlight = {};

  CachedLinkPreview? read(String url) {
    final hit = _entries.remove(url);
    // Re-inserted to move it to the back of the eviction order.
    if (hit != null) _entries[url] = hit;
    return hit;
  }

  void write(CachedLinkPreview entry) {
    _entries
      ..remove(entry.url)
      ..[entry.url] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();

  int get length => _entries.length;
}

/// One lookup's outcome, when it can be told without waiting.
///
/// [known] false means "ask [LinkPreviewService.previewFor]"; true with a null
/// [preview] means the answer is already in and it is "no card".
@immutable
class LinkPreviewPeek {
  const LinkPreviewPeek.unknown() : known = false, preview = null;
  const LinkPreviewPeek.known(this.preview) : known = true;

  final bool known;
  final LinkPreview? preview;
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
    LinkPreviewMemoryCache? memory,
    this.fetch,
    this.successTtl = const Duration(days: 7),
    this.missTtl = const Duration(hours: 6),
    DateTime Function()? now,
  }) : memory = memory ?? LinkPreviewMemoryCache(),
       _now = now ?? DateTime.now;

  final LinkPreviewSettings settings;

  /// Null in a context with no database — a widget test, mainly. The service
  /// still works; it just forgets between calls.
  final LinkPreviewStore? cache;

  /// The answers this run has already seen, in front of [cache].
  final LinkPreviewMemoryCache memory;

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

  /// Whether the homeserver may be asked about a link on [network] right now.
  bool allows(ChatNetwork network, {bool encrypted = false}) =>
      settings.allows(network, encrypted: encrypted);

  /// The answer for [url] if it is already known — memory first, then disk —
  /// without asking anyone.
  ///
  /// What lets a card scrolled back into view draw in its first frame instead
  /// of popping in a frame later. Gated exactly like [previewFor]: a closed
  /// gate is a known "nothing".
  LinkPreviewPeek peek(
    String url, {
    required ChatNetwork network,
    bool encrypted = false,
  }) {
    if (!settings.allows(network, encrypted: encrypted)) {
      return const LinkPreviewPeek.known(null);
    }
    final safe = previewableUrl(url);
    if (safe == null) return const LinkPreviewPeek.known(null);
    final cached = _fresh(safe);
    if (cached == null) return const LinkPreviewPeek.unknown();
    return LinkPreviewPeek.known(_decode(safe, cached));
  }

  /// The preview for [url], or null when there is none to show.
  ///
  /// Null covers every "no card" case deliberately — gate closed, network
  /// excluded, no homeserver, request refused, page with no tags — because the
  /// card has exactly one thing to do about all of them, which is not to draw.
  Future<LinkPreview?> previewFor(
    String url, {
    required ChatNetwork network,
    bool encrypted = false,
  }) async {
    if (!settings.allows(network, encrypted: encrypted)) return null;

    final safe = previewableUrl(url);
    if (safe == null) return null;

    final cached = _fresh(safe);
    if (cached != null) return _decode(safe, cached);

    final fetcher = fetch;
    if (fetcher == null) return null;

    return memory.inFlight[safe] ??= _fetchAndCache(safe, fetcher);
  }

  /// A cached answer still inside its ttl, from memory or else from disk.
  CachedLinkPreview? _fresh(String url) {
    final now = _now();
    bool fresh(CachedLinkPreview c) =>
        !c.isStale(c.isMiss ? missTtl : successTtl, now: now);

    final remembered = memory.read(url);
    if (remembered != null && fresh(remembered)) return remembered;

    final stored = cache?.read(url);
    if (stored == null || !fresh(stored)) return null;
    memory.write(stored);
    return stored;
  }

  static LinkPreview? _decode(String url, CachedLinkPreview cached) {
    final json = cached.preview;
    return json == null ? null : LinkPreview.fromJson(url, json);
  }

  Future<LinkPreview?> _fetchAndCache(
    String url,
    LinkPreviewFetch fetcher,
  ) async {
    try {
      final preview = await fetcher(Uri.parse(url));
      final worth = preview != null && preview.hasContent ? preview : null;
      final at = _now();
      cache?.write(url, worth?.toJson(), at: at);
      memory.write(
        CachedLinkPreview(url: url, preview: worth?.toJson(), fetchedAt: at),
      );
      return worth;
    } finally {
      // `remove` hands back the Future the map was holding, which is this one:
      // nothing is waiting on it here, and awaiting it would be awaiting self.
      unawaited(memory.inFlight.remove(url));
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

/// The answers this run of the app has seen. Lives as long as the app, across
/// every rebuild of [linkPreviewServiceProvider].
final linkPreviewMemoryProvider = Provider<LinkPreviewMemoryCache>(
  (ref) => LinkPreviewMemoryCache(),
);

final linkPreviewServiceProvider = Provider<LinkPreviewService>((ref) {
  return LinkPreviewService(
    settings: ref.watch(linkPreviewSettingsProvider),
    cache: storesOrNull(ref)?.linkPreviews,
    memory: ref.watch(linkPreviewMemoryProvider),
    fetch: ref.watch(linkPreviewFetchProvider),
  );
});

/// One bubble's link, the network it arrived on, and whether its room is
/// encrypted.
///
/// The network and the encryption are part of the key rather than read from
/// somewhere at fetch time because they are what the gate is checked against:
/// the same article forwarded from Signal and from Slack is two questions when
/// Signal is excluded, and the same one in an encrypted and a plain room is two
/// when encrypted previews are off. A key that dropped either would answer the
/// second with the first.
@immutable
class LinkPreviewRequest {
  const LinkPreviewRequest(this.url, this.network, {this.encrypted = false});

  final String url;
  final ChatNetwork network;
  final bool encrypted;

  @override
  bool operator ==(Object other) =>
      other is LinkPreviewRequest &&
      other.url == url &&
      other.network == network &&
      other.encrypted == encrypted;

  @override
  int get hashCode => Object.hash(url, network, encrypted);

  @override
  String toString() =>
      'LinkPreviewRequest($url, ${network.id}'
      '${encrypted ? ', encrypted' : ''})';
}

/// The preview for one message's link, or null.
final linkPreviewProvider =
    FutureProvider.family<LinkPreview?, LinkPreviewRequest>((
      ref,
      request,
    ) async {
      return ref
          .watch(linkPreviewServiceProvider)
          .previewFor(
            request.url,
            network: request.network,
            encrypted: request.encrypted,
          );
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
