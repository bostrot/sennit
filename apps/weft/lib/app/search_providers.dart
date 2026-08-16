import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_search/weft_search.dart';
import 'package:weft_store/weft_store.dart';
import 'package:weft_transcribe/weft_transcribe.dart';

import '../features/settings/models_screen.dart';
import '../services/models/model_catalog.dart';
import '../services/transcription/local_whisper_provider.dart';
import 'stores.dart';

/// The embedding provider described by settings, or null when semantic search
/// is not configured. Null is a supported state: the engine falls back to
/// keyword-only, which needs no endpoint at all.
final embeddingProviderProvider = Provider<EmbeddingProvider?>((ref) {
  ref.watch(settingsRevisionProvider);
  final stores = ref.watch(storesProvider);
  final settings = stores.settings;

  if (!settings.getBool(WeftSettings.embeddingEnabled)) return null;

  final baseUrl = settings.getString(WeftSettings.embeddingBaseUrl);
  final uri = baseUrl == null ? null : Uri.tryParse(baseUrl);
  if (uri == null || uri.host.isEmpty) return null;

  final provider = OpenAiCompatibleEmbeddingProvider(
    baseUrl: uri,
    modelId:
        settings.getString(WeftSettings.embeddingModel) ??
        'text-embedding-3-small',
    // Dimensions are model-dependent; stored so a model change can be detected
    // and trigger a reindex instead of mixing incomparable vectors.
    dimensions: settings.getInt('search.embedding_dimensions') ?? 1536,
    apiKey: stores.embeddingApiKey,
  );
  ref.onDispose(provider.dispose);
  return provider;
});

final searchEngineProvider = Provider<SearchEngine>((ref) {
  return SearchEngine(
    backend: ref.watch(storesProvider).search,
    embeddings: ref.watch(embeddingProviderProvider),
  );
});

/// Resolves the installed on-device Whisper model, if the user picked one.
///
/// Async because the path depends on the app-support directory; the UI reads
/// it through [transcriptionProviderProvider], which prefers it over any
/// endpoint — the local model is the only option that keeps voice notes on
/// the device.
final localWhisperPathProvider = FutureProvider<String?>((ref) async {
  ref.watch(settingsRevisionProvider);
  final settings = ref.watch(storesProvider).settings;

  final id = settings.getString(WeftSettings.transcriptionLocalModel);
  if (id == null || id.isEmpty) return null;

  final spec = ModelCatalog.byId(id);
  if (spec == null) return null;

  final installer = ref.watch(modelInstallerProvider);
  if (!await installer.isInstalled(spec)) return null;

  return (await installer.fileFor(spec, spec.files.first.name)).path;
});

/// The transcription provider described by settings, or null.
///
/// A `FutureProvider`, not a plain one: resolving an installed on-device model
/// touches the filesystem. Reading that asynchronous answer synchronously
/// (`.value` on a not-yet-loaded future) always yields null, which made the
/// Transcribe action insist no endpoint was configured even with a model
/// installed and selected.
final transcriptionProviderProvider = FutureProvider<TranscriptionProvider?>((
  ref,
) async {
  ref.watch(settingsRevisionProvider);
  final stores = ref.watch(storesProvider);
  final settings = stores.settings;

  // On-device wins when a model is installed: it is both the private option
  // and the one that works with no endpoint configured at all.
  final localPath = await ref.watch(localWhisperPathProvider.future);
  if (localPath != null) {
    final local = LocalWhisperProvider(
      modelPath: localPath,
      languageHint: settings.getString(WeftSettings.transcriptionLanguage),
    );
    ref.onDispose(local.dispose);
    return local;
  }

  final config = TranscriptionSettings(
    enabled: settings.getBool(WeftSettings.transcriptionEnabled),
    backend: TranscriptionBackend.fromId(
      settings.getString(WeftSettings.transcriptionProvider),
    ),
    baseUrl: settings.getString(WeftSettings.transcriptionBaseUrl),
    model: settings.getString(WeftSettings.transcriptionModel) ?? 'whisper-1',
    languageHint: settings.getString(WeftSettings.transcriptionLanguage),
    autoTranscribe: settings.getBool(WeftSettings.transcriptionAutoRun),
  );

  final provider = buildTranscriptionProvider(
    config,
    apiKey: stores.transcriptionApiKey,
  );
  if (provider != null) ref.onDispose(provider.dispose);
  return provider;
});

/// Drains the embedding queue in the background.
///
/// Runs only while an embedding provider is configured; without one the queue
/// simply accumulates, and enabling embeddings later backfills everything that
/// was indexed in the meantime.
class EmbeddingBackfill {
  EmbeddingBackfill({required this.store, required this.provider});

  final SearchStore store;
  final EmbeddingProvider provider;

  bool _running = false;

  int get pending => store.pendingEmbeddingCount;

  /// Embeds one batch. Returns how many vectors were written, so callers can
  /// loop until zero.
  Future<int> drainOnce({int batchSize = 32}) async {
    if (_running) return 0;
    _running = true;
    try {
      final batch = store.nextEmbeddingBatch(limit: batchSize);
      if (batch.isEmpty) return 0;

      try {
        final vectors = await provider.embed([for (final b in batch) b.body]);
        for (var i = 0; i < batch.length; i++) {
          store.saveEmbedding(
            rowId: batch[i].rowId,
            vector: vectors[i],
            model: provider.modelId,
          );
        }
        return batch.length;
      } on EmbeddingException catch (e) {
        // Attributed per row so a poison message sinks in the queue instead of
        // blocking everything behind it.
        for (final item in batch) {
          store.recordEmbeddingFailure(item.rowId, e.message);
        }
        return 0;
      }
    } finally {
      _running = false;
    }
  }

  /// Keeps draining until the queue is empty or progress stops.
  Future<void> drainAll({void Function(int remaining)? onProgress}) async {
    while (true) {
      final wrote = await drainOnce();
      onProgress?.call(pending);
      if (wrote == 0) return;
    }
  }
}

final embeddingBackfillProvider = Provider<EmbeddingBackfill?>((ref) {
  final provider = ref.watch(embeddingProviderProvider);
  if (provider == null) return null;
  return EmbeddingBackfill(
    store: ref.watch(storesProvider).search,
    provider: provider,
  );
});
