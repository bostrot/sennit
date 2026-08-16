import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import 'mapping.dart';

/// Adapts a Matrix [sdk.Timeline] to the [TimelineSource] contract that
/// [MergedTimeline] consumes.
///
/// This is the seam that lets the merge logic stay pure Dart: everything
/// SDK-shaped stops here, and the watermark algorithm on the other side never
/// learns what a Matrix event is.
class MatrixTimelineSource extends TimelineSource {
  MatrixTimelineSource({
    required sdk.Timeline timeline,
    required this.network,
    required String? ownUserId,
    Duration clockOffset = Duration.zero,
  }) : _timeline = timeline,
       _ownUserId = ownUserId,
       _clockOffset = clockOffset;

  final sdk.Timeline _timeline;
  final String? _ownUserId;
  final Duration _clockOffset;

  @override
  final ChatNetwork network;

  @override
  String get roomId => _timeline.room.id;

  @override
  Duration get clockOffset => _clockOffset;

  /// Mapping every event on each access would be O(n) per rebuild, and the
  /// timeline is read on every frame while scrolling. The cache is keyed on the
  /// timeline's own length and newest event, which together change whenever the
  /// SDK mutates it.
  List<WeftMessage>? _cache;
  int _cacheLength = -1;
  String? _cacheNewestId;

  @override
  List<WeftMessage> get loaded {
    final events = _timeline.events;
    final newestId = events.isEmpty ? null : events.first.eventId;

    if (_cache != null &&
        _cacheLength == events.length &&
        _cacheNewestId == newestId) {
      return _cache!;
    }

    final mapped = <WeftMessage>[];
    for (final event in events) {
      final message = mapEvent(
        event,
        network: network,
        ownUserId: _ownUserId,
        timeline: _timeline,
      );
      if (message != null) mapped.add(message);
    }

    _cache = List.unmodifiable(mapped);
    _cacheLength = events.length;
    _cacheNewestId = newestId;
    return _cache!;
  }

  @override
  bool get hasMore => _timeline.canRequestHistory;

  @override
  Future<int> loadMore({int count = 30}) async {
    final before = _timeline.events.length;
    await _timeline.requestHistory(historyCount: count);
    return _timeline.events.length - before;
  }

  /// Releases the underlying timeline's subscriptions.
  void dispose() => _timeline.cancelSubscriptions();
}
