/// The seam between the `.braid` archive and Braid's own tables.
///
/// `weft_backup` owns the container, the crypto and the merge *rules*; this
/// file owns the SQL and the files on disk. The dependency points one way —
/// store knows about backup — which is what lets the format be decided in a
/// pure-Dart test suite while the schema stays here, next to the migrations
/// that define it.
///
/// ## What a complete backup captures
///
/// Braid's database, table by table, and what happens to each:
///
/// | table              | in an archive | why                                    |
/// | ------------------ | ------------- | -------------------------------------- |
/// | `unified_contact`  | yes           | the identity graph                     |
/// | `network_handle`   | yes           | the identity graph                     |
/// | `merge_decision`   | yes           | irreplaceable; exists nowhere else     |
/// | `chat_prefs`       | yes           | a user decision                        |
/// | `settings`         | yes, filtered | minus the device-scoped keys below     |
/// | `search_message`   | yes           | **the message history itself**         |
/// | `transcript`       | yes           | paid for once, in inference or money   |
/// | `search_fts`       | no            | rebuilt by triggers on insert          |
/// | `search_embedding` | no            | derived, model-specific, and enormous  |
/// | `embedding_queue`  | no            | re-queued on restore, below            |
/// | `link_preview`     | no            | a cache, and a log of links received   |
///
/// Plus, on disk: the staged attachments under `<support>/media/<event>/<name>`
/// that `MediaFileStore` writes.
///
/// **`search_message` is the history.** That deserves saying plainly, because
/// the name suggests an index rather than a record. Braid does not keep its own
/// copy of the Matrix timeline — the SDK's database does — but the SDK's
/// database is protocol state full of device keys, and it holds *rooms* rather
/// than the cross-network view. `search_message` is where Braid's own answer to
/// "what was said, by whom, on which network, in which unified chat" lives, and
/// that answer is the thing that exists nowhere else once a bridge is gone.
///
/// **The Matrix SDK's database is deliberately not backed up.** It holds the
/// E2EE device keys and the access token, and an archive carrying those would
/// be an account takeover in a file. See `weft_backup/src/export.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:weft_backup/weft_backup.dart';

import 'weft_database.dart';

/// Setting keys that must not travel in an archive.
///
/// Not secrets — those live in the keychain via `SecretStore` and were never in
/// this table — but keys whose value is true of *one device* and false of the
/// one restoring. Carrying them over is worse than losing them.
const Set<String> kSettingsExcludedFromBackup = {
  // The push key this device registered with. Restoring it onto a second phone
  // makes that phone believe it owns a pusher registered by the first, and the
  // rotation logic then deletes a live pusher belonging to a device that is
  // still using it — which reads to the user as notifications simply stopping.
  'notify.push_key',
  // Whether *this* install has been through the permission prompt. Both
  // platforms give an app exactly one prompt; restoring a `true` onto a fresh
  // install spends that one chance without ever showing the rationale sheet.
  'notify.permission_asked',
};

/// Rows read out of SQLite in pages of this size.
///
/// Large enough that a 200 000-message export is 200 queries rather than
/// 200 000, small enough that no page is a memory event. The point of the
/// paging is that `records()` is a `Stream` all the way down: nothing here ever
/// materialises a whole table, which is the property the archive format was
/// built around.
const int _pageSize = 500;

/// Reads Braid's tables and the media directory into archive records.
class StoreBackupSource implements BackupSource {
  StoreBackupSource({required WeftDatabase database, Directory? mediaDirectory})
    : _db = database,
      _media = mediaDirectory;

  final WeftDatabase _db;
  final Directory? _media;

  Database get _raw => _db.raw;

  @override
  Future<BackupSummary> summarise({required bool includeMedia}) async {
    final media = includeMedia ? await _mediaFiles() : const <_MediaFile>[];

    return BackupSummary(
      networks: _raw
          .select('SELECT DISTINCT network FROM search_message')
          .map((row) => row['network'] as String)
          .where((id) => id.isNotEmpty)
          .toList(growable: false),
      chatCount: _count(
        'SELECT COUNT(DISTINCT chat_id) AS c FROM search_message',
      ),
      messageCount: _count('SELECT COUNT(*) AS c FROM search_message'),
      // Counted before dedup, because dedup needs the hashes and hashing every
      // file twice to make a progress bar slightly more accurate is a bad
      // trade. An over-count finishes the bar early, which is the right
      // direction to be wrong in.
      mediaCount: media.length,
      mediaBytes: media.fold(0, (sum, file) => sum + file.length),
      otherRecordCount:
          _count('SELECT COUNT(*) AS c FROM unified_contact') +
          _count('SELECT COUNT(*) AS c FROM network_handle') +
          _count('SELECT COUNT(*) AS c FROM merge_decision') +
          _count('SELECT COUNT(*) AS c FROM chat_prefs') +
          _count('SELECT COUNT(*) AS c FROM settings') +
          _count('SELECT COUNT(*) AS c FROM transcript') +
          media.length * 2,
    );
  }

  @override
  Stream<BackupRecord> records({required bool includeMedia}) async* {
    // Contacts before handles: a handle names the contact it belongs to, and
    // although the sink resolves the ordering itself, emitting them in
    // dependency order means the common path never has to.
    yield* _page(
      'SELECT * FROM unified_contact ORDER BY id',
      (row) => ContactRecord(
        id: row['id'] as String,
        displayName: (row['display_name'] as String?) ?? '',
        avatarUrl: row['avatar_url'] as String?,
        pinned: (row['pinned'] as int? ?? 0) != 0,
      ),
    );

    yield* _page(
      'SELECT * FROM network_handle ORDER BY id',
      (row) => HandleRecord(
        id: row['id'] as String,
        network: row['network'] as String,
        remoteId: row['remote_id'] as String,
        matrixUserId: row['matrix_user_id'] as String,
        roomId: row['room_id'] as String?,
        displayName: row['display_name'] as String?,
        avatarUrl: row['avatar_url'] as String?,
        phoneE164: row['phone_e164'] as String?,
        email: row['email'] as String?,
        avatarDHash: row['avatar_dhash'] as int?,
        unifiedContactId: row['unified_contact_id'] as String?,
      ),
    );

    yield* _page(
      'SELECT * FROM merge_decision ORDER BY pair',
      (row) => MergeDecisionRecord(
        pair: row['pair'] as String,
        verdict: row['verdict'] as String,
        source: row['source'] as String,
        decidedAt: DateTime.fromMillisecondsSinceEpoch(
          row['decided_at'] as int,
          isUtc: true,
        ),
      ),
    );

    yield* _page(
      'SELECT * FROM chat_prefs ORDER BY chat_id',
      (row) => ChatPrefRecord(
        chatId: row['chat_id'] as String,
        sendNetwork: row['send_network'] as String?,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          row['updated_at'] as int,
          isUtc: true,
        ),
      ),
    );

    yield* _page(
      'SELECT * FROM settings ORDER BY key',
      (row) => kSettingsExcludedFromBackup.contains(row['key'])
          ? null
          : SettingRecord(
              key: row['key'] as String,
              value: row['value'] as String,
            ),
    );

    // Oldest first, so a restore interrupted by something outside the
    // transaction leaves the *beginning* of a conversation rather than its end.
    yield* _pageBy(
      'SELECT * FROM search_message WHERE rowid > ? ORDER BY rowid LIMIT ?',
      (row) => MessageRecord(
        eventId: row['event_id'] as String,
        roomId: row['room_id'] as String,
        chatId: row['chat_id'] as String,
        network: row['network'] as String,
        senderId: row['sender_id'] as String,
        senderName: (row['sender_name'] as String?) ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          row['timestamp'] as int,
          isUtc: true,
        ),
        kind: row['kind'] as String,
        body: row['body'] as String,
        chatTitle: (row['chat_title'] as String?) ?? '',
        hasMedia: (row['has_media'] as int? ?? 0) != 0,
      ),
    );

    yield* _page(
      'SELECT * FROM transcript ORDER BY room_id, event_id',
      (row) => TranscriptRecord(
        eventId: row['event_id'] as String,
        roomId: row['room_id'] as String,
        text: row['text'] as String,
        provider: (row['provider'] as String?) ?? '',
        language: row['language'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at'] as int,
          isUtc: true,
        ),
      ),
    );

    if (!includeMedia) return;

    for (final file in await _mediaFiles()) {
      final hash = await _hashOf(file.file);
      if (hash == null) continue; // Vanished between the listing and the read.

      // Bytes first, reference second. The format requires it: a `media_ref`
      // whose hash has not been seen is skipped, which is exactly what should
      // happen for a reference into an archive written without media.
      yield MediaRecord(
        sha256: hash,
        sizeBytes: file.length,
        openBytes: file.file.openRead,
      );
      yield MediaRefRecord(
        eventId: file.folder,
        sha256: hash,
        fileName: p.basename(file.file.path),
      );
    }
  }

  int _count(String sql) => _raw.select(sql).first['c'] as int;

  /// Streams a whole table in pages, dropping rows the mapper refuses.
  Stream<BackupRecord> _page(
    String sql,
    BackupRecord? Function(Row row) map,
  ) async* {
    // Tables with a text primary key are small enough that a single select is
    // right; only `search_message` needs keyset paging, which [_pageBy] does.
    for (final row in _raw.select(sql)) {
      final record = map(row);
      if (record != null) yield record;
    }
  }

  /// Keyset pagination over `search_message`, which is the one table that can
  /// be enormous.
  ///
  /// By `rowid` rather than `LIMIT/OFFSET`: an offset scan re-walks every row
  /// it has already returned, so exporting 200 000 messages 500 at a time would
  /// be quadratic. `SearchStore.streamVectors` pages the same way for the same
  /// reason.
  Stream<BackupRecord> _pageBy(
    String sql,
    BackupRecord? Function(Row row) map,
  ) async* {
    var after = -1;
    while (true) {
      final rows = _raw.select(sql, [after, _pageSize]);
      if (rows.isEmpty) return;
      for (final row in rows) {
        after = row['rowid'] as int;
        final record = map(row);
        if (record != null) yield record;
      }
      if (rows.length < _pageSize) return;
    }
  }

  /// Every staged attachment, as `<mediaDir>/<folder>/<file>`.
  ///
  /// One level deep and no deeper, because that is the shape `stageAttachment`
  /// writes: a folder per event id, holding one file. `.part` files are skipped
  /// — they are downloads that never finished, and an archive is the wrong
  /// place to preserve a half-file.
  Future<List<_MediaFile>> _mediaFiles() async {
    final directory = _media;
    if (directory == null || !directory.existsSync()) return const [];

    final out = <_MediaFile>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final folder = p.basename(entry.path);
      await for (final child in entry.list(followLinks: false)) {
        if (child is! File) continue;
        if (child.path.endsWith('.part')) continue;
        final length = await child.length();
        if (length == 0) continue;
        out.add(_MediaFile(file: child, folder: folder, length: length));
      }
    }
    out.sort((a, b) => a.file.path.compareTo(b.file.path));
    return out;
  }

  /// [file]'s content hash, or null if it disappeared while being read.
  ///
  /// Streamed rather than read whole: this runs over every attachment the user
  /// has ever opened, and one of them being a film is the ordinary case. Null
  /// rather than a throw because a media directory is live — the SDK's own
  /// retention sweep deletes from it — so a file vanishing between the listing
  /// and the read is normal, and losing one attachment must not lose the
  /// backup.
  Future<String?> _hashOf(File file) async {
    try {
      return await mediaContentHashOfStream(file.openRead());
    } on FileSystemException {
      return null;
    }
  }
}

class _MediaFile {
  const _MediaFile({
    required this.file,
    required this.folder,
    required this.length,
  });

  final File file;

  /// The directory name the file sits in — `stageAttachment`'s sanitised event
  /// id, which is what a restore has to reproduce for the viewer to find it.
  final String folder;

  final int length;
}

/// Writes archive records into Braid's tables and media directory.
///
/// **Merge is `INSERT … ON CONFLICT DO NOTHING`, everywhere.** An existing row
/// wins over the archive's, which is the only choice that makes importing the
/// same file twice a no-op and importing an old backup into a live store safe.
/// The alternative — the archive overwriting — would make restoring a
/// six-month-old backup silently roll back six months of display names, merge
/// verdicts and settings.
class StoreBackupSink implements BackupSink {
  StoreBackupSink({required WeftDatabase database, Directory? mediaDirectory})
    : _db = database,
      _media = mediaDirectory;

  final WeftDatabase _db;
  final Directory? _media;

  Database get _raw => _db.raw;

  /// Content hash to the folder-and-name it was written under, so a
  /// [MediaRefRecord] arriving after its bytes knows where they went.
  final Map<String, String> _mediaPaths = {};

  bool _open = false;

  @override
  Future<void> begin(ImportMode mode) async {
    _raw.execute('BEGIN');
    _open = true;

    if (mode == ImportMode.replace) {
      // Only the tables this archive covers. `search_embedding` and
      // `embedding_queue` cascade from `search_message`; `link_preview` is a
      // cache the archive never carried and so is not the archive's to clear.
      for (final table in const [
        'transcript',
        'search_message',
        'chat_prefs',
        'merge_decision',
        'network_handle',
        'unified_contact',
        'settings',
      ]) {
        _raw.execute('DELETE FROM $table');
      }
    }
  }

  @override
  Future<bool> apply(BackupRecord record) async {
    switch (record) {
      case final ContactRecord r:
        _raw.execute(
          '''
          INSERT INTO unified_contact (id, display_name, avatar_url, pinned)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(id) DO NOTHING
          ''',
          [r.id, r.displayName, r.avatarUrl, r.pinned ? 1 : 0],
        );

      case final HandleRecord r:
        // The foreign key is `ON DELETE SET NULL` but still a foreign key, so
        // the contact has to exist first. A handle whose contact is missing
        // from the archive gets its assignment dropped rather than failing the
        // whole restore — losing one merge beats losing every message.
        final contactId = r.unifiedContactId;
        final hasContact =
            contactId != null &&
            _raw.select('SELECT 1 FROM unified_contact WHERE id = ?', [
              contactId,
            ]).isNotEmpty;
        _raw.execute(
          '''
          INSERT INTO network_handle
            (id, network, remote_id, matrix_user_id, room_id, display_name,
             avatar_url, phone_e164, email, avatar_dhash, unified_contact_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO NOTHING
          ''',
          [
            r.id,
            r.network,
            r.remoteId,
            r.matrixUserId,
            r.roomId,
            r.displayName,
            r.avatarUrl,
            r.phoneE164,
            r.email,
            r.avatarDHash,
            hasContact ? contactId : null,
          ],
        );

      case final MergeDecisionRecord r:
        _raw.execute(
          '''
          INSERT INTO merge_decision (pair, verdict, source, decided_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(pair) DO NOTHING
          ''',
          [r.pair, r.verdict, r.source, r.decidedAt.millisecondsSinceEpoch],
        );

      case final ChatPrefRecord r:
        _raw.execute(
          '''
          INSERT INTO chat_prefs (chat_id, send_network, updated_at)
          VALUES (?, ?, ?)
          ON CONFLICT(chat_id) DO NOTHING
          ''',
          [r.chatId, r.sendNetwork, r.updatedAt.millisecondsSinceEpoch],
        );

      case final SettingRecord r:
        // Filtered on the way in as well as on the way out: an archive written
        // by an older build predates the exclusion list, and the device-scoped
        // keys in it would still be wrong here.
        if (kSettingsExcludedFromBackup.contains(r.key)) return false;
        _raw.execute(
          '''
          INSERT INTO settings (key, value) VALUES (?, ?)
          ON CONFLICT(key) DO NOTHING
          ''',
          [r.key, r.value],
        );

      case final MessageRecord r:
        _raw.execute(
          '''
          INSERT INTO search_message
            (event_id, room_id, chat_id, network, sender_id, timestamp, kind,
             body, has_media, sender_name, chat_title)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(event_id, room_id) DO NOTHING
          ''',
          [
            r.eventId,
            r.roomId,
            r.chatId,
            r.network,
            r.senderId,
            r.timestamp.millisecondsSinceEpoch,
            r.kind,
            r.body,
            r.hasMedia ? 1 : 0,
            r.senderName,
            r.chatTitle,
          ],
        );

      case final TranscriptRecord r:
        _raw.execute(
          '''
          INSERT INTO transcript
            (event_id, room_id, text, provider, language, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(event_id, room_id) DO NOTHING
          ''',
          [
            r.eventId,
            r.roomId,
            r.text,
            r.provider,
            r.language,
            r.createdAt.millisecondsSinceEpoch,
          ],
        );

      case final MediaRefRecord r:
        // A reference into media the archive did not carry — because it was
        // exported without media, or because the bytes were skipped as already
        // present. Neither is an error and neither may corrupt the message that
        // references it: the row stays, the file simply is not there, and the
        // viewer re-downloads it the way it would for any attachment it has not
        // staged yet.
        final directory = _media;
        if (directory == null) return false;
        final source = _mediaPaths[r.sha256];
        if (source == null) return false;
        return _linkMedia(directory, source, r);

      case MediaRecord():
      case UnknownRecord():
        // Media bytes go through [beginMedia]; unknown types are counted by
        // `importArchive` and never reach here.
        return false;
    }

    return _raw.updatedRows > 0;
  }

  @override
  Future<MediaWriter?> beginMedia(String sha256, int sizeBytes) async {
    final directory = _media;
    if (directory == null) return null;

    // Content-addressed staging, so the same photo arriving twice in one
    // archive costs one write — and so a restore that is re-run does not
    // re-download what it already has.
    final staged = File(p.join(directory.path, '.restore', sha256));
    _mediaPaths[sha256] = staged.path;
    if (staged.existsSync() && await staged.length() == sizeBytes) return null;

    await staged.parent.create(recursive: true);
    return _FileMediaWriter(staged);
  }

  /// Puts the staged bytes where the viewer expects to find them.
  ///
  /// A copy rather than a rename, because one blob can serve several events —
  /// the same photo forwarded into four chats — and the staging file has to
  /// survive to serve the next reference.
  bool _linkMedia(Directory root, String stagedPath, MediaRefRecord ref) {
    // Sanitised again on the way in. The writer sanitised these, but an archive
    // is an untrusted file: `../../` in either component would otherwise decide
    // where a restore writes.
    final folder = _sanitise(ref.eventId);
    final name = _sanitise(p.basename(ref.fileName));
    final target = File(p.join(root.path, folder, name));

    if (target.existsSync() && target.lengthSync() > 0) return false;

    final staged = File(stagedPath);
    if (!staged.existsSync()) return false;

    target.parent.createSync(recursive: true);
    staged.copySync(target.path);
    return true;
  }

  @override
  Future<void> commit() async {
    // Restored messages have an FTS row — the `search_message_ai` trigger sees
    // to that — but no embedding and no place in the queue, because nothing
    // called `SearchStore.indexMessage`. Without this, semantic search silently
    // has a hole in it exactly where the restored history is, and nothing ever
    // notices.
    _raw.execute(
      '''
      INSERT OR IGNORE INTO embedding_queue (message_rowid, enqueued_at)
      SELECT rowid, ? FROM search_message
      WHERE rowid NOT IN (SELECT message_rowid FROM search_embedding)
      ''',
      [DateTime.now().millisecondsSinceEpoch],
    );

    _raw.execute('COMMIT');
    _open = false;
    await _clearStaging();
  }

  @override
  Future<void> rollback() async {
    if (_open) {
      _raw.execute('ROLLBACK');
      _open = false;
    }
    // Files are not in the transaction, so the staging directory is swept by
    // hand. What it holds is content-addressed and referenced by nothing, so
    // dropping it leaves no dangling row — which is the whole reason media is
    // staged under a hash before it is placed.
    await _clearStaging();
  }

  Future<void> _clearStaging() async {
    _mediaPaths.clear();
    final directory = _media;
    if (directory == null) return;
    final staging = Directory(p.join(directory.path, '.restore'));
    if (!staging.existsSync()) return;
    try {
      await staging.delete(recursive: true);
    } on FileSystemException {
      // Untidy rather than broken. Reporting this would replace a successful
      // restore with a failure over a directory nothing reads.
    }
  }
}

class _FileMediaWriter implements MediaWriter {
  _FileMediaWriter(this._target);

  final File _target;
  IOSink? _sink;

  IOSink get _open => _sink ??= _target.openWrite();

  @override
  Future<void> add(List<int> bytes) async => _open.add(bytes);

  @override
  Future<void> finish() async {
    await _open.flush();
    await _open.close();
    _sink = null;
  }

  @override
  Future<void> abort() async {
    try {
      await _sink?.close();
    } on FileSystemException {
      // Already gone.
    }
    _sink = null;
    if (_target.existsSync()) {
      try {
        await _target.delete();
      } on FileSystemException {
        // Best effort; the content is addressed by hash and referenced by
        // nothing, so what is left behind is inert.
      }
    }
  }
}

/// Everything a file system might object to, flattened to `_`.
///
/// The same rule `media_store.dart` applies on the way out, applied again on
/// the way in. Duplicated rather than shared because the two live either side
/// of a package boundary that points the wrong way — `weft_store` cannot depend
/// on the app — and because the *reason* differs: there it is about sender
/// input, here it is about an untrusted archive.
String _sanitise(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return cleaned.isEmpty ? 'attachment' : cleaned;
}
