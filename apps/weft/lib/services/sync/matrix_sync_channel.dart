import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_sync/weft_sync.dart';

/// The sealed sync document as global account data on the user's homeserver.
///
/// Account data rather than a room: it is per account, every device receives
/// it in `/sync` with no join or history, and the latest write is all a device
/// needs. The homeserver stores ciphertext and the event types; nothing else.
class MatrixSyncChannel implements SyncChannel {
  MatrixSyncChannel(this._client);

  final sdk.Client _client;

  @override
  Future<String?> backupSecret() async {
    final encryption = _client.encryption;
    if (encryption == null) return null;
    return encryption.ssss.getCached(sdk.EventTypes.MegolmBackup);
  }

  @override
  Map<String, Object?>? read(String type) => _client.accountData[type]?.content;

  @override
  Future<void> write(String type, Map<String, Object?> content) =>
      _client.setAccountData(_client.userID!, type, content);

  /// Fires when another device — or this one — replaced the document.
  Stream<void> get changes => _client.onSync.stream
      .where(
        (update) =>
            update.accountData?.any((e) => e.type == kSyncEventType) ?? false,
      )
      .map((_) {});
}
