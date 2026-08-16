import 'package:weft_domain/weft_domain.dart';

/// One room's history, paginated backwards from the newest message.
///
/// Implemented over a Matrix `Timeline` in the app and over a plain list in
/// tests, which is the whole reason the merge logic lives in a Flutter-free
/// package.
abstract class TimelineSource {
  String get roomId;

  ChatNetwork get network;

  /// Messages loaded so far, **newest first**.
  List<WeftMessage> get loaded;

  /// Whether older messages remain on the server.
  bool get hasMore;

  /// Clock-skew correction applied to every message from this source.
  ///
  /// Bridges stamp `origin_server_ts` from the remote network, and a network
  /// whose clock runs a few seconds off would otherwise interleave wrongly.
  Duration get clockOffset => Duration.zero;

  /// Loads up to [count] older messages. Returns how many were actually added.
  ///
  /// Returning 0 while [hasMore] stays true would stall pagination, so
  /// implementations must either add messages or clear [hasMore].
  Future<int> loadMore({int count = 30});

  /// Effective timestamp of [message] from this source, skew-corrected.
  DateTime effectiveTimestamp(WeftMessage message) =>
      message.timestamp.add(clockOffset);

  /// Skew-corrected timestamp of the oldest loaded message, or null if none.
  DateTime? get oldestLoadedTimestamp {
    if (loaded.isEmpty) return null;
    return effectiveTimestamp(loaded.last);
  }
}

/// In-memory [TimelineSource] backed by a fixed list. Used by tests and by the
/// UI previews.
class InMemoryTimelineSource extends TimelineSource {
  InMemoryTimelineSource({
    required this.roomId,
    required this.network,
    required List<WeftMessage> history,
    this.pageSize = 10,
    Duration clockOffset = Duration.zero,
  }) : _clockOffset = clockOffset,
       // Newest first, matching the contract.
       _history = [...history]
         ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  @override
  final String roomId;

  @override
  final ChatNetwork network;

  final int pageSize;
  final Duration _clockOffset;
  final List<WeftMessage> _history;

  final List<WeftMessage> _loaded = [];

  /// Number of [loadMore] round trips, so tests can assert that pagination
  /// only pulls from the source actually holding the watermark up.
  int loadCallCount = 0;

  @override
  Duration get clockOffset => _clockOffset;

  @override
  List<WeftMessage> get loaded => List.unmodifiable(_loaded);

  @override
  bool get hasMore => _loaded.length < _history.length;

  @override
  Future<int> loadMore({int count = 30}) async {
    loadCallCount++;
    final take = count < pageSize ? count : pageSize;
    final start = _loaded.length;
    final end = (start + take).clamp(0, _history.length);
    if (start >= end) return 0;
    _loaded.addAll(_history.sublist(start, end));
    return end - start;
  }
}
