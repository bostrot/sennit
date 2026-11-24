import 'package:sqlite3/common.dart';
import 'package:weft_domain/weft_domain.dart';

import 'weft_database.dart';

/// A persisted merge verdict, in the shape `weft_merge` rehydrates from.
///
/// Deliberately a plain record rather than a dependency on `weft_merge`'s
/// `MergeDecision`: the store stays free of the merge package, and the app
/// converts between the two at the seam.
typedef StoredDecision = ({
  String pair,
  String verdict,
  String source,
  DateTime decidedAt,
});

/// Persists the identity graph — handles, their contact assignment, and the
/// user's sticky merge verdicts.
///
/// Without this, an unmerge lasts until the next restart and then the scorer
/// cheerfully re-suggests it, which reads as the app ignoring the user.
class IdentityStore {
  IdentityStore(this._db);

  final WeftDatabase _db;

  CommonDatabase get _raw => _db.raw;

  // ------------------------------------------------------------------ handles

  /// Inserts or refreshes a handle, preserving its contact assignment unless
  /// [handle] carries one.
  void upsertHandle(NetworkHandle handle) {
    // The referenced contact must exist before the handle can point at it.
    final contactId = handle.unifiedContactId;
    if (contactId != null) {
      ensureContact(contactId, displayName: handle.displayName);
    }

    _raw.execute(
      '''
      INSERT INTO network_handle
        (id, network, remote_id, matrix_user_id, room_id, display_name,
         avatar_url, phone_e164, email, avatar_dhash, unified_contact_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        network        = excluded.network,
        remote_id      = excluded.remote_id,
        matrix_user_id = excluded.matrix_user_id,
        room_id        = excluded.room_id,
        display_name   = excluded.display_name,
        avatar_url     = excluded.avatar_url,
        phone_e164     = excluded.phone_e164,
        email          = excluded.email,
        avatar_dhash   = excluded.avatar_dhash,
        -- A refresh from sync must not clear a merge the user made.
        unified_contact_id =
          COALESCE(excluded.unified_contact_id, network_handle.unified_contact_id)
      ''',
      [
        handle.id,
        handle.network.id,
        handle.remoteId,
        handle.matrixUserId,
        handle.roomId,
        handle.displayName,
        handle.avatarUrl,
        handle.phoneE164,
        handle.email,
        handle.avatarDHash,
        handle.unifiedContactId,
      ],
    );
  }

  void upsertHandles(Iterable<NetworkHandle> handles) {
    _db.transaction(() {
      for (final handle in handles) {
        upsertHandle(handle);
      }
    });
  }

  List<NetworkHandle> loadHandles() {
    final rows = _raw.select('SELECT * FROM network_handle');
    return rows.map(_handleFromRow).toList(growable: false);
  }

  /// Records which contact a handle belongs to.
  void setContact(String handleId, String? contactId) {
    if (contactId != null) ensureContact(contactId);
    _raw.execute(
      'UPDATE network_handle SET unified_contact_id = ? WHERE id = ?',
      [contactId, handleId],
    );
  }

  /// Creates the `unified_contact` row a handle is about to point at.
  ///
  /// The identity graph mints contact ids in memory; without this the very
  /// first assignment fails the foreign key with
  /// `SqliteException(787): FOREIGN KEY constraint failed` and no merge ever
  /// persists. The FK is kept rather than dropped because it is what stops a
  /// handle from referencing a contact that was deleted.
  void ensureContact(
    String contactId, {
    String? displayName,
    String? avatarUrl,
  }) {
    _raw.execute(
      '''
      INSERT INTO unified_contact (id, display_name, avatar_url)
      VALUES (?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        display_name = COALESCE(excluded.display_name, unified_contact.display_name),
        avatar_url   = COALESCE(excluded.avatar_url, unified_contact.avatar_url)
      ''',
      [contactId, displayName ?? '', avatarUrl],
    );
  }

  /// Removes contacts no longer referenced by any handle.
  ///
  /// Unmerging leaves the old contact row behind; without a sweep the table
  /// grows forever with rows nothing points at.
  int pruneOrphanedContacts() {
    _raw.execute('''
      DELETE FROM unified_contact
      WHERE id NOT IN (
        SELECT unified_contact_id FROM network_handle
        WHERE unified_contact_id IS NOT NULL
      )
    ''');
    return _raw.updatedRows;
  }

  /// Applies a whole partition at once, after a merge or unmerge.
  void saveAssignments(Map<String, String> contactIdByHandleId) {
    _db.transaction(() {
      for (final contactId in contactIdByHandleId.values.toSet()) {
        ensureContact(contactId);
      }
      for (final entry in contactIdByHandleId.entries) {
        setContact(entry.key, entry.value);
      }
    });
  }

  static NetworkHandle _handleFromRow(Row row) {
    return NetworkHandle(
      id: row['id'] as String,
      network: ChatNetwork.fromId(row['network'] as String),
      remoteId: row['remote_id'] as String,
      matrixUserId: row['matrix_user_id'] as String,
      roomId: row['room_id'] as String?,
      displayName: row['display_name'] as String?,
      avatarUrl: row['avatar_url'] as String?,
      phoneE164: row['phone_e164'] as String?,
      email: row['email'] as String?,
      avatarDHash: row['avatar_dhash'] as int?,
      unifiedContactId: row['unified_contact_id'] as String?,
    );
  }

  // ---------------------------------------------------------------- decisions

  void saveDecision(StoredDecision decision) {
    _raw.execute(
      '''
      INSERT INTO merge_decision (pair, verdict, source, decided_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(pair) DO UPDATE SET
        verdict    = excluded.verdict,
        source     = excluded.source,
        decided_at = excluded.decided_at
      ''',
      [
        decision.pair,
        decision.verdict,
        decision.source,
        decision.decidedAt.millisecondsSinceEpoch,
      ],
    );
  }

  void saveDecisions(Iterable<StoredDecision> decisions) {
    _db.transaction(() {
      for (final decision in decisions) {
        saveDecision(decision);
      }
    });
  }

  List<StoredDecision> loadDecisions() {
    return _raw
        .select('SELECT * FROM merge_decision ORDER BY decided_at')
        .map(
          (row) => (
            pair: row['pair'] as String,
            verdict: row['verdict'] as String,
            source: row['source'] as String,
            // Always UTC: the epoch value carries no zone, and handing back
            // local time makes stored decisions compare unequal to the value
            // that was written on a machine in another zone.
            decidedAt: DateTime.fromMillisecondsSinceEpoch(
              row['decided_at'] as int,
              isUtc: true,
            ),
          ),
        )
        .toList(growable: false);
  }

  // ------------------------------------------------------------- chat prefs

  /// The network the user chose for outgoing messages in [chatId].
  ChatNetwork? sendNetworkFor(String chatId) {
    final rows = _raw.select(
      'SELECT send_network FROM chat_prefs WHERE chat_id = ?',
      [chatId],
    );
    if (rows.isEmpty) return null;
    final value = rows.first['send_network'] as String?;
    return value == null ? null : ChatNetwork.fromId(value);
  }

  Map<String, ChatNetwork> loadSendNetworks() {
    final out = <String, ChatNetwork>{};
    for (final row in _raw.select(
      'SELECT chat_id, send_network FROM chat_prefs WHERE send_network IS NOT NULL',
    )) {
      out[row['chat_id'] as String] = ChatNetwork.fromId(
        row['send_network'] as String,
      );
    }
    return out;
  }

  void setSendNetwork(String chatId, ChatNetwork? network) {
    _raw.execute(
      '''
      INSERT INTO chat_prefs (chat_id, send_network, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(chat_id) DO UPDATE SET
        send_network = excluded.send_network,
        updated_at   = excluded.updated_at
      ''',
      [chatId, network?.id, DateTime.now().millisecondsSinceEpoch],
    );
  }
}
