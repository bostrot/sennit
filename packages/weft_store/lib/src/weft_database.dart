import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'migrations.dart';

/// Weft's own database, separate from the Matrix SDK's.
///
/// The SDK owns protocol state — rooms, events, keys. This owns everything
/// Weft adds on top: the identity graph, per-chat preferences, settings, and
/// the search index. Keeping them apart means a Matrix SDK upgrade that
/// rebuilds its schema never takes the user's merge decisions with it.
class WeftDatabase {
  WeftDatabase._(this.raw, this.path);

  final Database raw;

  /// File path, or `:memory:`.
  final String path;

  /// Opens the app's database in the platform's support directory.
  static Future<WeftDatabase> open({String? directoryOverride}) async {
    final directory =
        directoryOverride ??
        p.join((await getApplicationSupportDirectory()).path, 'weft');
    final dir = Directory(directory);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    return WeftDatabase.openAt(p.join(directory, 'weft.db'));
  }

  /// Opens (or creates) a database at [path]. Pass `:memory:` for tests.
  factory WeftDatabase.openAt(String path) {
    final db = sqlite3.open(path);

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

  void dispose() => raw.close();
}
