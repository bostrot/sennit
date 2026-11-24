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
  static const String homeAssistantToken = 'home_assistant_token';
  static const String llmApiKey = 'llm_api_key';
  static const String paperlessToken = 'paperless_token';

  /// The shared calendars' ICS addresses, one per line. A secret because a
  /// private address is one: Google's, iCloud's and Nextcloud's carry the
  /// token that grants read access in the URL itself.
  static const String calendarIcsUrl = 'calendar_ics_url';

  /// What the user noted about the people they write to, as one JSON blob —
  /// see `PersonMemoryBook`. A secret not because it opens anything but
  /// because it is the most personal thing Sennit keeps outside a message: a
  /// birthday, a partner's name, what someone is going through.
  static const String personMemory = 'person_memory';

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
      return;
    }
    await _storage.write(key: key, value: value);
  }

  Future<void> delete(String key) => _storage.delete(key: key);

  /// Forgets every credential Sennit stored on this device.
  Future<void> deleteAll() => _storage.deleteAll();
}

/// Setting keys, gathered so a typo is a compile error rather than a silently
/// missing preference.
abstract final class WeftSettings {
  static const String themeMode = 'appearance.theme_mode';

  /// When false (the default), the network rail is single-select: tapping a
  /// network shows only it, tapping again returns to All.
  static const String railMultiSelect = 'rail.multi_select';

  /// Whether Return sends the message.
  ///
  /// False by default, which is the opposite of most messengers and is the
  /// right default for this one: Sennit's composer grows to five lines, people
  /// write paragraphs in it, and a Return that sends turns every attempt at a
  /// second line into a message nobody meant to send. Off, Return breaks the
  /// line and the platform's send chord — Cmd+Return, Ctrl+Return — sends.
  static const String sendOnEnter = 'composer.send_on_enter';
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

  /// Which downloaded model on-device embeddings should use, by catalog id.
  /// Empty means "use the configured endpoint instead". The exact counterpart
  /// of [transcriptionLocalModel], for the same reason: the local model is the
  /// only option that keeps message text on the device.
  static const String embeddingLocalModel = 'search.local_model';

  /// Networks excluded from any remote endpoint, as a JSON list of network ids.
  static const String remoteExcludedNetworks = 'privacy.remote_excluded';

  /// Whether reading a chat tells the *sender* it was read. Off sends only
  /// private receipts — unread counts still clear on this account's devices,
  /// but the other side sees no blue-tick equivalent.
  static const String sendReadReceipts = 'privacy.read_receipts';

  /// Whether messages are scanned for appointments to offer "add to
  /// calendar". Fully on-device — rules plus, when installed, the local
  /// embedding model — which is why it may default on.
  static const String agendaDetect = 'agenda.detect';

  /// Networks whose chats stay out of the combined "All" inbox, as a JSON
  /// list of ids under `networks`. Tapping the network in the rail is the
  /// way in — a work bridge that should not mingle with private chats, most
  /// of the time. Merged chats with a visible leg stay visible.
  static const String inboxHiddenFromAll = 'inbox.hidden_from_all';

  /// Rooms whose message request the user accepted, as `{"rooms": [...]}`.
  ///
  /// Accepting an *invitation* is recorded by the homeserver — the room is
  /// joined. Accepting a stranger's conversation on a bridged network changes
  /// nothing the server knows about, so without this the answer lived only in
  /// memory and the request was back in the list on the next launch.
  static const String acceptedRequests = 'requests.accepted';

  /// Whether the first-start setup flow has run. It runs once per install —
  /// including once on the update that introduced it, which is deliberate:
  /// existing installs get the same defaults offered the same way.
  static const String onboardingDone = 'onboarding.done';

  /// Whether the feature walkthrough is owed: set when this install shows
  /// the sign-in screen, cleared when the walkthrough ends. An install that
  /// was already signed in when the walkthrough shipped never sets it.
  static const String walkthroughPending = 'onboarding.walkthrough_pending';

  /// Whether the walkthrough has been shown, so signing out and back in does
  /// not owe it a second time.
  static const String walkthroughDone = 'onboarding.walkthrough_done';

  /// The app version this install last started as, e.g. `1.0.12`. Written on
  /// every start; a stored version older than the running one is an update.
  static const String whatsNewLastVersion = 'whats_new.last_version';

  /// The version whose release notes are owed: set on the start that found
  /// an update, cleared the moment the notes are shown, so they show once.
  static const String whatsNewPendingVersion = 'whats_new.pending_version';

  /// Whether people are named from the device address book when a phone
  /// number matches, instead of whatever the network calls them. Off by
  /// default: reading contacts is a permission the user grants knowingly.
  static const String useDeviceContactNames = 'contacts.use_device_names';

  /// Whether bridge status broadcasts (WhatsApp statuses) show as story
  /// rings above the inbox instead of as the broadcast group chat.
  static const String statusRings = 'status.rings';

  /// How statuses appear at all: `rings` (default), `group`, or `off` —
  /// off hides both the ring row and the broadcast conversation.
  static const String statusMode = 'status.mode';

  /// Sender ids whose statuses are never shown, as a JSON list under
  /// `senders`. Long-press a ring to add someone.
  static const String statusHiddenSenders = 'status.hidden_senders';

  /// The user's Home Assistant base URL, e.g. `http://homeassistant.local:8123`.
  static const String homeAssistantUrl = 'integrations.ha_url';

  /// The user's paperless-ngx base URL.
  static const String paperlessUrl = 'integrations.paperless_url';

  /// Whether auto-replies and reply suggestions may be told when the user is
  /// busy, from the calendar under [SecretStore.calendarIcsUrl].
  ///
  /// On unless set: adding the calendar is the opt-in, and the integrations
  /// screen says beside the address what it is used for. Even on, only busy
  /// times are sent — never what the appointments are — and only when the
  /// conversation is about when someone is free.
  static const String calendarForAi = 'integrations.calendar_for_ai';

  /// An OpenAI-compatible chat-completions endpoint, e.g. a local Ollama.
  /// Empty means no LLM is configured and every feature that would use one
  /// stays dormant.
  static const String llmBaseUrl = 'ai.llm_base_url';
  static const String llmModel = 'ai.llm_model';

  /// The model the notification reply chips ask instead of [llmModel], at the
  /// same endpoint — a small or non-thinking one, so two short answers come
  /// in a second or two. Empty means [llmModel].
  static const String llmSuggestionModel = 'ai.llm_suggestion_model';

  /// Each model's context window and answer length — what the user typed and
  /// what the server reported — as one JSON object keyed by base URL and
  /// model (`LlmModelSettings.keyFor`), so switching models keeps each one's.
  static const String llmModelLimits = 'ai.llm_model_limits';

  /// Every auto-reply rule, as one JSON blob under a `rules` key.
  ///
  /// One key rather than a row per rule, for the reasons [notifyPolicy] gives:
  /// the list is read as a unit on every incoming message and written as a unit
  /// by the editor, and `AutoReplyRule.listFromJson` already degrades rule by
  /// rule — so a blob written by a newer build drops the rules this one cannot
  /// understand and keeps the rest.
  ///
  /// Absent means no rules, which means the feature is dormant. There is no
  /// master switch beside it on purpose: a rule is off unless someone turned it
  /// on, and a second place to say "not now" would be a second place to forget
  /// that a message is going out.
  static const String autoReplyRules = 'ai.auto_reply_rules';

  /// The quick messages offered in the composer's attach menu, as one JSON
  /// blob under a `messages` key, in the order they are shown.
  ///
  /// Absent means the built-in list, which is also what "Restore defaults"
  /// writes by removing the key — so an untouched list keeps following the
  /// app's language and any improvement to a shipped prompt.
  static const String quickMessages = 'ai.quick_messages';

  /// Whether what the user noted about a person goes to the model with the
  /// quick messages, auto-replies and reply chips written for them.
  ///
  /// Off unless set, like every other gate that sends something off the
  /// device. The notes themselves are not here — they are in [SecretStore]
  /// under [SecretStore.personMemory] — and writing one never needs this on:
  /// a note nobody sends is still a note.
  static const String personMemoryInAi = 'ai.person_memory';

  /// Whether Sennit keeps the memory up to date by itself: every so often it
  /// sends an active chat to the model and writes what it learned straight
  /// into the chat's and its people's memory, marked as learned, for the user
  /// to edit, pin or undo. On unless set — the owner's call — but only ever
  /// acted on while [personMemoryInAi] is on too.
  static const String personMemoryAutoLearn = 'ai.person_memory_auto';

  /// Whether facts may be learned from end-to-end encrypted chats too.
  ///
  /// Off unless set, the same trade as [linkPreviewEncryptedRooms]: learning
  /// sends the conversation to the endpoint for a purpose the user did not
  /// start a quick message or an auto-reply for.
  static const String personMemoryEncryptedChats =
      'privacy.person_memory_encrypted';

  /// Whether incoming-message notifications carry one or two AI-suggested
  /// answers. Its own gate on top of the endpoint existing, because
  /// configuring an LLM for anything sends every notified message's text to
  /// it — that trade is made here, not implied there.
  static const String notifySmartReplies = 'notify.smart_replies';

  /// Whether a link in a message may be previewed.
  ///
  /// On unless set. A preview is fetched by the *homeserver*, so it never
  /// exposes the reader's IP to the site, and in a room that is not encrypted
  /// the homeserver already holds the link — asking it about one tells it
  /// nothing new. The trade that is not free, encrypted rooms, has its own
  /// key: [linkPreviewEncryptedRooms].
  static const String linkPreviewEnabled = 'privacy.link_previews';

  /// Whether links in end-to-end encrypted rooms may be previewed too.
  ///
  /// Off unless set, like every other gate that sends something off the
  /// device: asking the homeserver about a link in an encrypted room tells it
  /// a url it would otherwise never see.
  static const String linkPreviewEncryptedRooms =
      'privacy.link_previews_encrypted';

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

  /// Every chat that self-deletes its messages, as one JSON blob under a
  /// `chats` key — see `RetentionSettings` in `weft_domain`.
  ///
  /// One key rather than a column on `chat_prefs`, and the reason is the
  /// archive rather than the schema: `settings` already travels in a backup,
  /// so a policy the user set survives a restore without the backup format
  /// growing a record type for it. Losing it silently would be the worst
  /// outcome available here — a user who believes a conversation still erases
  /// itself and finds out otherwise.
  ///
  /// Absent means no chat deletes anything, which is what almost every install
  /// says. There is deliberately no master switch beside it: a policy is set
  /// per conversation, and a global "pause" would be a second place for a
  /// conversation to quietly stop erasing itself.
  static const String retentionPolicies = 'privacy.retention';

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

  /// `ReplyReminderSettings` from `weft_notify`, as one JSON blob. Absent
  /// means off, which is the default: nothing is reminded about until the user
  /// asks for it.
  static const String notifyReplyReminders = 'notify.reply_reminders';

  /// `ReplyReminderLedger`: which chats are waiting for a reply and since
  /// when. Kept so the reminder clock survives a restart.
  static const String notifyReplyReminderLedger =
      'notify.reply_reminder_ledger';

  /// The reply reminders currently queued with the OS, as a list of plan keys
  /// under `keys`, so the next plan can cancel exactly what it replaces.
  static const String notifyReplyRemindersQueued =
      'notify.reply_reminders_queued';

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
