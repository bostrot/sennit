import 'package:sqlite3/sqlite3.dart';

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
];

/// Applies any migrations the database has not seen yet.
///
/// Returns the version it ended on. Idempotent: running it against an
/// up-to-date database does nothing.
int migrate(Database db, {List<String> migrations = weftMigrations}) {
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
