/// The Matrix SDK's database: SQLite through sqflite's ffi backend on every
/// native platform, and nothing at all in the browser build — which never
/// signs in to Matrix itself but talks to a phone that has. See
/// `database_native.dart`.
library;

export 'database_native.dart' if (dart.library.js_interop) 'database_web.dart';
