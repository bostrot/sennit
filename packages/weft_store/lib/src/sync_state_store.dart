import 'weft_database.dart';

/// One row of `sync_state`, as strings — the store knows nothing about clocks.
typedef StoredSyncRecord = ({
  String key,
  String? value,
  String hlc,
  String? observed,
  bool tracked,
});

/// Persists what device sync last shared, so a restart does not mistake every
/// setting for a fresh edit.
class SyncStateStore {
  SyncStateStore(this._db);

  final WeftDatabase _db;

  List<StoredSyncRecord> load() => [
    for (final row in _db.raw.select('SELECT * FROM sync_state'))
      (
        key: row['key'] as String,
        value: row['value'] as String?,
        hlc: row['hlc'] as String,
        observed: row['observed'] as String?,
        tracked: (row['tracked'] as int) != 0,
      ),
  ];

  /// Replaces every row with [records], atomically.
  void replaceAll(Iterable<StoredSyncRecord> records) {
    _db.transaction(() {
      _db.raw.execute('DELETE FROM sync_state');
      final insert = _db.raw.prepare(
        'INSERT INTO sync_state (key, value, hlc, observed, tracked) '
        'VALUES (?, ?, ?, ?, ?)',
      );
      try {
        for (final r in records) {
          insert.execute([
            r.key,
            r.value,
            r.hlc,
            r.observed,
            r.tracked ? 1 : 0,
          ]);
        }
      } finally {
        insert.close();
      }
    });
  }

  /// Forgets everything, so the next round joins as a new device would.
  void clear() => _db.raw.execute('DELETE FROM sync_state');
}
