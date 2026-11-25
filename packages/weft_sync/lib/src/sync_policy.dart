/// Prefixes that say what kind of thing a sync key names.
abstract final class SyncKeys {
  /// A row of the `settings` table, by its key.
  static const String setting = 's:';

  /// A merge verdict, by its order-independent pair key.
  static const String merge = 'm:';

  /// The network a chat sends on, by chat id.
  static const String chatNetwork = 'c:';

  /// A keychain value — an API key, the person notes — by its keychain name.
  /// Only ever present while [SyncPolicy.secretsGate] is on.
  static const String secret = 'x:';
}

/// What travels between devices and what stays on the one it was set on.
///
/// An allowlist by prefix plus the exceptions inside those prefixes, rather
/// than "everything but": a setting added next year that describes this
/// device — a permission asked, a token registered, a model downloaded — must
/// not start syncing because nobody remembered to list it. A synced setting
/// someone forgot to list only fails to sync, which is the cheaper mistake.
abstract final class SyncPolicy {
  /// Whether keychain values sync. A synced setting itself, so turning it off
  /// on one device takes the secrets out of the shared document for all of
  /// them instead of the next device with it on putting them back.
  static const String secretsGate = 'sync.secrets';

  static const List<String> _syncedPrefixes = [
    'appearance.',
    'rail.',
    'composer.',
    'merge.',
    'transcribe.',
    'search.',
    'privacy.',
    'agenda.',
    'inbox.',
    'status.',
    'integrations.',
    'ai.',
    'notify.',
    // Messages hidden on this account only, one row each.
    'hidden.',
  ];

  static const Set<String> _localPrefixes = {
    // Widgets and watch faces are surfaces of one device.
    'privacy.snapshot_',
  };

  static const Set<String> _localKeys = {
    // A downloaded model is a file on this device.
    'transcribe.local_model',
    'search.local_model',
    // The OS gives each install one permission prompt, and each device
    // registers its own pusher.
    'notify.permission_asked',
    'notify.push_gateway',
    'notify.push_key',
    // Bookkeeping for reminders this device scheduled with its OS.
    'notify.reply_reminder_ledger',
    'notify.reply_reminders_queued',
  };

  /// Whether the `settings` row [key] is shared between devices.
  static bool syncsSetting(String key) {
    if (key == secretsGate) return true;
    if (_localKeys.contains(key)) return false;
    if (_localPrefixes.any(key.startsWith)) return false;
    return _syncedPrefixes.any(key.startsWith);
  }

  /// Whether this device reads and writes the document entry [docKey].
  static bool inScope(String docKey, {required bool secrets}) {
    if (docKey.startsWith(SyncKeys.setting)) {
      return syncsSetting(docKey.substring(SyncKeys.setting.length));
    }
    if (docKey.startsWith(SyncKeys.secret)) return secrets;
    return docKey.startsWith(SyncKeys.merge) ||
        docKey.startsWith(SyncKeys.chatNetwork);
  }
}
