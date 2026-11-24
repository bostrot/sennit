import 'package:sqflite_common/sqlite_api.dart';

export 'package:sqflite_common/sqlite_api.dart'
    show Database, inMemoryDatabasePath;

/// The browser build holds no Matrix session of its own, so it never opens the
/// SDK's database. Reaching this is a wiring mistake, said loudly.
Future<Database> openWeftSqfliteDatabase(String path) =>
    throw UnsupportedError('The browser build has no Matrix database');
