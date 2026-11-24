import 'package:meta/meta.dart';

import 'hlc.dart';
import 'sync_document.dart';
import 'sync_policy.dart';

/// What this device remembers about one document entry.
///
/// [value] and [hlc] are the entry as last shared. [observed] is the value
/// this device last saw locally for it — what makes a local edit detectable by
/// comparison, with no hook in every place that writes a setting. [tracked] is
/// false for an entry that arrived while it was out of this device's scope:
/// the first time it comes into scope, the shared value wins over whatever is
/// here, because nothing here was ever edited *against* it.
@immutable
class SyncRecord {
  const SyncRecord({
    required this.value,
    required this.hlc,
    required this.observed,
    required this.tracked,
  });

  final String? value;
  final Hlc hlc;
  final String? observed;
  final bool tracked;

  SyncEntry get entry => SyncEntry(value, hlc);

  @override
  bool operator ==(Object other) =>
      other is SyncRecord &&
      other.value == value &&
      other.hlc == hlc &&
      other.observed == observed &&
      other.tracked == tracked;

  @override
  int get hashCode => Object.hash(value, hlc, observed, tracked);
}

/// One round's outcome.
class Reconciled {
  const Reconciled({
    required this.state,
    required this.apply,
    required this.document,
    required this.upload,
  });

  /// The records to persist, replacing the old ones. Keys absent here are
  /// deleted.
  final Map<String, SyncRecord> state;

  /// Local writes the shared document asks for; a null value removes.
  final Map<String, String?> apply;

  /// What the shared document should say after this round.
  final SyncDocument document;

  /// Whether [document] differs from what the server holds.
  final bool upload;
}

/// One round of sync, as a pure function.
///
/// [local] holds every in-scope value this device has now; an in-scope key
/// missing from it has no local value. [remote] is the document as the server
/// last held it, or null when it holds none.
///
/// Local edits are stamped before the remote document is merged, so an edit
/// made here since the last round beats one the server already had. Two
/// devices that each run a round against the other's upload end with the same
/// document — the property the tests exercise with shuffled interleavings.
Reconciled reconcile({
  required Map<String, SyncRecord> state,
  required Map<String, String> local,
  required SyncDocument? remote,
  required HlcClock clock,
}) {
  final next = {...state};
  final apply = <String, String?>{};

  bool secretsOn() =>
      next[SyncKeys.setting + SyncPolicy.secretsGate]?.value == 'true';

  void stampLocal(String key, String? value) {
    next[key] = SyncRecord(
      value: value,
      hlc: clock.tick(),
      observed: value,
      tracked: true,
    );
  }

  // Local edits first: compare what is here with what was last seen here.
  final secretsBefore = secretsOn();
  final keys = {...local.keys, ...state.keys};
  for (final key in keys) {
    if (!SyncPolicy.inScope(key, secrets: secretsBefore)) continue;
    final now = local[key];
    final record = next[key];
    if (record == null) {
      // A key the document already has but this device never synced: it is
      // joining, and the merge below lets the shared value win.
      if (now != null && remote?.entries.containsKey(key) != true) {
        stampLocal(key, now);
      }
    } else if (!record.tracked) {
      // First contact with an entry another device wrote: theirs wins.
      if (record.value != now) apply[key] = record.value;
      next[key] = SyncRecord(
        value: record.value,
        hlc: record.hlc,
        observed: record.value,
        tracked: true,
      );
    } else if (now != record.observed) {
      stampLocal(key, now);
    }
  }

  // Then the server's document, per key by clock.
  final shared = remote ?? SyncDocument.empty;
  // Secrets last, so a document that switches them on in the same round has
  // its switch merged before the secrets it gates are considered.
  final incoming = shared.entries.keys.toList()
    ..sort((a, b) {
      final sa = a.startsWith(SyncKeys.secret) ? 1 : 0;
      final sb = b.startsWith(SyncKeys.secret) ? 1 : 0;
      return sa != sb ? sa - sb : a.compareTo(b);
    });
  for (final key in incoming) {
    final entry = shared.entries[key]!;
    final record = next[key];
    if (record != null && !(entry.hlc > record.hlc)) continue;
    clock.receive(entry.hlc);
    final inScope = SyncPolicy.inScope(key, secrets: secretsOn());
    if (inScope) {
      final current = apply.containsKey(key) ? apply[key] : local[key];
      if (current != entry.value) {
        apply[key] = entry.value;
      } else {
        apply.remove(key);
      }
    }
    next[key] = SyncRecord(
      value: entry.value,
      hlc: entry.hlc,
      observed: inScope ? entry.value : record?.observed,
      tracked: inScope,
    );
  }

  // Secrets switched off — here or by another device — leave the document.
  if (!secretsOn()) {
    next.removeWhere((key, _) => key.startsWith(SyncKeys.secret));
    apply.removeWhere((key, _) => key.startsWith(SyncKeys.secret));
  }

  final document = SyncDocument({
    for (final MapEntry(:key, :value) in next.entries) key: value.entry,
  });
  return Reconciled(
    state: next,
    apply: apply,
    document: document,
    upload: !document.sameAs(shared),
  );
}
