import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_richtext/weft_richtext.dart';

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
    MergedIdentityResolver resolveSender = senderIsIdentity,
    Set<String> purgedEventIds = const {},
  }) : _timeline = timeline,
       _ownUserId = ownUserId,
       _clockOffset = clockOffset,
       _resolveSender = resolveSender,
       _purgedEventIds = purgedEventIds;

  final sdk.Timeline _timeline;
  final String? _ownUserId;
  final Duration _clockOffset;

  /// Which annotation senders are the same person. Injected because the answer
  /// lives in the identity graph, which this package deliberately does not own.
  final MergedIdentityResolver _resolveSender;

  /// Events this device has deleted and must never show again — a retention
  /// sweep's tombstones, read once when the timeline is opened.
  ///
  /// Deleting an event from the SDK's own database is not enough on its own:
  /// the homeserver still has it, and the next backfill of this room hands it
  /// straight back. Filtering here is what makes the deletion hold, and it is
  /// deliberately the *mapper* that filters rather than the renderer — an event
  /// that never becomes a [WeftMessage] cannot be re-indexed, notified on, or
  /// quoted in a reply preview either.
  ///
  /// A snapshot rather than a live query because this is read once per event
  /// per rebuild, hundreds of times a frame while scrolling. A sweep that
  /// purges something invalidates the open timelines, which rebuilds this
  /// source with a fresh set.
  final Set<String> _purgedEventIds;

  @override
  final ChatNetwork network;

  @override
  String get roomId => _timeline.room.id;

  @override
  Duration get clockOffset => _clockOffset;

  /// Mapping every event on each access would be O(n) per rebuild, and the
  /// timeline is read on every frame while scrolling. The cache is keyed on the
  /// timeline's own length and on a cheap hash of each event's id, status and
  /// type. A reaction, an edit and the redaction of either are all timeline
  /// events of their own, so the length moves for those; the hash is for what
  /// the SDK changes in place. A send replaces its local echo where it stands:
  /// the transaction id becomes the event id, then `sent` becomes `synced` with
  /// the id unchanged, and a late key turns an undecryptable event into a
  /// message. Keyed on the newest event alone, each of those waited for the
  /// next event in the room: a send behind a reply that landed first kept its
  /// clock, and a settled send stayed at `sent`.
  List<WeftMessage>? _cache;
  int _cacheLength = -1;
  int _cacheSignature = 0;

  static int _signatureOf(List<sdk.Event> events) {
    var hash = 0;
    for (final event in events) {
      hash = Object.hash(hash, event.eventId, event.status, event.type);
    }
    return hash;
  }

  @override
  List<WeftMessage> get loaded {
    final events = _timeline.events;
    final signature = _signatureOf(events);

    if (_cache != null &&
        _cacheLength == events.length &&
        _cacheSignature == signature) {
      return _cache!;
    }

    final mapped = <WeftMessage>[];
    for (final event in events) {
      if (_purgedEventIds.contains(event.eventId)) continue;
      final message = mapEvent(
        event,
        network: network,
        ownUserId: _ownUserId,
        timeline: _timeline,
        resolveSender: _resolveSender,
      );
      if (message != null) mapped.add(message);
    }

    _cache = List.unmodifiable(_withReplyPreviews(mapped));
    _cacheLength = events.length;
    _cacheSignature = signature;
    return _cache!;
  }

  /// Fills in the reply previews this room can answer for itself.
  ///
  /// Deliberately partial: a reply whose target is not in this room is left
  /// with a null preview rather than a stub, because in a merged conversation
  /// the target may well be loaded on another leg, and a stub here would render
  /// "message not loaded" over a message that is two bubbles up. Resolving
  /// across legs is the merged layer's job — see `resolveReplyTarget`, which
  /// takes the whole candidate set — and this is the part that does not need
  /// it: the overwhelming majority of replies answer their own room.
  List<WeftMessage> _withReplyPreviews(List<WeftMessage> mapped) {
    // One pass to index, rather than a scan of the whole list per reply: a
    // thread of a thousand messages where most are replies is otherwise
    // quadratic on every timeline change.
    final byId = <String, WeftMessage>{
      for (final message in mapped) message.eventId: message,
    };

    for (var i = 0; i < mapped.length; i++) {
      final targetId = mapped[i].replyToEventId;
      if (targetId == null || !byId.containsKey(targetId)) continue;
      mapped[i] = mapped[i].copyWith(
        replyPreview: resolveReplyTarget(
          replyToEventId: targetId,
          loaded: [byId[targetId]!],
        ),
      );
    }
    return mapped;
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
