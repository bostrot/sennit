import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:weft_domain/weft_domain.dart';

import 'settings_store.dart';
import 'weft_database.dart';

/// One message a sweep may be about to delete.
///
/// The columns of Braid's own message record that decide *how* it is deleted —
/// [senderId] because the user's own messages are redacted for everyone and
/// nobody else's can be, [hasMedia] because a photo also has bytes staged on
/// disk that no database delete would reach.
typedef RetentionCandidate = ({
  String eventId,
  String roomId,
  String senderId,
  DateTime sentAt,
  bool hasMedia,
});

/// Which chats self-delete, when they last got read, and what has already gone.
///
/// The policies themselves are a [SettingsStore] blob rather than a table — see
/// [WeftSettings.retentionPolicies] — so a backup carries them without the
/// archive format learning a new record type. The two things that *are* tables
/// are the ones a blob could not hold: a row per read, and a row per deleted
/// event.
///
/// Every method here is synchronous, like the rest of the stores. The sweeper
/// that drives them is not, because redacting a message is a network call.
class RetentionStore {
  RetentionStore(this._db, this._settings);

  final WeftDatabase _db;
  final SettingsStore _settings;

  Database get _raw => _db.raw;

  // ----------------------------------------------------------------- policies

  RetentionSettings load() => RetentionSettings.fromJson(
    _settings.getJson(WeftSettings.retentionPolicies),
  );

  void save(RetentionSettings settings) {
    if (settings.isDormant) {
      // Nothing left to say, and an empty blob would be a settings row that
      // reads as "this user has configured retention" to anything looking.
      _settings.remove(WeftSettings.retentionPolicies);
      return;
    }
    _settings.setJson(WeftSettings.retentionPolicies, settings.toJson());
  }

  // --------------------------------------------------------------- read marks

  /// The most read marks any one chat keeps.
  ///
  /// A ceiling rather than the mechanism: a chat with an active read-anchored
  /// policy is pruned properly by the sweeper, which drops marks once nothing
  /// they cover can still be alive. This is for every *other* chat — `markRead`
  /// records unconditionally, because a policy set next month has to be able to
  /// count from reads that happened before it existed, and without a ceiling
  /// that is a row per chat opening for the life of the install.
  ///
  /// Dropping the oldest can only ever *delay* a deletion: a message whose mark
  /// is gone re-anchors to a later one, or to none. Nothing expires early
  /// because a mark was trimmed.
  static const int maxReadMarksPerChat = 64;

  /// Records that at [at] the user had read [chatId] as far as [upTo].
  ///
  /// Called from `markRead`, which is the one place that knows both halves.
  /// Idempotent within a millisecond: two reads in the same tick collapse to
  /// the later watermark rather than raising a constraint error.
  void recordRead({
    required String chatId,
    required DateTime at,
    required DateTime upTo,
  }) {
    _raw.execute(
      '''
      INSERT INTO chat_read_mark (chat_id, read_at, up_to_ms)
      VALUES (?, ?, ?)
      ON CONFLICT(chat_id, read_at) DO UPDATE SET
        up_to_ms = MAX(up_to_ms, excluded.up_to_ms)
      ''',
      [chatId, at.millisecondsSinceEpoch, upTo.millisecondsSinceEpoch],
    );
    _raw.execute(
      '''
      DELETE FROM chat_read_mark
      WHERE chat_id = ?
        AND read_at < (
          SELECT MIN(read_at) FROM (
            SELECT read_at FROM chat_read_mark
            WHERE chat_id = ? ORDER BY read_at DESC LIMIT ?
          )
        )
      ''',
      [chatId, chatId, maxReadMarksPerChat],
    );
  }

  /// When the conversation was first read past a message sent at [sentAt], or
  /// null when it has not been.
  ///
  /// The *earliest* qualifying mark, not the latest: a message read a week ago
  /// was read a week ago, however many times the chat has been opened since.
  ///
  /// The definition [readCutoff] is the bulk form of, kept so a test can pin
  /// the semantics one message at a time. The sweep itself asks [candidates],
  /// which cannot afford a query per message.
  @visibleForTesting
  DateTime? readAtFor({required String chatId, required DateTime sentAt}) {
    final rows = _raw.select(
      '''
      SELECT MIN(read_at) AS read_at FROM chat_read_mark
      WHERE chat_id = ? AND up_to_ms >= ?
      ''',
      [chatId, sentAt.millisecondsSinceEpoch],
    );
    final value = rows.isEmpty ? null : rows.first['read_at'] as int?;
    return value == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  /// How far a [RetentionAnchor.read] policy has ripened at [now]: every
  /// message sent at or before this instant has been read long enough to go.
  ///
  /// The whole read anchor, collapsed into one comparable number. A mark whose
  /// own `read_at` is already older than the policy's window makes everything
  /// it covers due, because a message's read stamp is the *earliest* mark
  /// covering it and so is no later than this one's. Taking the largest
  /// `up_to_ms` among those marks therefore names the newest message that can
  /// possibly be due — which turns "join every message against its read mark"
  /// into a single cutoff the timestamp index can answer.
  ///
  /// Null when no mark has ripened, which is the correct answer for a chat
  /// that has never been read.
  DateTime? readCutoff({required String chatId, required DateTime notAfter}) {
    final rows = _raw.select(
      '''
      SELECT MAX(up_to_ms) AS up_to FROM chat_read_mark
      WHERE chat_id = ? AND read_at <= ?
      ''',
      [chatId, notAfter.millisecondsSinceEpoch],
    );
    final value = rows.isEmpty ? null : rows.first['up_to'] as int?;
    return value == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  /// Drops read marks that can no longer change an answer.
  ///
  /// A mark older than the policy's window has ripened: everything it covers is
  /// already due and has just been swept. The newest such mark is deliberately
  /// **kept** — deleting the lot would leave any message that survived the
  /// sweep (a redaction the server refused, an event the SDK could not find)
  /// with no read stamp at all, which under the read anchor means "never
  /// expires". A message that outlived one sweep would then outlive all of them.
  int pruneReadMarks({required String chatId, required DateTime before}) {
    _raw.execute(
      '''
      DELETE FROM chat_read_mark
      WHERE chat_id = ?
        AND read_at <= ?
        AND read_at < (
          SELECT MAX(read_at) FROM chat_read_mark
          WHERE chat_id = ? AND read_at <= ?
        )
      ''',
      [
        chatId,
        before.millisecondsSinceEpoch,
        chatId,
        before.millisecondsSinceEpoch,
      ],
    );
    return _raw.updatedRows;
  }

  /// Every read mark for [chatId], newest first.
  @visibleForTesting
  List<({DateTime readAt, DateTime upTo})> readMarks(String chatId) => _raw
      .select(
        'SELECT read_at, up_to_ms FROM chat_read_mark WHERE chat_id = ? '
        'ORDER BY read_at DESC',
        [chatId],
      )
      .map(
        (row) => (
          readAt: DateTime.fromMillisecondsSinceEpoch(
            row['read_at'] as int,
            isUtc: true,
          ),
          upTo: DateTime.fromMillisecondsSinceEpoch(
            row['up_to_ms'] as int,
            isUtc: true,
          ),
        ),
      )
      .toList(growable: false);

  // --------------------------------------------------------------- candidates

  /// Messages of [chatId] that [policy] has made due by [now].
  ///
  /// Reads Braid's own message record rather than a Matrix timeline, which is
  /// what lets a sweep run over every chat at startup without opening one: a
  /// timeline is an async SDK object that exists only for a chat somebody has
  /// looked at. The cost is the record's own boundary — a message Braid never
  /// indexed is not seen here — and that boundary is the right one anyway,
  /// because `search_message` *is* the history the user would find later.
  ///
  /// [limit] bounds one pass rather than the work: a chat with ten thousand due
  /// messages deletes the oldest [limit] now and the rest on the next sweep,
  /// which keeps a single sweep from holding the database for a minute.
  List<RetentionCandidate> candidates({
    required String chatId,
    required RetentionPolicy policy,
    required DateTime now,
    int limit = 200,
  }) {
    if (!policy.isActive) return const [];

    // Nothing sent after this can have finished its window, whichever anchor
    // is in force: the read anchor's stamp is never earlier than the message.
    var cutoff = now.subtract(policy.after);

    if (policy.anchor == RetentionAnchor.read) {
      final ripened = readCutoff(chatId: chatId, notAfter: cutoff);
      // Never read far enough back: nothing is due, and an unbounded query
      // here would be the whole chat.
      if (ripened == null) return const [];
      if (ripened.isBefore(cutoff)) cutoff = ripened;
    }

    return _raw
        .select(
          '''
          SELECT m.event_id, m.room_id, m.sender_id, m.timestamp, m.has_media
          FROM search_message m
          WHERE m.chat_id = ? AND m.timestamp <= ?
          ORDER BY m.timestamp ASC
          LIMIT ?
          ''',
          [chatId, cutoff.millisecondsSinceEpoch, limit],
        )
        .map(
          (row) => (
            eventId: row['event_id'] as String,
            roomId: row['room_id'] as String,
            senderId: row['sender_id'] as String,
            sentAt: DateTime.fromMillisecondsSinceEpoch(
              row['timestamp'] as int,
              isUtc: true,
            ),
            hasMedia: (row['has_media'] as int? ?? 0) != 0,
          ),
        )
        .toList(growable: false);
  }

  // ---------------------------------------------------------------- tombstones

  /// Records that [eventId] has been deleted from this device.
  void markPurged({
    required String roomId,
    required String eventId,
    required DateTime at,
  }) {
    _raw.execute(
      '''
      INSERT INTO purged_event (room_id, event_id, purged_at)
      VALUES (?, ?, ?)
      ON CONFLICT(room_id, event_id) DO NOTHING
      ''',
      [roomId, eventId, at.millisecondsSinceEpoch],
    );
  }

  bool isPurged({required String roomId, required String eventId}) =>
      _raw.select(
        'SELECT 1 FROM purged_event WHERE room_id = ? AND event_id = ? LIMIT 1',
        [roomId, eventId],
      ).isNotEmpty;

  /// Every event this device has deleted in [roomId].
  ///
  /// A whole-room set rather than a query per message because the caller is the
  /// timeline mapper, which asks about every event it holds on every rebuild —
  /// hundreds of questions per frame while scrolling.
  Set<String> purgedIn(String roomId) => _raw
      .select('SELECT event_id FROM purged_event WHERE room_id = ?', [roomId])
      .map((row) => row['event_id'] as String)
      .toSet();

  @visibleForTesting
  int get purgedCount =>
      _raw.select('SELECT COUNT(*) AS c FROM purged_event').first['c'] as int;
}
