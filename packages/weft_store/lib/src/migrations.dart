import 'package:sqlite3/common.dart';

/// Ordered schema migrations.
///
/// Each entry is applied once, in order, inside a transaction, and
/// `PRAGMA user_version` records how far we got. **Never edit or reorder an
/// existing migration** — that would leave already-migrated installs on a
/// schema nothing else agrees with. Append a new one instead.
const List<String> weftMigrations = [
  // ---------------------------------------------------------------- v1
  '''
  -- One human, across every network they appear on.
  CREATE TABLE unified_contact (
    id           TEXT PRIMARY KEY,
    display_name TEXT NOT NULL DEFAULT '',
    avatar_url   TEXT,
    pinned       INTEGER NOT NULL DEFAULT 0
  );

  -- One person as they exist on one network.
  CREATE TABLE network_handle (
    id                 TEXT PRIMARY KEY,
    network            TEXT NOT NULL,
    remote_id          TEXT NOT NULL,
    matrix_user_id     TEXT NOT NULL,
    room_id            TEXT,
    display_name       TEXT,
    avatar_url         TEXT,
    phone_e164         TEXT,
    email              TEXT,
    avatar_dhash       INTEGER,
    unified_contact_id TEXT REFERENCES unified_contact(id) ON DELETE SET NULL
  );
  CREATE INDEX idx_handle_contact ON network_handle(unified_contact_id);
  CREATE INDEX idx_handle_room    ON network_handle(room_id);

  -- Sticky user verdicts. These always beat the scorer's heuristics, which is
  -- why an unmerge has to survive a restart.
  CREATE TABLE merge_decision (
    pair       TEXT PRIMARY KEY,
    verdict    TEXT NOT NULL,
    source     TEXT NOT NULL,
    decided_at INTEGER NOT NULL
  );

  -- Per-chat preferences that are Weft's, not Matrix's.
  CREATE TABLE chat_prefs (
    chat_id       TEXT PRIMARY KEY,
    send_network  TEXT,
    updated_at    INTEGER NOT NULL
  );

  CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );
  ''',

  // ---------------------------------------------------------------- v2
  '''
  -- Keyword half of hybrid search. `content=''` makes this a contentless FTS5
  -- table: the text is not stored twice, and rowid maps back to search_message.
  CREATE TABLE search_message (
    rowid      INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id   TEXT NOT NULL,
    room_id    TEXT NOT NULL,
    chat_id    TEXT NOT NULL,
    network    TEXT NOT NULL,
    sender_id  TEXT NOT NULL,
    timestamp  INTEGER NOT NULL,
    kind       TEXT NOT NULL,
    body       TEXT NOT NULL,
    has_media  INTEGER NOT NULL DEFAULT 0,
    UNIQUE(event_id, room_id)
  );
  CREATE INDEX idx_search_chat ON search_message(chat_id, timestamp DESC);
  CREATE INDEX idx_search_ts   ON search_message(timestamp DESC);

  CREATE VIRTUAL TABLE search_fts USING fts5(
    body,
    content='search_message',
    content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
  );

  -- Keep the index in step with the table without any application code
  -- remembering to. A contentless FTS5 table needs the delete row spelled out.
  CREATE TRIGGER search_message_ai AFTER INSERT ON search_message BEGIN
    INSERT INTO search_fts(rowid, body) VALUES (new.rowid, new.body);
  END;
  CREATE TRIGGER search_message_ad AFTER DELETE ON search_message BEGIN
    INSERT INTO search_fts(search_fts, rowid, body) VALUES ('delete', old.rowid, old.body);
  END;
  CREATE TRIGGER search_message_au AFTER UPDATE ON search_message BEGIN
    INSERT INTO search_fts(search_fts, rowid, body) VALUES ('delete', old.rowid, old.body);
    INSERT INTO search_fts(rowid, body) VALUES (new.rowid, new.body);
  END;

  -- Vector half. Stored as a float32 blob alongside the row it describes;
  -- the ANN index is built over these at query time.
  CREATE TABLE search_embedding (
    message_rowid INTEGER PRIMARY KEY
                  REFERENCES search_message(rowid) ON DELETE CASCADE,
    model         TEXT NOT NULL,
    dimensions    INTEGER NOT NULL,
    vector        BLOB NOT NULL
  );

  -- Durable work queue, so a backfill survives a crash or a lost connection
  -- and never silently drops a message from the index.
  CREATE TABLE embedding_queue (
    message_rowid INTEGER PRIMARY KEY
                  REFERENCES search_message(rowid) ON DELETE CASCADE,
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    enqueued_at   INTEGER NOT NULL
  );
  ''',

  // ---------------------------------------------------------------- v3
  '''
  -- Searching only message bodies meant typing a person's name found nothing
  -- unless they had said their own name. Sender and chat titles now sit
  -- alongside the body in the index.
  ALTER TABLE search_message ADD COLUMN sender_name TEXT NOT NULL DEFAULT '';
  ALTER TABLE search_message ADD COLUMN chat_title  TEXT NOT NULL DEFAULT '';

  -- An FTS5 table's columns are fixed at creation, so widening the index means
  -- rebuilding it. Triggers go first: they reference the old shape.
  DROP TRIGGER IF EXISTS search_message_ai;
  DROP TRIGGER IF EXISTS search_message_ad;
  DROP TRIGGER IF EXISTS search_message_au;
  DROP TABLE IF EXISTS search_fts;

  CREATE VIRTUAL TABLE search_fts USING fts5(
    body,
    sender_name,
    chat_title,
    content='search_message',
    content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
  );

  CREATE TRIGGER search_message_ai AFTER INSERT ON search_message BEGIN
    INSERT INTO search_fts(rowid, body, sender_name, chat_title)
    VALUES (new.rowid, new.body, new.sender_name, new.chat_title);
  END;
  CREATE TRIGGER search_message_ad AFTER DELETE ON search_message BEGIN
    INSERT INTO search_fts(search_fts, rowid, body, sender_name, chat_title)
    VALUES ('delete', old.rowid, old.body, old.sender_name, old.chat_title);
  END;
  CREATE TRIGGER search_message_au AFTER UPDATE ON search_message BEGIN
    INSERT INTO search_fts(search_fts, rowid, body, sender_name, chat_title)
    VALUES ('delete', old.rowid, old.body, old.sender_name, old.chat_title);
    INSERT INTO search_fts(rowid, body, sender_name, chat_title)
    VALUES (new.rowid, new.body, new.sender_name, new.chat_title);
  END;

  -- Repopulate from the rows that already exist, so an upgrade does not lose
  -- the index the user already built.
  INSERT INTO search_fts(rowid, body, sender_name, chat_title)
  SELECT rowid, body, sender_name, chat_title FROM search_message;
  ''',

  // ---------------------------------------------------------------- v4
  '''
  -- Link previews, as the homeserver answered them.
  --
  -- One JSON column rather than a column per OpenGraph field, for the same
  -- reason the notification policy is one blob: the shape is the *server's*,
  -- it is read and written as a unit, and `LinkPreview.fromJson` already
  -- degrades field by field — so a row written by a newer build loses the
  -- fields this one does not know about and keeps the rest.
  --
  -- A null `preview` is a real answer and not a missing row: it records that
  -- the homeserver was asked and had nothing. Without it, every scroll past a
  -- bare url re-asks a question already answered, which is both a request the
  -- user did not make and a second chance to leak that they were sent it.
  CREATE TABLE link_preview (
    url        TEXT PRIMARY KEY,
    preview    TEXT,
    fetched_at INTEGER NOT NULL
  );
  CREATE INDEX idx_link_preview_fetched ON link_preview(fetched_at);
  ''',

  // ---------------------------------------------------------------- v5
  '''
  -- Finished voice transcriptions.
  --
  -- Transcribing costs seconds of on-device inference or a metered endpoint
  -- call, and the result used to live in a per-session map — closing the app
  -- threw the work away and the bubble went back to "Transcribe". A row here
  -- is the transcript's home; the search index carries a *copy* for FTS and
  -- embeddings, re-planted on startup for any message the index has not seen.
  CREATE TABLE transcript (
    event_id   TEXT NOT NULL,
    room_id    TEXT NOT NULL,
    text       TEXT NOT NULL,
    provider   TEXT NOT NULL DEFAULT '',
    language   TEXT,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (event_id, room_id)
  );
  ''',

  // ---------------------------------------------------------------- v6
  '''
  -- The two things a self-deleting chat has to remember. The *policy* is not
  -- among them: it lives in `settings` under `privacy.retention`, as one blob
  -- read and written whole, which is also what carries it into a backup.
  --
  -- When the user last read a conversation, and how far.
  --
  -- One row per read rather than a single moving stamp, because the question a
  -- read-anchored policy asks is per message: "when was the conversation first
  -- read past *this* one". A single latest stamp answers that wrongly for
  -- everything below it — a message read a week ago would restart its hour
  -- every time the chat is opened, and would never expire in an active chat.
  --
  -- Rows are pruned by the sweeper once nothing they cover can still be alive,
  -- so an install that reads one chat every day does not accumulate a row a day
  -- forever. See `RetentionStore.pruneReadMarks`.
  CREATE TABLE chat_read_mark (
    chat_id  TEXT NOT NULL,
    read_at  INTEGER NOT NULL,
    up_to_ms INTEGER NOT NULL,
    PRIMARY KEY (chat_id, read_at)
  );
  CREATE INDEX idx_read_mark_chat ON chat_read_mark(chat_id, up_to_ms);

  -- Events this device has deleted and must not show again.
  --
  -- A tombstone rather than trust in the deletion itself, because deleting a
  -- message from the Matrix SDK's local database does not stop the homeserver
  -- from serving it back on the next backfill — and Sennit's own indexer would
  -- then re-file a message the user was told had gone. Deliberately *not* in a
  -- backup: it is a fact about one device's copy, and a restore onto a fresh
  -- device re-syncs from the server regardless.
  CREATE TABLE purged_event (
    room_id   TEXT NOT NULL,
    event_id  TEXT NOT NULL,
    purged_at INTEGER NOT NULL,
    PRIMARY KEY (room_id, event_id)
  );
  CREATE INDEX idx_purged_room ON purged_event(room_id);
  ''',

  // ---------------------------------------------------------------- v7
  '''
  -- What this device last shared with its other devices, per sync key — see
  -- `reconcile` in weft_sync. `observed` is the local value as last seen,
  -- which is how an edit is found by comparison rather than by a hook in every
  -- place that writes a setting. Not in a backup: it describes this device's
  -- conversation with the others, and a restored device starts that afresh.
  CREATE TABLE sync_state (
    key      TEXT PRIMARY KEY,
    value    TEXT,
    hlc      TEXT NOT NULL,
    observed TEXT,
    tracked  INTEGER NOT NULL
  );
  ''',
];

/// Applies any migrations the database has not seen yet.
///
/// Returns the version it ended on. Idempotent: running it against an
/// up-to-date database does nothing.
int migrate(CommonDatabase db, {List<String> migrations = weftMigrations}) {
  db.execute('PRAGMA foreign_keys = ON');

  final current = db.select('PRAGMA user_version').first.values.first! as int;
  if (current >= migrations.length) return current;

  for (var version = current; version < migrations.length; version++) {
    db.execute('BEGIN');
    try {
      db.execute(migrations[version]);
      // user_version does not accept a bound parameter.
      db.execute('PRAGMA user_version = ${version + 1}');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  return migrations.length;
}
