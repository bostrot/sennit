import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'weft_database.dart';

/// Non-secret preferences, as a typed key/value store.
///
/// Anything that would be embarrassing in a plain database file — API keys,
/// tokens — belongs in [SecretStore] instead.
class SettingsStore {
  SettingsStore(this._db);

  final WeftDatabase _db;

  String? getString(String key) {
    final rows = _db.raw.select('SELECT value FROM settings WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setString(String key, String value) {
    _db.raw.execute(
      '''
      INSERT INTO settings (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      ''',
      [key, value],
    );
  }

  bool getBool(String key, {bool fallback = false}) {
    final raw = getString(key);
    return raw == null ? fallback : raw == 'true';
  }

  void setBool(String key, {required bool value}) =>
      setString(key, value ? 'true' : 'false');

  int? getInt(String key) => int.tryParse(getString(key) ?? '');

  void setInt(String key, int value) => setString(key, '$value');

  double? getDouble(String key) => double.tryParse(getString(key) ?? '');

  void setDouble(String key, double value) => setString(key, '$value');

  Map<String, Object?>? getJson(String key) {
    final raw = getString(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      // A corrupt value should read as "unset" rather than crash startup.
      return null;
    }
  }

  void setJson(String key, Map<String, Object?> value) =>
      setString(key, jsonEncode(value));

  void remove(String key) =>
      _db.raw.execute('DELETE FROM settings WHERE key = ?', [key]);
}

/// Credentials, in the platform keychain rather than the database.
///
/// Weft asks users to supply their own transcription and embedding endpoints,
/// which means holding their API keys. Those go to Keychain / Keystore /
/// libsecret, never to a file next to the messages.
class SecretStore {
  SecretStore({FlutterSecureStorage? storage})
    // Defaults are already backed by Keychain on Apple platforms, the
    // Keystore-encrypted store on Android, and libsecret on Linux.
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const String transcriptionApiKey = 'transcription_api_key';
  static const String embeddingApiKey = 'embedding_api_key';
  static const String mcpTunnelToken = 'mcp_tunnel_token';

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
      return;
    }
    await _storage.write(key: key, value: value);
  }

  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Setting keys, gathered so a typo is a compile error rather than a silently
/// missing preference.
abstract final class WeftSettings {
  static const String themeMode = 'appearance.theme_mode';

  /// When false (the default), the network rail is single-select: tapping a
  /// network shows only it, tapping again returns to All.
  static const String railMultiSelect = 'rail.multi_select';
  static const String seedColor = 'appearance.seed_color';
  static const String density = 'appearance.density';

  static const String autoMergeOnIdentitySignal = 'merge.auto_on_identity';
  static const String mergeSuggestThreshold = 'merge.suggest_threshold';
  static const String defaultCountryCode = 'merge.default_country_code';

  static const String transcriptionEnabled = 'transcribe.enabled';
  static const String transcriptionProvider = 'transcribe.provider';
  static const String transcriptionBaseUrl = 'transcribe.base_url';
  static const String transcriptionModel = 'transcribe.model';
  static const String transcriptionLanguage = 'transcribe.language';
  static const String transcriptionAutoRun = 'transcribe.auto';

  /// Which downloaded model on-device transcription should use, by catalog id.
  /// Empty means "use the configured endpoint instead".
  static const String transcriptionLocalModel = 'transcribe.local_model';

  static const String embeddingEnabled = 'search.embedding_enabled';
  static const String embeddingProvider = 'search.embedding_provider';
  static const String embeddingBaseUrl = 'search.embedding_base_url';
  static const String embeddingModel = 'search.embedding_model';

  /// Networks excluded from any remote endpoint, as a JSON list of network ids.
  static const String remoteExcludedNetworks = 'privacy.remote_excluded';

  /// Whether a link in a message may be previewed.
  ///
  /// Off unless set, like every other gate that sends something off the device.
  /// A preview is fetched by the *homeserver*, so it never exposes the reader's
  /// IP to the site — but it does tell the homeserver which links they were
  /// sent and when, including links inside end-to-end encrypted rooms it would
  /// otherwise never see. That is a trade only the user can make.
  static const String linkPreviewEnabled = 'privacy.link_previews';

  /// Networks whose messages are never previewed, as a JSON list of ids under
  /// a `networks` key. The escape hatch the transcription gate already has:
  /// previews for the group chat, nothing for the one conversation that must
  /// leave no trace on the homeserver beyond its ciphertext.
  static const String linkPreviewExcludedNetworks =
      'privacy.link_preview_excluded';

  /// Whether the inbox snapshot reaches home screen widgets.
  ///
  /// The third gate of this shape, under the same `privacy.` prefix as the
  /// other two and off unless set, for the same reason. What it discloses is
  /// larger than either of them: a widget row is conversation content written
  /// *outside* the encrypted store, into a container the OS reads on its own
  /// schedule and any device-level backup copies. See `SnapshotSettings` in
  /// `apps/weft/lib/services/snapshot/snapshot_writer.dart`.
  ///
  /// **Deliberately no migration.** These five keys are rows in the generic
  /// `settings` key/value table that has existed since v1, exactly like the two
  /// link-preview keys above, which were added without one. A migration here
  /// would be an empty statement bumping `user_version` for nothing, and the
  /// rule this file's neighbours follow is that a migration exists when the
  /// *schema* changes.
  static const String snapshotWidgets = 'privacy.snapshot_widgets';

  /// Whether the inbox snapshot reaches the watch companions.
  ///
  /// Separate from [snapshotWidgets] because they are separate disclosures: a
  /// widget sits on a home screen anyone standing nearby can read, and a watch
  /// is on a wrist. Someone may well want one and not the other, and a single
  /// switch would make them decide for both.
  static const String snapshotWatch = 'privacy.snapshot_watch';

  /// Whether a snapshot row carries what the last message said.
  static const String snapshotPreviews = 'privacy.snapshot_previews';

  /// Whether a snapshot row carries the conversation's title, the last sender's
  /// name and its avatar.
  ///
  /// Split from [snapshotPreviews] because "don't show what they said" and
  /// "don't show who they are" are not the same worry — the split `weft_notify`
  /// documents between Android's hide-sensitive-content and iOS's
  /// hide-previews, made into two switches.
  static const String snapshotSenderNames = 'privacy.snapshot_senders';

  /// Networks that never reach a companion surface, as a JSON list of ids under
  /// a `networks` key — the same shape as [linkPreviewExcludedNetworks], read
  /// by the same kind of `fromStore`.
  static const String snapshotExcludedNetworks = 'privacy.snapshot_excluded';

  static const String mcpEnabled = 'mcp.enabled';
  static const String mcpPort = 'mcp.port';
  static const String mcpTunnelEnabled = 'mcp.tunnel_enabled';

  /// The whole of `NotificationPolicy`, as one JSON blob.
  ///
  /// One key rather than a dozen because the policy is read as a unit on every
  /// message and written as a unit by the settings screen, and because
  /// `NotificationPolicy.fromJson` already degrades field by field — so a blob
  /// written by a newer build loses the fields this one does not know about and
  /// keeps the rest, which a column-per-setting layout could not do.
  static const String notifyPolicy = 'notify.policy';

  /// The push gateway's `/_matrix/push/v1/notify` endpoint.
  ///
  /// Deliberately a *setting* and not a constant. Weft hosts nothing, and which
  /// sygnal instance a user's pokes travel through is a deployment decision
  /// they make, exactly like their homeserver. Empty means "no push" — the app
  /// still notifies from the foreground sync path.
  static const String notifyPushGateway = 'notify.push_gateway';

  /// The push key this device registered with last time.
  ///
  /// Persisted because it cannot be inferred: every device of the account
  /// registers under the same app id, so "the other pushers with my app id" is
  /// the user's other phones. Without this record a rotated FCM token leaves a
  /// dead pusher on the account forever.
  static const String notifyPushKey = 'notify.push_key';

  /// Whether the notification permission has already been asked for once.
  ///
  /// Android and iOS both give an app exactly one prompt; a second call
  /// returns the previous answer without showing anything. This is what lets
  /// the rationale sheet be shown *before* that one chance is spent.
  static const String notifyPermissionAsked = 'notify.permission_asked';
}
