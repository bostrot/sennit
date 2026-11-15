import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';
import 'package:weft_search/weft_search.dart';

import 'weft_database.dart';

/// SQLite-backed [SearchBackend], plus the write side of the index.
class SearchStore implements SearchBackend {
  SearchStore(this._db);

  final WeftDatabase _db;

  Database get _raw => _db.raw;

  // -------------------------------------------------------------- indexing

  /// Adds or refreshes a message in the index and queues it for embedding.
  ///
  /// Returns the index row id. Idempotent per (eventId, roomId): re-indexing an
  /// edited message replaces the old text rather than duplicating the row.
  ///
  /// What is stored is the message's *visible* text, not the markup it was
  /// written in: [plainTextOf] runs the body through the same allowlist the
  /// bubble renders. Indexing a formatted body raw is wrong twice over — it
  /// makes `<b>fire</b>` unfindable by "fire" while making every formatted
  /// message findable by "strong" and "href", and it puts the contents of a
  /// `<script>` the reader was never shown into the column the search screen
  /// prints back as a snippet.
  ///
  /// The projection happens here rather than at the call sites because this is
  /// the one door into the index: the FTS row and the embedding queued below
  /// both come off this column, so a writer that forgot to project would poison
  /// keyword and semantic search together.
  int indexMessage(
    WeftMessage message, {
    required String chatId,
    String chatTitle = '',
  }) {
    final writer = _IndexWriter(_raw);
    try {
      return writer.write(message, chatId: chatId, chatTitle: chatTitle);
    } finally {
      writer.dispose();
    }
  }

  void indexMessages(
    Iterable<WeftMessage> messages, {
    required String chatId,
    String chatTitle = '',
  }) {
    final writer = _IndexWriter(_raw);
    try {
      _db.transaction(() {
        for (final message in messages) {
          writer.write(message, chatId: chatId, chatTitle: chatTitle);
        }
      });
    } finally {
      writer.dispose();
    }
  }

  void removeMessage({required String eventId, required String roomId}) {
    _raw.execute(
      'DELETE FROM search_message WHERE event_id = ? AND room_id = ?',
      [eventId, roomId],
    );
  }

  int get indexedCount =>
      _raw.select('SELECT COUNT(*) AS c FROM search_message').first['c'] as int;

  int get pendingEmbeddingCount =>
      _raw.select('SELECT COUNT(*) AS c FROM embedding_queue').first['c']
          as int;

  // ------------------------------------------------------------- embeddings

  /// Next batch awaiting an embedding, oldest first.
  ///
  /// Rows that have failed repeatedly sort last so one poison message cannot
  /// stall the whole backfill behind it.
  List<({int rowId, String body})> nextEmbeddingBatch({int limit = 32}) {
    return _raw
        .select(
          '''
          SELECT q.message_rowid AS rowid, m.body AS body
          FROM embedding_queue q
          JOIN search_message m ON m.rowid = q.message_rowid
          WHERE q.attempts < 5
          ORDER BY q.attempts ASC, q.enqueued_at ASC
          LIMIT ?
          ''',
          [limit],
        )
        .map((row) => (rowId: row['rowid'] as int, body: row['body'] as String))
        .toList(growable: false);
  }

  void saveEmbedding({
    required int rowId,
    required Int8List vector,
    required String model,
  }) {
    _raw.execute(
      '''
      INSERT INTO search_embedding (message_rowid, model, dimensions, vector)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(message_rowid) DO UPDATE SET
        model      = excluded.model,
        dimensions = excluded.dimensions,
        vector     = excluded.vector
      ''',
      [rowId, model, vector.length, encodeVector(vector)],
    );
    _raw.execute('DELETE FROM embedding_queue WHERE message_rowid = ?', [
      rowId,
    ]);
  }

  void recordEmbeddingFailure(int rowId, String error) {
    _raw.execute(
      '''
      UPDATE embedding_queue
      SET attempts = attempts + 1, last_error = ?
      WHERE message_rowid = ?
      ''',
      [error, rowId],
    );
  }

  /// Drops every vector and re-queues everything.
  ///
  /// Required after an embedding-model change: vectors from different models
  /// share no coordinate space, so mixing them silently ruins ranking.
  void reindexEmbeddings() {
    _db.transaction(() {
      _raw.execute('DELETE FROM search_embedding');
      // Cleared rather than upserted: `INSERT … SELECT … ON CONFLICT` is a
      // parse error in SQLite without a disambiguating WHERE, and starting
      // from an empty queue is what a reindex means anyway.
      _raw.execute('DELETE FROM embedding_queue');
      _raw.execute(
        '''
        INSERT INTO embedding_queue (message_rowid, enqueued_at)
        SELECT rowid, ? FROM search_message
        ''',
        [DateTime.now().millisecondsSinceEpoch],
      );
    });
  }

  @override
  Stream<StoredVector> streamVectors() async* {
    // Paged by primary key so a large index never lands in memory at once.
    const pageSize = 512;
    var after = -1;

    while (true) {
      final rows = _raw.select(
        '''
        SELECT message_rowid, vector FROM search_embedding
        WHERE message_rowid > ?
        ORDER BY message_rowid
        LIMIT ?
        ''',
        [after, pageSize],
      );
      if (rows.isEmpty) return;

      for (final row in rows) {
        after = row['message_rowid'] as int;
        yield (
          messageRowId: after,
          vector: decodeVector(row['vector'] as Uint8List),
        );
      }
    }
  }

  // ---------------------------------------------------------------- queries

  @override
  Future<List<RankedHit>> keywordSearch(
    String query, {
    int limit = 200,
    Set<int>? restrictTo,
  }) async {
    final match = toFtsMatchQuery(query);
    if (match == null) return const [];

    // bm25() is negative, better matches more so; negate to get a score where
    // larger is better, matching the rest of the ranking pipeline.
    final rows = _raw.select(
      '''
      SELECT rowid, -bm25(search_fts) AS score
      FROM search_fts
      WHERE search_fts MATCH ?
      ORDER BY bm25(search_fts)
      LIMIT ?
      ''',
      [match, limit],
    );

    final hits = <RankedHit>[];
    for (final row in rows) {
      final id = row['rowid'] as int;
      if (restrictTo != null && !restrictTo.contains(id)) continue;
      hits.add(RankedHit(id: id, score: (row['score'] as num).toDouble()));
    }
    return hits;
  }

  @override
  Future<Set<int>?> candidateRowIds(SearchQuery query) async {
    if (!query.hasFilters) return null;

    final where = <String>[];
    final args = <Object?>[];

    if (query.networks.isNotEmpty) {
      where.add(
        'network IN (${List.filled(query.networks.length, '?').join(',')})',
      );
      args.addAll(query.networks.map((n) => n.id));
    }
    if (query.chatIds.isNotEmpty) {
      where.add(
        'chat_id IN (${List.filled(query.chatIds.length, '?').join(',')})',
      );
      args.addAll(query.chatIds);
    }
    if (query.senderIds.isNotEmpty) {
      where.add(
        'sender_id IN (${List.filled(query.senderIds.length, '?').join(',')})',
      );
      args.addAll(query.senderIds);
    }
    if (query.after != null) {
      where.add('timestamp >= ?');
      args.add(query.after!.millisecondsSinceEpoch);
    }
    if (query.before != null) {
      where.add('timestamp <= ?');
      args.add(query.before!.millisecondsSinceEpoch);
    }
    if (query.hasMedia != null) {
      where.add('has_media = ?');
      args.add(query.hasMedia! ? 1 : 0);
    }

    // A filters-only browse should still be bounded and newest-first.
    final rows = _raw.select(
      '''
      SELECT rowid FROM search_message
      WHERE ${where.join(' AND ')}
      ORDER BY timestamp DESC
      LIMIT ?
      ''',
      [...args, query.text.trim().isEmpty ? query.limit : 5000],
    );
    return rows.map((r) => r['rowid'] as int).toSet();
  }

  @override
  Future<List<SearchResult>> hydrate(
    List<FusedHit> hits,
    String queryText,
  ) async {
    if (hits.isEmpty) return const [];

    final byId = {for (final hit in hits) hit.id: hit};
    final placeholders = List.filled(hits.length, '?').join(',');
    final rows = _raw.select(
      'SELECT * FROM search_message WHERE rowid IN ($placeholders)',
      byId.keys.toList(),
    );

    final results = <int, SearchResult>{};
    for (final row in rows) {
      final id = row['rowid'] as int;
      final hit = byId[id]!;
      results[id] = SearchResult(
        eventId: row['event_id'] as String,
        roomId: row['room_id'] as String,
        chatId: row['chat_id'] as String,
        network: ChatNetwork.fromId(row['network'] as String),
        senderId: row['sender_id'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
        kind: MessageKind.values.firstWhere(
          (k) => k.name == row['kind'],
          orElse: () => MessageKind.text,
        ),
        body: row['body'] as String,
        senderName: (row['sender_name'] as String?) ?? '',
        chatTitle: (row['chat_title'] as String?) ?? '',
        score: hit.score,
        matchedKeyword: hit.keywordRank != null,
        matchedSemantic: hit.vectorRank != null,
      );
    }

    // Preserve fusion order; drop ids whose row vanished mid-query.
    return hits
        .map((hit) => results[hit.id])
        .whereType<SearchResult>()
        .toList(growable: false);
  }
}

/// Converts free text into a safe FTS5 MATCH expression.
///
/// User input goes straight into FTS5's own query language, where a stray
/// quote, `*`, `NOT` or `:` is a syntax error that would surface as a crash
/// mid-typing. Every token is therefore quoted and combined with implicit AND.
/// A trailing `*` is added to the last token so results narrow as the user
/// types rather than appearing only on word boundaries.
///
/// Returns null when nothing searchable remains.
String? toFtsMatchQuery(String input, {bool prefixLastToken = true}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  // An explicitly quoted string is a phrase search; keep it as one token.
  if (trimmed.length > 1 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    final phrase = trimmed.substring(1, trimmed.length - 1).replaceAll('"', '');
    return phrase.trim().isEmpty ? null : '"$phrase"';
  }

  final tokens = trimmed
      .split(RegExp(r'\s+'))
      // Strip everything FTS5 treats as syntax, leaving letters, digits and
      // marks. Keeping any of it would let input become an operator.
      .map((t) => t.replaceAll(RegExp(r'''["'*(){}\[\]:^\-+,.;!?~/\\]'''), ''))
      .where((t) => t.isNotEmpty)
      .toList();

  if (tokens.isEmpty) return null;

  final quoted = <String>[];
  for (var i = 0; i < tokens.length; i++) {
    final isLast = i == tokens.length - 1;
    quoted.add(
      prefixLastToken && isLast ? '"${tokens[i]}"*' : '"${tokens[i]}"',
    );
  }
  return quoted.join(' ');
}

/// The statements one pass of indexing runs, prepared once for the pass.
///
/// The chat view files every message it has loaded, and it has loaded most of
/// them before: reopening a conversation hands back the same page it indexed
/// on the last visit. Written unconditionally, each of those was an upsert
/// that re-fired the FTS triggers, a deleted embedding and a fresh place in
/// the embedding queue — so every visit to a conversation re-embedded it from
/// the top, on a device that was trying to scroll. And each of the four
/// statements per message was compiled again for each message.
///
/// So the row is read first. Unchanged, it is left exactly as it is; changed
/// only in what it is filed under, it is re-filed and keeps its embedding;
/// only new or reworded text is embedded again.
class _IndexWriter {
  _IndexWriter(Database db)
    : _existing = db.prepare(
        'SELECT rowid, chat_id, kind, body, has_media, sender_name, chat_title '
        'FROM search_message WHERE event_id = ? AND room_id = ?',
      ),
      _upsert = db.prepare('''
        INSERT INTO search_message
          (event_id, room_id, chat_id, network, sender_id, timestamp, kind,
           body, has_media, sender_name, chat_title)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(event_id, room_id) DO UPDATE SET
          chat_id     = excluded.chat_id,
          body        = excluded.body,
          kind        = excluded.kind,
          has_media   = excluded.has_media,
          sender_name = excluded.sender_name,
          chat_title  = excluded.chat_title
      '''),
      _dropEmbedding = db.prepare(
        'DELETE FROM search_embedding WHERE message_rowid = ?',
      ),
      _enqueue = db.prepare('''
        INSERT INTO embedding_queue (message_rowid, enqueued_at) VALUES (?, ?)
        ON CONFLICT(message_rowid) DO UPDATE SET
          attempts    = 0,
          last_error  = NULL,
          enqueued_at = excluded.enqueued_at
      '''),
      _enqueueIfMissing = db.prepare('''
        INSERT INTO embedding_queue (message_rowid, enqueued_at)
        SELECT ?1, ?2
        WHERE NOT EXISTS
          (SELECT 1 FROM search_embedding WHERE message_rowid = ?1)
        ON CONFLICT(message_rowid) DO NOTHING
      ''');

  final PreparedStatement _existing;
  final PreparedStatement _upsert;
  final PreparedStatement _dropEmbedding;
  final PreparedStatement _enqueue;
  final PreparedStatement _enqueueIfMissing;

  int write(
    WeftMessage message, {
    required String chatId,
    required String chatTitle,
  }) {
    final text = plainTextOf(message);
    final hasMedia = message.attachmentUrl != null ? 1 : 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    final rows = _existing.select([message.eventId, message.roomId]);
    final row = rows.isEmpty ? null : rows.first;
    final sameText = row != null && row['body'] == text;

    if (sameText &&
        row['chat_id'] == chatId &&
        row['kind'] == message.kind.name &&
        row['has_media'] == hasMedia &&
        row['sender_name'] == message.senderName &&
        row['chat_title'] == chatTitle) {
      final rowId = row['rowid'] as int;
      // Nothing to write — but a row that was never embedded, because the
      // model arrived after the message did, still gets its turn. A row
      // already waiting keeps its place and its attempt count.
      _enqueueIfMissing.execute([rowId, now]);
      return rowId;
    }

    _upsert.execute([
      message.eventId,
      message.roomId,
      chatId,
      message.network.id,
      message.senderId,
      message.timestamp.millisecondsSinceEpoch,
      message.kind.name,
      text,
      hasMedia,
      message.senderName,
      chatTitle,
    ]);
    // Asked rather than taken from `last_insert_rowid`, which an update does
    // not move and the FTS triggers do.
    final rowId =
        row?['rowid'] as int? ??
        _existing.select([message.eventId, message.roomId]).first['rowid']
            as int;

    if (sameText) {
      // Re-filed under a new chat or title; the words, and so the vector, are
      // the ones already stored.
      _enqueueIfMissing.execute([rowId, now]);
      return rowId;
    }

    _dropEmbedding.execute([rowId]);
    _enqueue.execute([rowId, now]);
    return rowId;
  }

  void dispose() {
    _existing.close();
    _upsert.close();
    _dropEmbedding.close();
    _enqueue.close();
    _enqueueIfMissing.close();
  }
}
