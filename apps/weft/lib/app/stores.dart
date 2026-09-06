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

  /// [secretStore] exists for tests: the real one talks to the platform
  /// keychain over a method channel, which never answers under `flutter_test`.
  static Future<WeftStores> open({
    String? directoryOverride,
    SecretStore? secretStore,
  }) async {
    final db = directoryOverride != null
        ? WeftDatabase.openAt(directoryOverride)
        : await WeftDatabase.open();
    final secrets = secretStore ?? SecretStore();

    // Secure storage prompts on some platforms; demo mode skips it entirely.
    //
    // Issued together rather than one after another. None of them depends on
    // another's answer, and the auth gate holds its splash on this future — so
    // awaited in a row they put five channel round trips end to end in front of
    // the first frame of every cold start, for five values the inbox does not
    // even use.
    //
    // What this buys is the round trips overlapping, not the keychain work: the
    // Android plugin posts every call to one worker `HandlerThread`, so the
    // decryptions still happen in a row on the far side. That also makes this
    // safe — the platform serialises, and the map it reads is synchronised.
    //
    // `Future.wait` rather than five bare futures awaited in turn, because it
    // subscribes to all five at once: a keychain that refuses then fails the
    // bootstrap exactly as it does today, instead of failing it once and
    // leaving four unhandled errors behind it.
    final secretValues = kDemoMode
        ? const <String?>[null, null, null, null, null]
        : await Future.wait<String?>([
            secrets.read(SecretStore.embeddingApiKey),
            secrets.read(SecretStore.transcriptionApiKey),
            secrets.read(SecretStore.homeAssistantToken),
            secrets.read(SecretStore.paperlessToken),
            secrets.read(SecretStore.llmApiKey),
          ]);
    final [embeddingKey, transcriptionKey, haToken, paperlessKey, llmKey] =
        secretValues;

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
