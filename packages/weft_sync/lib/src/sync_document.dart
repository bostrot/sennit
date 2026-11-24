import 'dart:convert';

import 'hlc.dart';

/// One synced value and when it was last written. A null [value] is a
/// deletion, kept so a removal on one device is not undone by another that
/// still has the old value.
class SyncEntry {
  const SyncEntry(this.value, this.hlc);

  final String? value;
  final Hlc hlc;

  @override
  bool operator ==(Object other) =>
      other is SyncEntry && other.value == value && other.hlc == hlc;

  @override
  int get hashCode => Object.hash(value, hlc);
}

/// Everything shared between the devices, keyed by [SyncKeys].
class SyncDocument {
  const SyncDocument(this.entries);

  static const SyncDocument empty = SyncDocument({});

  /// Reads [encode]'s form. Entries this build cannot parse are skipped
  /// rather than failing the document: one bad row from a newer build must not
  /// stop everything else from syncing.
  factory SyncDocument.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?> || decoded['v'] != 1) {
      throw const FormatException('Unknown sync document version');
    }
    final rows = decoded['e'];
    final entries = <String, SyncEntry>{};
    if (rows is Map<String, Object?>) {
      for (final MapEntry(:key, :value) in rows.entries) {
        if (value is! List || value.length != 2) continue;
        final [v, h] = value;
        if ((v != null && v is! String) || h is! String) continue;
        try {
          entries[key] = SyncEntry(v as String?, Hlc.parse(h));
        } on FormatException {
          continue;
        }
      }
    }
    return SyncDocument(entries);
  }

  final Map<String, SyncEntry> entries;

  String encode() => jsonEncode({
    'v': 1,
    'e': {
      for (final MapEntry(:key, :value) in entries.entries)
        key: [value.value, value.hlc.toString()],
    },
  });

  /// The per-key later of the two. Commutative, associative and idempotent —
  /// the three properties that let devices merge in any order and agree.
  SyncDocument merge(SyncDocument other) {
    final out = {...entries};
    for (final MapEntry(:key, :value) in other.entries.entries) {
      final mine = out[key];
      if (mine == null || value.hlc > mine.hlc) out[key] = value;
    }
    return SyncDocument(out);
  }

  bool sameAs(SyncDocument other) {
    if (other.entries.length != entries.length) return false;
    for (final MapEntry(:key, :value) in entries.entries) {
      if (other.entries[key] != value) return false;
    }
    return true;
  }
}
