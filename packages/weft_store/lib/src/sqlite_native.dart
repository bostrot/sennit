import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

/// The native engine, linked through the package's build hooks.
CommonDatabase openSqlite(String path) => sqlite3.open(path);

/// Nothing to load: the engine is part of the binary.
Future<void> loadSqlite() async {}

/// The database file inside the app's support directory, created if missing.
Future<String> defaultDatabasePath() async {
  final directory = p.join(
    (await getApplicationSupportDirectory()).path,
    'weft',
  );
  final dir = Directory(directory);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return p.join(directory, 'weft.db');
}

/// The given directory's database file, created if missing.
String databasePathIn(String directory) {
  final dir = Directory(directory);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return p.join(directory, 'weft.db');
}
