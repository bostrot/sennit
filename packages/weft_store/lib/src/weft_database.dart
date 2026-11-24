import 'package:sqlite3/common.dart';

import 'migrations.dart';
import 'sqlite_native.dart' if (dart.library.js_interop) 'sqlite_web.dart';

/// Weft's own database, separate from the Matrix SDK's.
///
/// The SDK owns protocol state — rooms, events, keys. This owns everything
/// Weft adds on top: the identity graph, per-chat preferences, settings, and
/// the search index. Keeping them apart means a Matrix SDK upgrade that
/// rebuilds its schema never takes the user's merge decisions with it.
class WeftDatabase {
  WeftDatabase._(this.raw, this.path);

  final CommonDatabase raw;

  /// File path, or `:memory:`.
  final String path;

  /// Opens the app's database in the platform's support directory.
  static Future<WeftDatabase> open({String? directoryOverride}) async {
    await loadSqlite();
    return WeftDatabase.openAt(
      directoryOverride != null
          ? databasePathIn(directoryOverride)
          : await defaultDatabasePath(),
    );
  }

  /// Loads the SQLite engine where it is not linked in — the browser build,
  /// which fetches it as WebAssembly. A no-op everywhere else. [openAt] needs
  /// it to have finished.
  static Future<void> loadEngine() => loadSqlite();

  /// Opens (or creates) a database at [path]. Pass `:memory:` for tests.
  factory WeftDatabase.openAt(String path) {
    final db = openSqlite(path);

    // WAL lets the UI read while a backfill writes. Meaningless in memory, and
    // sqlite refuses it there, so it is skipped.
    if (path != ':memory:') db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA busy_timeout = 5000');

    migrate(db);
    return WeftDatabase._(db, path);
  }

  int get schemaVersion =>
      raw.select('PRAGMA user_version').first.values.first! as int;

  /// Runs [action] in a transaction, rolling back if it throws.
  T transaction<T>(T Function() action) {
    raw.execute('BEGIN');
    try {
      final result = action();
      raw.execute('COMMIT');
      return result;
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Deletes every row this database holds and leaves the schema as it is,
  /// so the app carries on against an empty database as it would after a
  /// fresh install.
  ///
  /// Rows rather than the file because the file is open — the app's stores
  /// hold it for the whole run. The `VACUUM` afterwards is the part that makes
  /// it a wipe: sqlite only marks deleted pages free, and until they are
  /// rewritten the messages in the search index are still in the file.
  void wipe() {
    final tables = raw.select(
      "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%'",
    );
    final virtual = [
      for (final row in tables)
        if ((row['sql'] as String? ?? '').toUpperCase().startsWith(
          'CREATE VIRTUAL',
        ))
          row['name'] as String,
    ];
    // A virtual table keeps its data in shadow tables named after it, which
    // only the module that owns them may write.
    bool shadow(String name) =>
        virtual.any((table) => name.startsWith('${table}_'));

    transaction(() {
      for (final row in tables) {
        final name = row['name'] as String;
        if (virtual.contains(name) || shadow(name)) continue;
        raw.execute('DELETE FROM "$name"');
      }
      // The search index is an external-content FTS table over a table that is
      // now empty; rebuilding it from that leaves nothing behind.
      for (final name in virtual) {
        raw.execute('INSERT INTO "$name"("$name") VALUES (\'rebuild\')');
      }
    });
    raw.execute('VACUUM');
    if (path != ':memory:') raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  void dispose() => raw.close();
}
