/// Weft's persistence: the identity graph, per-chat preferences, settings and
/// the search index.
///
/// Kept separate from the Matrix SDK's own database so a protocol-layer schema
/// rebuild never takes the user's merge decisions with it.
library;

export 'src/backup_adapter.dart';
export 'src/identity_store.dart';
export 'src/link_preview_store.dart';
export 'src/migrations.dart';
export 'src/retention_store.dart';
export 'src/search_store.dart';
export 'src/settings_store.dart';
export 'src/transcript_store.dart';
export 'src/weft_database.dart';
