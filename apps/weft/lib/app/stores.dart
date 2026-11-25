import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_store/weft_store.dart';

import '../features/whats_new/whats_new.dart' show recordLaunchVersion;
import '../services/backup/backup_service.dart' show kSennitVersion;
import '../services/review/review_prompt.dart';
import 'session_providers.dart';

/// Every store, opened once at startup.
///
/// Secrets are read into memory here so the providers that need them —
/// embedding and transcription builders — can stay synchronous. They are
/// re-read only when the user edits them in settings.
class WeftStores {
  WeftStores._({
    required this.db,
    required this.identity,
    required this.settings,
    required this.search,
    required this.transcripts,
    required this.retention,
    required this.linkPreviews,
    required this.syncState,
    required this.secrets,
    required this.embeddingApiKey,
    required this.transcriptionApiKey,
    this.homeAssistantToken,
    this.paperlessToken,
    this.llmApiKey,
    this.calendarIcsUrl,
    this.personMemory,
  });

  final WeftDatabase db;
  final IdentityStore identity;
  final SettingsStore settings;
  final SearchStore search;
  final TranscriptStore transcripts;

  /// Which chats erase themselves, and what has already been erased here.
  final RetentionStore retention;

  /// Answers the homeserver has already given about links, so a scroll past
  /// the same bubble does not ask it again. See [LinkPreviewStore].
  final LinkPreviewStore linkPreviews;

  /// What device sync last shared — see `StoreSyncLocal`.
  final SyncStateStore syncState;

  final SecretStore secrets;

  String? embeddingApiKey;
  String? transcriptionApiKey;
  String? homeAssistantToken;
  String? paperlessToken;
  String? llmApiKey;

  /// The shared calendars' addresses, one per line — see `icsUrisFrom`. Held
  /// with the secrets because a private ICS address carries its access token
  /// in the URL.
  String? calendarIcsUrl;

  /// What the user noted about the people they write to, as the keychain
  /// holds it — `MemoryBook.encode`'s blob. Read here with the secrets,
  /// so a prompt written in the background never waits on the keychain.
  String? personMemory;

  /// Test construction: everything in memory, no platform channels.
  ///
  /// [open] awaits secure-storage reads, which are method-channel calls that
  /// never complete under flutter_test's fake-async zone — a test using the
  /// real factory hangs at its first pump.
  @visibleForTesting
  factory WeftStores.inMemory() {
    final db = WeftDatabase.openAt(':memory:');
    final settings = SettingsStore(db);
    return WeftStores._(
      db: db,
      identity: IdentityStore(db),
      settings: settings,
      search: SearchStore(db),
      transcripts: TranscriptStore(db),
      retention: RetentionStore(db, settings),
      linkPreviews: LinkPreviewStore(db),
      syncState: SyncStateStore(db),
      secrets: SecretStore(),
      embeddingApiKey: null,
      transcriptionApiKey: null,
    );
  }

  /// [secretStore] exists for tests: the real one talks to the platform
  /// keychain over a method channel, which never answers under `flutter_test`.
  static Future<WeftStores> open({
    String? directoryOverride,
    SecretStore? secretStore,
  }) async {
    await WeftDatabase.loadEngine();
    final db = directoryOverride != null
        ? WeftDatabase.openAt(directoryOverride)
        : await WeftDatabase.open();
    final secrets = secretStore ?? SecretStore();
    final settings = SettingsStore(db);

    // Secure storage prompts on some platforms; demo mode skips it entirely.
    //
    // Issued together rather than one after another. None of them depends on
    // another's answer, and the auth gate holds its splash on this future — so
    // awaited in a row they put seven channel round trips end to end in front
    // of the first frame of every cold start, for seven values the inbox does
    // not even use.
    //
    // What this buys is the round trips overlapping, not the keychain work: the
    // Android plugin posts every call to one worker `HandlerThread`, so the
    // decryptions still happen in a row on the far side. That also makes this
    // safe — the platform serialises, and the map it reads is synchronised.
    //
    // `Future.wait` rather than seven bare futures awaited in turn, because it
    // subscribes to all seven at once: a keychain that refuses then fails the
    // bootstrap exactly as it does today, instead of failing it once and
    // leaving six unhandled errors behind it.
    final secretValues = kNoMatrix
        ? const <String?>[null, null, null, null, null, null, null]
        : await Future.wait<String?>([
            secrets.read(SecretStore.embeddingApiKey),
            secrets.read(SecretStore.transcriptionApiKey),
            secrets.read(SecretStore.homeAssistantToken),
            secrets.read(SecretStore.paperlessToken),
            secrets.read(SecretStore.llmApiKey),
            secrets.read(SecretStore.calendarIcsUrl),
            secrets.read(SecretStore.personMemory),
          ]);
    final [
      embeddingKey,
      transcriptionKey,
      haToken,
      paperlessKey,
      llmKey,
      calendarUrl,
      memoryBlob,
    ] = secretValues;

    return WeftStores._(
      db: db,
      identity: IdentityStore(db),
      settings: settings,
      search: SearchStore(db),
      transcripts: TranscriptStore(db),
      retention: RetentionStore(db, settings),
      linkPreviews: LinkPreviewStore(db),
      syncState: SyncStateStore(db),
      secrets: secrets,
      embeddingApiKey: embeddingKey,
      transcriptionApiKey: transcriptionKey,
      homeAssistantToken: haToken,
      paperlessToken: paperlessKey,
      llmApiKey: llmKey,
      calendarIcsUrl: calendarUrl,
      personMemory: memoryBlob,
    );
  }

  Future<void> setEmbeddingApiKey(String? value) async {
    embeddingApiKey = value;
    await secrets.write(SecretStore.embeddingApiKey, value);
  }

  Future<void> setTranscriptionApiKey(String? value) async {
    transcriptionApiKey = value;
    await secrets.write(SecretStore.transcriptionApiKey, value);
  }

  Future<void> setHomeAssistantToken(String? value) async {
    homeAssistantToken = value;
    await secrets.write(SecretStore.homeAssistantToken, value);
  }

  Future<void> setPaperlessToken(String? value) async {
    paperlessToken = value;
    await secrets.write(SecretStore.paperlessToken, value);
  }

  Future<void> setLlmApiKey(String? value) async {
    llmApiKey = value;
    await secrets.write(SecretStore.llmApiKey, value);
  }

  Future<void> setCalendarIcsUrl(String? value) async {
    calendarIcsUrl = value;
    await secrets.write(SecretStore.calendarIcsUrl, value);
  }

  Future<void> setPersonMemory(String? value) async {
    personMemory = value;
    await secrets.write(SecretStore.personMemory, value);
  }

  void dispose() => db.dispose();
}

/// Opened before the first frame that needs data; the auth gate waits on this
/// alongside the session, so everything below may read it synchronously.
final storesBootstrapProvider = FutureProvider<WeftStores>((ref) async {
  final stores = await WeftStores.open(
    directoryOverride: kDemoMode ? ':memory:' : null,
  );
  ref.onDispose(stores.dispose);
  // Before anything is drawn, so a fresh install has recorded its version
  // by the time it reaches the inbox; see [recordLaunchVersion].
  if (!kNoMatrix) {
    recordLaunchVersion(stores.settings, kSennitVersion);
    // Today counts as a day Sennit was used, for the rating prompt.
    ReviewPrompter(
      stores.settings,
      store: ReviewStore.current,
      version: kSennitVersion,
    ).recordActive();
  }
  return stores;
});

/// Synchronous access, valid once the gate has passed.
final storesProvider = Provider<WeftStores>((ref) {
  final stores = ref.watch(storesBootstrapProvider).value;
  if (stores == null) {
    throw StateError('Stores read before bootstrap completed');
  }
  return stores;
});

/// The stores, or null when nobody has opened them yet.
///
/// Deliberately `on Object` rather than `on StateError`. [storesProvider]
/// throws a `StateError` the *first* time it is read before bootstrap; from
/// then on it is a provider in an error state, and Riverpod rethrows that
/// wrapped in a `ProviderException` to everyone after. Catching only the
/// unwrapped form means the first reader degrades quietly and the second gets a
/// red screen — which is exactly what a widget test pumping a chat view with no
/// database saw, from a card whose whole job was to decide not to draw.
///
/// Every privacy gate reads its settings through this, and every one of them
/// falls back to its `off` constant when the answer is null: until the database
/// is open nobody can say whether the user opted in, and the honest answer to
/// that is "they did not".
WeftStores? storesOrNull(Ref ref) {
  try {
    return ref.watch(storesProvider);
  } on Object catch (_) {
    return null;
  }
}

/// Bumped whenever settings change, so providers derived from them rebuild.
class SettingsRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final settingsRevisionProvider = NotifierProvider<SettingsRevision, int>(
  SettingsRevision.new,
);
