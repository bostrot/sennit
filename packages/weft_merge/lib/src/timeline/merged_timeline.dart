import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'timeline_source.dart';

/// An immutable snapshot of a merged conversation.
@immutable
class MergedTimelineView {
  const MergedTimelineView({
    required this.messages,
    required this.watermark,
    required this.hasMoreHistory,
  });

  /// Safely orderable messages, **newest first**.
  ///
  /// Every message here is guaranteed to be in its final position: no
  /// not-yet-loaded message from any source can ever sort above it. See
  /// [MergedTimeline] for why.
  final List<WeftMessage> messages;

  /// The oldest timestamp we can currently render without risking a hole, or
  /// null when every source is fully loaded.
  final DateTime? watermark;

  /// Whether any source still has history on the server.
  final bool hasMoreHistory;

  bool get isEmpty => messages.isEmpty;

  @override
  String toString() =>
      'MergedTimelineView(${messages.length} messages, '
      'watermark=$watermark, hasMore=$hasMoreHistory)';
}

/// Interleaves several rooms into one conversation.
///
/// ## The hole problem
///
/// Naively concatenating each room's loaded messages and sorting produces a
/// timeline that silently corrupts itself while scrolling. Suppose WhatsApp has
/// loaded back to 14:00 and Signal only back to 16:00. Sorting what's loaded
/// renders a Signal message at 16:05 directly above a WhatsApp message at
/// 15:30 — but Signal may well have a message at 15:45 that simply hasn't been
/// fetched. When it arrives, it has to be inserted *between two already-visible
/// messages*, and the conversation the user was reading rewrites itself.
///
/// ## The watermark rule
///
/// Let `W = max(oldestLoaded(s))` over every source `s` that still has history.
/// Only messages **strictly newer** than `W` are exposed.
///
/// This is sound: any unloaded message `x` in source `s` satisfies
/// `x <= oldestLoaded(s) <= W`, while every exposed message `m` satisfies
/// `m > W`. So `x < m` for all unloaded `x`, and no insertion above the fold is
/// possible.
///
/// The comparison must be strict. Two messages in one room can share a
/// timestamp and land on opposite sides of a pagination boundary, in which case
/// `x == oldestLoaded(s) == W`; admitting messages *equal* to `W` would let the
/// tie-break rule slot `x` above an already-visible message. The cost is that
/// messages sitting exactly on the watermark stay hidden for one extra round.
///
/// [loadMore] then pulls only from the sources actually holding `W` up —
/// paginating any other source cannot lower the watermark and would just waste
/// a round trip.
class MergedTimeline {
  MergedTimeline({required List<TimelineSource> sources})
    : assert(sources.isNotEmpty, 'A merged timeline needs at least one source'),
      _sources = List.unmodifiable(sources);

  final List<TimelineSource> _sources;

  List<TimelineSource> get sources => _sources;

  /// Networks feeding this timeline, in stable enum order.
  List<ChatNetwork> get networks {
    final seen = _sources.map((s) => s.network).toSet();
    return ChatNetwork.values.where(seen.contains).toList(growable: false);
  }

  /// Current watermark, or null when every source is exhausted.
  DateTime? get watermark {
    DateTime? highest;
    for (final source in _sources) {
      if (!source.hasMore) continue;

      final oldest = source.oldestLoadedTimestamp;
      if (oldest == null) {
        // Nothing loaded but history exists: this source could hold a message
        // newer than anything we have, so nothing at all is safe to show.
        return _distantFuture;
      }
      if (highest == null || oldest.isAfter(highest)) highest = oldest;
    }
    return highest;
  }

  static final DateTime _distantFuture = DateTime.fromMillisecondsSinceEpoch(
    8640000000000000,
    isUtc: true,
  );

  bool get hasMoreHistory => _sources.any((s) => s.hasMore);

  /// Builds the current safe view.
  MergedTimelineView view() {
    final merged = _mergeLoaded();
    final w = watermark;

    final visible = w == null
        ? merged
        : merged
              .where((m) => _effectiveTs(m).isAfter(w))
              .toList(growable: false);

    return MergedTimelineView(
      messages: visible,
      watermark: w == _distantFuture ? null : w,
      hasMoreHistory: hasMoreHistory,
    );
  }

  /// Loads history from whichever sources are pinning the watermark.
  ///
  /// Returns true when at least one message was added, so a caller can loop
  /// until the view actually grows.
  Future<bool> loadMore({int count = 30}) async {
    final pending = _sources.where((s) => s.hasMore).toList();
    if (pending.isEmpty) return false;

    // Sources that have loaded nothing yet must be primed first: until they
    // have a newest message we cannot bound them at all.
    final unprimed = pending
        .where((s) => s.oldestLoadedTimestamp == null)
        .toList();
    if (unprimed.isNotEmpty) {
      final added = await Future.wait(
        unprimed.map((s) => s.loadMore(count: count)),
      );
      return added.any((n) => n > 0);
    }

    // Otherwise pull only from the sources holding the watermark up.
    DateTime? highest;
    for (final s in pending) {
      final oldest = s.oldestLoadedTimestamp!;
      if (highest == null || oldest.isAfter(highest)) highest = oldest;
    }
    final blocking = pending
        .where((s) => s.oldestLoadedTimestamp!.isAtSameMomentAs(highest!))
        .toList();

    final added = await Future.wait(
      blocking.map((s) => s.loadMore(count: count)),
    );
    return added.any((n) => n > 0);
  }

  /// Loads until the view gains messages or history runs out.
  ///
  /// One [loadMore] can legitimately add messages without revealing any — it
  /// may only have lowered the watermark part of the way — so a UI "load older"
  /// action wants this rather than a bare [loadMore].
  Future<MergedTimelineView> loadMoreUntilVisibleGrowth({
    int count = 30,
    int maxRounds = 8,
  }) async {
    final before = view().messages.length;
    for (var round = 0; round < maxRounds; round++) {
      if (!hasMoreHistory) break;
      final progressed = await loadMore(count: count);
      if (!progressed) break;
      final current = view();
      if (current.messages.length > before) return current;
    }
    return view();
  }

  DateTime _effectiveTs(WeftMessage m) {
    for (final s in _sources) {
      if (s.roomId == m.roomId) return s.effectiveTimestamp(m);
    }
    return m.timestamp;
  }

  /// k-way merge of the per-source loaded lists, newest first.
  ///
  /// Each source is already sorted, so this walks k cursors. k is the number of
  /// networks in a merged chat — realistically under ten — so a linear scan
  /// across the heads beats a heap on both constant factor and clarity.
  List<WeftMessage> _mergeLoaded() {
    final lists = _sources.map((s) => s.loaded).toList(growable: false);
    final cursors = List<int>.filled(lists.length, 0);

    var total = 0;
    for (final l in lists) {
      total += l.length;
    }
    final out = <WeftMessage>[];

    for (var emitted = 0; emitted < total; emitted++) {
      var bestIndex = -1;
      DateTime? bestTs;
      WeftMessage? best;

      for (var i = 0; i < lists.length; i++) {
        if (cursors[i] >= lists[i].length) continue;
        final candidate = lists[i][cursors[i]];
        final ts = _sources[i].effectiveTimestamp(candidate);

        if (bestTs == null || ts.isAfter(bestTs)) {
          bestIndex = i;
          bestTs = ts;
          best = candidate;
        } else if (ts.isAtSameMomentAs(bestTs) &&
            _tieBreak(candidate, best!) < 0) {
          bestIndex = i;
          best = candidate;
        }
      }

      if (bestIndex < 0) break;
      out.add(lists[bestIndex][cursors[bestIndex]]);
      cursors[bestIndex]++;
    }
    return out;
  }

  /// Deterministic ordering for equal timestamps *across* sources, so the same
  /// set of messages always renders in the same order on every device.
  ///
  /// Ordering *within* a source is never decided here: each source contributes
  /// its messages in its own order, and for a Matrix room that stream order is
  /// authoritative for events sharing an `origin_server_ts`. The [eventId]
  /// comparison is therefore only a defensive fallback for the pathological
  /// case of two sources reporting the same room.
  static int _tieBreak(WeftMessage a, WeftMessage b) {
    final byRoom = a.roomId.compareTo(b.roomId);
    if (byRoom != 0) return byRoom;
    return a.eventId.compareTo(b.eventId);
  }
}
