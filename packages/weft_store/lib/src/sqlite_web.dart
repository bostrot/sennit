import 'package:sqlite3/wasm.dart';

/// The browser build's engine: SQLite compiled to WebAssembly, served next to
/// the app as `sqlite3.wasm` and loaded once by [loadSqlite].
WasmSqlite3? _engine;

/// In memory only. The browser client is a view of a phone that holds the
/// real data; nothing it keeps should outlive the tab.
CommonDatabase openSqlite(String path) {
  final engine = _engine;
  if (engine == null) {
    throw StateError('loadSqlite() must finish before a database is opened');
  }
  return engine.openInMemory();
}

Future<void> loadSqlite() async {
  if (_engine != null) return;
  final engine = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  // The wasm build ships without a default file system; memory is the one
  // this build wants anyway.
  engine.registerVirtualFileSystem(InMemoryFileSystem(), makeDefault: true);
  _engine = engine;
}

Future<String> defaultDatabasePath() async => ':memory:';

String databasePathIn(String directory) => ':memory:';
