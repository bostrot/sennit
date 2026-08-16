import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Re-exported so callers (notably tests) don't need their own sqflite
/// dependency just to name a database path.
export 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show Database, inMemoryDatabasePath;

/// Opens the sqflite database that backs `MatrixSdkDatabase`.
///
/// The SDK requires a database to be supplied explicitly on native platforms —
/// `MatrixSdkDatabase.init` throws "You must provide a Database
/// `sqfliteDatabase` for use on native" otherwise.
///
/// The ffi factory is used on every platform rather than the sqflite plugin on
/// mobile and ffi on desktop. It depends only on `package:sqlite3`, whose 3.x
/// releases bundle their own natives through Dart build hooks, so all five
/// targets take one code path with no per-platform plugin registration.
///
/// Pass `:memory:` as [path] for a throwaway database in tests.
Future<Database> openWeftSqfliteDatabase(String path) async {
  // Idempotent, and cheap enough to call on every open.
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(path);
}
