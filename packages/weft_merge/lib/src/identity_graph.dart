import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'scoring/merge_scorer.dart';

/// What the user decided about a pair of handles.
enum MergeVerdict { merged, rejected }

/// Who decided.
enum MergeDecisionSource { user, auto }

/// A recorded, sticky decision about one handle pair.
///
/// Decisions always beat heuristics. Once a user says "these two are not the
/// same person", no amount of matching avatars re-suggests it.
@immutable
class MergeDecision {
  const MergeDecision({
    required this.pair,
    required this.verdict,
    required this.source,
    required this.decidedAt,
  });

  /// Order-independent key from [pairKey].
  final String pair;
  final MergeVerdict verdict;
  final MergeDecisionSource source;
  final DateTime decidedAt;
}

/// The cross-network identity graph: which handles are the same person.
///
/// Handles are partitioned into contacts. A handle always belongs to exactly
/// one contact, so an unmerged handle is simply a contact of size one and the
/// rest of the app never branches on "merged or not".
///
/// This class is deliberately in-memory and synchronous. `weft_store` persists
/// and rehydrates it; keeping the logic pure makes every merge and unmerge path
/// unit-testable without a database.
class IdentityGraph {
  IdentityGraph({
    required List<NetworkHandle> handles,
    List<MergeDecision> decisions = const [],
    MergeScorer scorer = const MergeScorer(),
    String Function()? idFactory,
  }) : _scorer = scorer,
       _nextId = idFactory ?? _defaultIdFactory() {
    for (final h in handles) {
      _handles[h.id] = h;
      _byMatrixUserId[h.matrixUserId] = h.id;
      _contactOf[h.id] = h.unifiedContactId ?? _freshId();
    }
    for (final d in decisions) {
      _decisions[d.pair] = d;
      if (d.verdict == MergeVerdict.merged) {
        final ids = d.pair.split('|');
        if (_handles.containsKey(ids[0]) && _handles.containsKey(ids[1])) {
          _union(ids[0], ids[1]);
        }
      }
    }
    _repairCollisions();
  }

  /// Splits apart contacts that were never merged.
  ///
  /// A broken id factory once handed out contact ids that collided with ones
  /// already persisted, silently dropping strangers into each other's
  /// contacts — no merge, no decision, just two handles wearing the same id.
  /// A *real* merge always records a decision, so within every multi-handle
  /// contact the members must be connected through merged-pair decisions;
  /// any component that is not connected to the rest is split back out. This
  /// also heals the databases the broken factory already wrote.
  void _repairCollisions() {
    final byContact = <String, List<String>>{};
    _contactOf.forEach(
      (handle, contact) => byContact.putIfAbsent(contact, () => []).add(handle),
    );
    for (final members in byContact.values) {
      if (members.length < 2) continue;
      // Connected components over the merged decisions among these members.
      final unassigned = {...members};
      var first = true;
      while (unassigned.isNotEmpty) {
        final seed = unassigned.first;
        final component = <String>{seed};
        final queue = [seed];
        unassigned.remove(seed);
        while (queue.isNotEmpty) {
          final current = queue.removeLast();
          for (final other in [...unassigned]) {
            final decision = _decisions[pairKey(current, other)];
            if (decision?.verdict == MergeVerdict.merged) {
              component.add(other);
              unassigned.remove(other);
              queue.add(other);
            }
          }
        }
        if (first) {
          // The first component keeps the stored contact id.
          first = false;
          continue;
        }
        final fresh = _freshId();
        for (final handle in component) {
          _contactOf[handle] = fresh;
        }
      }
    }
  }

  /// A new contact id that provably belongs to nobody, whatever the factory
  /// returns — the guard that makes an id collision structurally impossible.
  String _freshId() {
    var id = _nextId();
    while (_contactOf.containsValue(id)) {
      id = _nextId();
    }
    return id;
  }

  final MergeScorer _scorer;
  final String Function() _nextId;

  final Map<String, NetworkHandle> _handles = {};
  final Map<String, String> _contactOf = {};
  final Map<String, MergeDecision> _decisions = {};

  /// Handle id by [NetworkHandle.matrixUserId], maintained alongside the
  /// handles themselves. See [handleFor] for who asks.
  final Map<String, String> _byMatrixUserId = {};

  static String Function() _defaultIdFactory() {
    var counter = 0;
    return () =>
        'contact_${DateTime.now().microsecondsSinceEpoch}_${counter++}';
  }

  Iterable<NetworkHandle> get handles => _handles.values;

  List<MergeDecision> get decisions =>
      _decisions.values.toList(growable: false);

  /// Contact id a handle currently belongs to.
  String? contactIdOf(String handleId) => _contactOf[handleId];

  /// The handle a Matrix user id belongs to, or null when no handle claims it.
  ///
  /// The reverse of [NetworkHandle.matrixUserId], and the lookup reaction
  /// dedupe is built on: an annotation arrives from a bridge ghost
  /// (`@whatsapp_49…:example.org`), and the only honest way to ask whether that
  /// ghost is a person already merged with another is to find its handle and
  /// then its contact. Null for every ghost the graph has never seen — a group
  /// member who has no DM, a bridgebot — and the caller's correct response is
  /// to treat that sender as their own person rather than to guess from the
  /// shape of the id.
  NetworkHandle? handleFor(String matrixUserId) {
    final id = _byMatrixUserId[matrixUserId];
    return id == null ? null : _handles[id];
  }

  /// The contact behind a Matrix user id: [handleFor] then [contactIdOf].
  ///
  /// This is the whole of what a `MergedIdentityResolver` needs, which is why
  /// it is one call — every caller that assembled it out of the two parts got
  /// to choose a different answer for "unknown sender", and the wrong choice
  /// there does not show a bad suggestion, it silently merges two people's
  /// reactions into one.
  String? contactIdForUser(String matrixUserId) {
    final handle = handleFor(matrixUserId);
    return handle == null ? null : contactIdOf(handle.id);
  }

  /// All handles sharing a contact.
  List<NetworkHandle> handlesInContact(String contactId) => _contactOf.entries
      .where((e) => e.value == contactId)
      .map((e) => _handles[e.key]!)
      .sorted((a, b) => a.network.index.compareTo(b.network.index));

  /// Materialises the current partition as contacts.
  List<UnifiedContact> contacts() {
    final grouped = <String, List<NetworkHandle>>{};
    for (final entry in _contactOf.entries) {
      grouped.putIfAbsent(entry.value, () => []).add(_handles[entry.key]!);
    }
    return grouped.entries
        .map((e) {
          final members = e.value.sorted(
            (a, b) => a.network.index.compareTo(b.network.index),
          );
          return UnifiedContact(
            id: e.key,
            displayName: _bestName(members),
            avatarUrl: members
                .firstWhereOrNull((h) => h.avatarUrl != null)
                ?.avatarUrl,
            handles: members
                .map((h) => h.copyWith(unifiedContactId: e.key))
                .toList(growable: false),
          );
        })
        .sorted((a, b) => a.displayName.compareTo(b.displayName));
  }

  /// Longest available name wins — "Anna Maven" is more useful than "Anna",
  /// and bridges often supply only a phone number for one of the two.
  static String _bestName(List<NetworkHandle> members) {
    final named = members
        .map((h) => h.displayName)
        .whereType<String>()
        .where((n) => n.trim().isNotEmpty)
        .toList();
    if (named.isEmpty) return members.first.remoteId;
    named.sort((a, b) => b.length.compareTo(a.length));
    return named.first;
  }

  /// Merge suggestions the user hasn't already ruled on.
  ///
  /// Ruled on at the *contact* level, not the handle level. A contact spans
  /// several handles, and a rejection recorded against one of them used to
  /// leave the scorer free to re-propose the same two people through
  /// another: dismiss "C + A", get "C + B" — the identical card, back
  /// again, however many times the user said no. A verdict between any two
  /// handles now silences every pair that bridges the same two contacts.
  List<MergeCandidate> suggestions({
    Map<String, Set<String>> sharedGroupsByPair = const {},
  }) {
    final rejected = _decisions.entries
        .where((e) => e.value.verdict == MergeVerdict.rejected)
        .map((e) => e.key)
        .toSet();

    final rejectedContactPairs = <String>{};
    for (final key in rejected) {
      final parts = key.split('|');
      if (parts.length != 2) continue;
      final ca = _contactOf[parts[0]];
      final cb = _contactOf[parts[1]];
      if (ca != null && cb != null && ca != cb) {
        rejectedContactPairs.add(pairKey(ca, cb));
      }
    }

    final withContacts = _handles.values
        .map((h) => h.copyWith(unifiedContactId: _contactOf[h.id]))
        .toList(growable: false);

    final scored = _scorer.scoreAll(
      withContacts,
      rejectedPairs: rejected,
      sharedGroupsByPair: sharedGroupsByPair,
    );
    if (rejectedContactPairs.isEmpty) return scored;
    return [
      for (final candidate in scored)
        if (!rejectedContactPairs.contains(
          pairKey(
            _contactOf[candidate.a.id] ?? candidate.a.id,
            _contactOf[candidate.b.id] ?? candidate.b.id,
          ),
        ))
          candidate,
    ];
  }

  /// Auto-merges the pairs [MergeCandidate.qualifiesForAutoMerge] accepts —
  /// identical substantial name, different networks, one-to-one — when the
  /// user has opted in. Returns the pairs actually merged.
  List<MergeCandidate> applyAutoMerges({DateTime? now}) {
    if (!_scorer.config.autoMergeOnIdentitySignal) return const [];
    final applied = <MergeCandidate>[];
    for (final c in suggestions()) {
      if (!c.qualifiesForAutoMerge) continue;
      merge(c.a.id, c.b.id, source: MergeDecisionSource.auto, now: now);
      applied.add(c);
    }
    return applied;
  }

  /// Merges two handles into one contact, along with everything already merged
  /// into either of them.
  String merge(
    String handleIdA,
    String handleIdB, {
    MergeDecisionSource source = MergeDecisionSource.user,
    DateTime? now,
  }) {
    _require(handleIdA);
    _require(handleIdB);

    _decisions[pairKey(handleIdA, handleIdB)] = MergeDecision(
      pair: pairKey(handleIdA, handleIdB),
      verdict: MergeVerdict.merged,
      source: source,
      decidedAt: now ?? DateTime.now(),
    );
    return _union(handleIdA, handleIdB);
  }

  /// Splits [handleId] out into a contact of its own.
  ///
  /// Also records a rejection against each former group-mate, otherwise the
  /// scorer would cheerfully re-suggest the merge on the next pass and the
  /// unmerge would appear not to have worked.
  String unmerge(String handleId, {DateTime? now}) {
    _require(handleId);
    final oldContact = _contactOf[handleId]!;
    final formerPeers = _contactOf.entries
        .where((e) => e.value == oldContact && e.key != handleId)
        .map((e) => e.key)
        .toList();

    final at = now ?? DateTime.now();
    for (final peer in formerPeers) {
      final key = pairKey(handleId, peer);
      _decisions[key] = MergeDecision(
        pair: key,
        verdict: MergeVerdict.rejected,
        source: MergeDecisionSource.user,
        decidedAt: at,
      );
    }

    final fresh = _freshId();
    _contactOf[handleId] = fresh;
    return fresh;
  }

  /// Records that two handles are *not* the same person without changing the
  /// current partition — the "dismiss suggestion" action.
  void reject(String handleIdA, String handleIdB, {DateTime? now}) {
    _require(handleIdA);
    _require(handleIdB);
    final key = pairKey(handleIdA, handleIdB);
    _decisions[key] = MergeDecision(
      pair: key,
      verdict: MergeVerdict.rejected,
      source: MergeDecisionSource.user,
      decidedAt: now ?? DateTime.now(),
    );
  }

  /// Adds or refreshes a handle, preserving its current contact assignment.
  void upsertHandle(NetworkHandle handle) {
    _handles[handle.id] = handle;
    _byMatrixUserId[handle.matrixUserId] = handle.id;
    _contactOf.putIfAbsent(
      handle.id,
      () => handle.unifiedContactId ?? _freshId(),
    );
  }

  String _union(String a, String b) {
    final target = _contactOf[a]!;
    final absorbed = _contactOf[b]!;
    if (target == absorbed) return target;
    for (final key in _contactOf.keys.toList()) {
      if (_contactOf[key] == absorbed) _contactOf[key] = target;
    }
    return target;
  }

  void _require(String handleId) {
    if (!_handles.containsKey(handleId)) {
      throw ArgumentError.value(handleId, 'handleId', 'Unknown handle');
    }
  }
}
