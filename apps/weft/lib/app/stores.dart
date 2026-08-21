import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_store/weft_store.dart';

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
    required this.linkPreviews,
    required this.secrets,
    required this.embeddingApiKey,
    required this.transcriptionApiKey,
    this.homeAssistantToken,
    this.paperlessToken,
    this.llmApiKey,
  });

  final WeftDatabase db;
  final IdentityStore identity;
  final SettingsStore settings;
  final SearchStore search;
  final TranscriptStore transcripts;

  /// Answers the homeserver has already given about links, so a scroll past
  /// the same bubble does not ask it again. See [LinkPreviewStore].
  final LinkPreviewStore linkPreviews;

  final SecretStore secrets;

  String? embeddingApiKey;
  String? transcriptionApiKey;
  String? homeAssistantToken;
  String? paperlessToken;
  String? llmApiKey;

  /// Test construction: everything in memory, no platform channels.
  ///
  /// [open] awaits secure-storage reads, which are method-channel calls that
  /// never complete under flutter_test's fake-async zone — a test using the
  /// real factory hangs at its first pump.
  @visibleForTesting
  factory WeftStores.inMemory() {
    final db = WeftDatabase.openAt(':memory:');
    return WeftStores._(
      db: db,
      identity: IdentityStore(db),
      settings: SettingsStore(db),
      search: SearchStore(db),
      transcripts: TranscriptStore(db),
      linkPreviews: LinkPreviewStore(db),
      secrets: SecretStore(),
      embeddingApiKey: null,
      transcriptionApiKey: null,
    );
  }

  static Future<WeftStores> open({String? directoryOverride}) async {
    final db = directoryOverride != null
        ? WeftDatabase.openAt(directoryOverride)
        : await WeftDatabase.open();
    final secrets = SecretStore();

    String? embeddingKey;
    String? transcriptionKey;
    String? haToken;
    String? paperlessKey;
    String? llmKey;
    if (!kDemoMode) {
      // Secure storage prompts on some platforms; demo mode skips it entirely.
      embeddingKey = await secrets.read(SecretStore.embeddingApiKey);
      transcriptionKey = await secrets.read(SecretStore.transcriptionApiKey);
      haToken = await secrets.read(SecretStore.homeAssistantToken);
      paperlessKey = await secrets.read(SecretStore.paperlessToken);
      llmKey = await secrets.read(SecretStore.llmApiKey);
    }

    return WeftStores._(
      db: db,
      identity: IdentityStore(db),
      settings: SettingsStore(db),
      search: SearchStore(db),
      transcripts: TranscriptStore(db),
      linkPreviews: LinkPreviewStore(db),
      secrets: secrets,
      embeddingApiKey: embeddingKey,
      transcriptionApiKey: transcriptionKey,
      homeAssistantToken: haToken,
      paperlessToken: paperlessKey,
      llmApiKey: llmKey,
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

  void dispose() => db.dispose();
}

/// Opened before the first frame that needs data; the auth gate waits on this
/// alongside the session, so everything below may read it synchronously.
final storesBootstrapProvider = FutureProvider<WeftStores>((ref) async {
  final stores = await WeftStores.open(
    directoryOverride: kDemoMode ? ':memory:' : null,
  );
  ref.onDispose(stores.dispose);
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
