import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

import '../../data/chat_repository.dart';

/// Deletes the media a message staged on disk. See `MediaFileStore.purge`.
///
/// A function rather than the store itself so a test can watch what was asked
/// for without a `path_provider` method channel, which never answers under
/// `flutter_test`.
typedef MediaPurge = Future<void> Function(String eventId);

/// What one pass deleted, for the log and for tests.
typedef SweepResult = ({int redacted, int forgotten, int deferred});

/// Erases the messages a chat's [RetentionPolicy] has made due.
///
/// ## What "deleted" means, exactly
///
/// Two different things, and conflating them would be the one lie this feature
/// cannot afford:
///
/// * **The user's own messages are redacted.** That is a real deletion — the
///   homeserver drops the content, every other client drops it, and the bridges
///   relay it onward as WhatsApp's or Signal's own delete-for-everyone.
/// * **Everyone else's are forgotten locally**: dropped from the Matrix SDK's
///   database, from Braid's message record, from any bytes staged on disk, and
///   tombstoned so a backfill cannot walk them back in. The sender's copy is
///   not Braid's to touch, and no client can make it so.
///
/// ## Order, and what happens when a step fails
///
/// The tombstone is written **first**, so a pass that dies halfway leaves a
/// message hidden rather than half-deleted, and the next pass finishes the job.
/// A redaction that fails for a reason that might not recur — offline, a 5xx,
/// a rate limit — **defers the whole message**: nothing local is dropped, and
/// the next sweep tries again. Purging locally first would throw away the only
/// record of what still needs redacting, and the message would stay on the
/// peer's phone forever with nothing left here to notice.
///
/// A message the room no longer holds is a different case and is *not*
/// deferred: it was already redacted, or the room was left, and there is
/// nothing left to ask the server for.
class RetentionSweeper {
  RetentionSweeper({
    required RetentionStore retention,
    required SearchStore search,
    required ChatRepository repository,
    required String? ownUserId,
    MediaPurge? purgeMedia,
    this.batchSize = 200,
  }) : _retention = retention,
       _search = search,
       _repository = repository,
       _ownUserId = ownUserId,
       _purgeMedia = purgeMedia;

  final RetentionStore _retention;
  final SearchStore _search;
  final ChatRepository _repository;
  final String? _ownUserId;
  final MediaPurge? _purgeMedia;

  /// How many messages one chat may lose in a single pass.
  ///
  /// A bound on the pass, not on the work: a chat with ten thousand due
  /// messages loses the oldest [batchSize] now and the rest on the next tick,
  /// which keeps a newly-set "delete after an hour" on a long history from
  /// holding the database — and the UI thread behind it — for a minute.
  final int batchSize;

  /// How often the periodic pass runs while the app is in the foreground.
  ///
  /// A minute is fine-grained enough that the shortest offered window (an hour)
  /// is honoured to within a rounding error, and coarse enough that a dormant
  /// install — which is nearly all of them — spends nothing: [sweepAll] returns
  /// on an empty settings blob before it touches the database.
  static const Duration interval = Duration(minutes: 1);

  Timer? _timer;
  bool _running = false;

  /// Starts the periodic pass, beginning with one now. Idempotent.
  ///
  /// The immediate pass is the important one: the clock does not stop when the
  /// app does, and a conversation set to erase after an hour has a night's
  /// worth of messages due before its first bubble is drawn.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(sweepAll()));
    unawaited(sweepAll());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass over every chat that self-deletes.
  ///
  /// Never runs twice at once: a sweep is mostly awaiting the network, and a
  /// second pass entering while the first is mid-redaction would ask for the
  /// same deletions again.
  Future<SweepResult> sweepAll() async {
    if (_running) return (redacted: 0, forgotten: 0, deferred: 0);
    final settings = _retention.load();
    if (settings.isDormant) return (redacted: 0, forgotten: 0, deferred: 0);

    _running = true;
    try {
      var redacted = 0;
      var forgotten = 0;
      var deferred = 0;
      for (final entry in settings.byChat.entries) {
        final result = await _sweep(entry.key, entry.value);
        redacted += result.redacted;
        forgotten += result.forgotten;
        deferred += result.deferred;
      }
      return (redacted: redacted, forgotten: forgotten, deferred: deferred);
    } finally {
      _running = false;
    }
  }

  /// One pass over a single chat — what opening a conversation runs, so a chat
  /// that was due while the app was closed is already clean by the time its
  /// first bubble draws.
  Future<SweepResult> sweepChat(String chatId) async {
    if (_running) return (redacted: 0, forgotten: 0, deferred: 0);
    final policy = _retention.load().forChat(chatId);
    if (!policy.isActive) return (redacted: 0, forgotten: 0, deferred: 0);

    _running = true;
    try {
      return await _sweep(chatId, policy);
    } finally {
      _running = false;
    }
  }

  Future<SweepResult> _sweep(String chatId, RetentionPolicy policy) async {
    final now = clock.now().toUtc();
    final due = _retention.candidates(
      chatId: chatId,
      policy: policy,
      now: now,
      limit: batchSize,
    );
    if (due.isEmpty) return (redacted: 0, forgotten: 0, deferred: 0);

    var redacted = 0;
    var forgotten = 0;
    var deferred = 0;

    for (final candidate in due) {
      final own = _ownUserId != null && candidate.senderId == _ownUserId;
      if (own) {
        final outcome = await _redact(chatId, candidate.eventId);
        switch (outcome) {
          case _RedactOutcome.done:
            redacted++;
          case _RedactOutcome.gone:
            break;
          case _RedactOutcome.retry:
            deferred++;
            continue;
        }
      }
      await _forget(candidate, at: now);
      forgotten++;
    }

    // Only once the pass is done: a mark is what tells a deferred message when
    // it was read, and pruning before the retry would strand it.
    if (deferred == 0 && policy.anchor == RetentionAnchor.read) {
      _retention.pruneReadMarks(
        chatId: chatId,
        before: now.subtract(policy.after),
      );
    }

    return (redacted: redacted, forgotten: forgotten, deferred: deferred);
  }

  Future<_RedactOutcome> _redact(String chatId, String eventId) async {
    try {
      await _repository.redact(chatId, eventId);
      return _RedactOutcome.done;
    } on StateError {
      // The repository's own signal that no room behind this chat holds the
      // event: already redacted, or the room has been left. Nothing to ask the
      // server for, and deferring would defer forever.
      return _RedactOutcome.gone;
    } on Object catch (error) {
      // Offline, a 5xx, a rate limit — anything that might work next minute.
      // The message keeps its row so the next pass finds it again.
      debugPrint('weft: retention could not redact $eventId: $error');
      return _RedactOutcome.retry;
    }
  }

  Future<void> _forget(
    RetentionCandidate candidate, {
    required DateTime at,
  }) async {
    // First, and before anything is actually dropped: the tombstone is what
    // stops a backfill from re-serving the message and Braid's indexer from
    // re-filing it. A pass that dies after this leaves a hidden message that
    // the next pass finishes deleting; one that died before it would leave a
    // message that came back.
    _retention.markPurged(
      roomId: candidate.roomId,
      eventId: candidate.eventId,
      at: at,
    );

    try {
      await _repository.forgetLocally(candidate.roomId, candidate.eventId);
    } on Object catch (error) {
      // The tombstone already hides it; the SDK's own copy going stale is a
      // disk-space problem, not a privacy one, and must not stop the rest.
      debugPrint('weft: retention could not drop ${candidate.eventId}: $error');
    }

    // Braid's own record of what was said — the one place a search would find
    // the words again.
    _search.removeMessage(eventId: candidate.eventId, roomId: candidate.roomId);

    if (!candidate.hasMedia) return;
    final purge = _purgeMedia;
    if (purge == null) return;
    try {
      // Bytes staged for the viewer or a share sheet. A row delete never
      // touches these, and a photo left behind is the whole message.
      await purge(candidate.eventId);
    } on Object catch (error) {
      debugPrint('weft: retention could not drop staged media: $error');
    }
  }
}

enum _RedactOutcome { done, gone, retry }
