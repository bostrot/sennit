import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_search/weft_search.dart';
import 'package:weft_store/weft_store.dart';
import 'package:weft_transcribe/weft_transcribe.dart';

import '../features/settings/models_screen.dart';
import '../services/billing/entitlements.dart';
import '../services/models/model_catalog.dart';
import '../services/search/local_embedding_provider.dart';
import '../services/transcription/local_whisper_provider.dart';
import 'billing_providers.dart';
import 'l10n_labels.dart';
import 'localisation.dart';
import 'stores.dart';

/// The embedding provider described by settings, or null when semantic search
/// is not configured. Null is a supported state: the engine falls back to
/// keyword-only, which needs no endpoint at all.
final embeddingProviderProvider = Provider<EmbeddingProvider?>((ref) {
  ref.watch(settingsRevisionProvider);
  // Without it, search is keyword-only — which is the free tier.
  if (!proUnlocked(ref, ProFeature.semanticSearch)) return null;
  final stores = ref.watch(storesProvider);
  final settings = stores.settings;

  // On-device wins when the user switched a downloaded model on: it is both
  // the private option and the one that needs no endpoint at all. Constructed
  // synchronously and loaded lazily — whether the files are really on disk is
  // answered at first use, where the error can actually be shown.
  final localId = settings.getString(WeftSettings.embeddingLocalModel);
  if (localId != null && localId.isNotEmpty) {
    final spec = ModelCatalog.byId(localId);
    if (spec != null && spec.capability == ModelCapability.embedding) {
      final installer = ref.watch(modelInstallerProvider);
      final local = LocalEmbeddingProvider(
        modelId: spec.id,
        dimensions: ModelCatalog.miniLmDimensions,
        modelFile: () => installer.fileFor(spec, spec.files.first.name),
        vocabFile: () => installer.fileFor(spec, spec.files.last.name),
      );
      ref.onDispose(local.dispose);
      return local;
    }
  }

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
  if (!proUnlocked(ref, ProFeature.transcription)) return null;
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

/// Drains the embedding queue on its own.
///
/// Runs only while an embedding provider is configured; without one the queue
/// simply accumulates, and enabling embeddings later backfills everything that
/// was indexed in the meantime. Once [start]ed it drains at launch, again
/// shortly after anything new is indexed, and after a pause for any failure
/// that was the endpoint's rather than a message's.
///
/// It used to drain only when someone pressed the button on the search
/// screen, which nothing explained: the notice came back every time search was
/// opened, and "Backfill will retry" after a 429 was a promise nobody kept.
/// Choosing a model or an endpoint is the consent — the text leaves the device
/// at that moment or never — so asking again per batch protected nothing.
///
/// Only while the app is in front. Search is read there and nowhere else, and
/// the process a backgrounded Sennit lives in is the one the built-in
/// connection posts notifications from. Draining there — and wrapping every
/// drain of 100 or more in a foreground service — meant an endpoint the phone
/// could not reach in Doze started that service and stopped it again within
/// milliseconds, every retry, all night. Android crashes an app that stops a
/// service before it was let call `startForeground`, and a process that crashes
/// in the background does not get its connection back until it is opened.
class EmbeddingBackfill extends ChangeNotifier {
  EmbeddingBackfill({
    required this.store,
    required this.provider,
    this.foreground,
    this.settle = const Duration(seconds: 2),
    this.firstRetry = const Duration(seconds: 30),
    this.maxRetry = const Duration(minutes: 30),
  }) {
    foreground?.addListener(_onForegroundChanged);
  }

  final SearchStore store;
  final EmbeddingProvider provider;

  /// Whether the app is in front, which is the only time a drain runs. Null
  /// drains regardless — tests, and anything with no lifecycle to follow.
  final ValueListenable<bool>? foreground;

  /// How long new work waits for more to arrive: opening a chat indexes a
  /// page of history at once, and one drain should take all of it.
  final Duration settle;

  final Duration firstRetry;
  final Duration maxRetry;

  bool _running = false;
  bool _again = false;
  bool _disposed = false;
  Timer? _timer;
  StreamSubscription<void>? _queued;
  Duration? _backoff;
  int _total = 0;

  int get pending => store.pendingEmbeddingCount;

  bool get _inForeground => foreground?.value ?? true;

  /// Whether a drain is under way right now.
  bool get running => _running;

  /// Why draining stopped and is waiting to try again, or null when it is not.
  String? get pausedReason => _pausedReason;
  String? _pausedReason;

  /// How far through the current drain, 0..1, or null when not draining.
  double? get progress {
    if (!_running || _total == 0) return null;
    return (1 - pending / _total).clamp(0.0, 1.0);
  }

  /// Drains now, and from then on whenever messages are indexed.
  void start() {
    _queued ??= store.embeddingQueued.listen((_) => schedule());
    schedule(Duration.zero);
  }

  /// Asks for a drain after [delay] (default [settle]). A drain already
  /// running goes round again instead, and a pending retry after a failure is
  /// left alone — the endpoint asked for the wait; [retryNow] overrides it.
  ///
  /// In the background it does nothing: coming back to the front drains
  /// whatever arrived meanwhile.
  void schedule([Duration? delay]) {
    if (_disposed || !_inForeground) return;
    if (_running) {
      _again = true;
      return;
    }
    if (_pausedReason != null) return;
    _timer?.cancel();
    _timer = Timer(delay ?? settle, () => unawaited(_drain()));
  }

  /// Leaving stops the clock — a drain under way finishes its batch and goes
  /// no further — and coming back picks up where it left off: a retry still
  /// waits out its backoff, anything else drains now.
  void _onForegroundChanged() {
    if (_disposed) return;
    _timer?.cancel();
    if (!_inForeground) return;
    if (_pausedReason != null) {
      _retryAfter(_backoff ?? firstRetry);
    } else {
      schedule(Duration.zero);
    }
  }

  void _retryAfter(Duration wait) {
    _timer = Timer(wait, () {
      _pausedReason = null;
      unawaited(_drain());
    });
  }

  /// Ends a pause early: the user saw why and wants another go now.
  Future<void> retryNow() {
    _timer?.cancel();
    _pausedReason = null;
    _notify();
    return _drain();
  }

  Future<void> _drain() async {
    if (_running || _disposed || !_inForeground) return;
    _running = true;
    _total = pending;
    _notify();
    try {
      do {
        _again = false;
        await drainAll(
          onProgress: (remaining) {
            if (remaining > _total) _total = remaining;
            _notify();
          },
        );
      } while (_again && !_disposed && _inForeground);
      _backoff = null;
      _pausedReason = null;
    } on Exception catch (e) {
      // Doubling, so a rate limit is honoured rather than argued with, and an
      // endpoint that is down for the night costs a request every half hour.
      final wait = _backoff = _backoff == null
          ? firstRetry
          : _backoff! * 2 > maxRetry
          ? maxRetry
          : _backoff! * 2;
      // Anything that is not an [EmbeddingException] — a 200 whose body is
      // not JSON, say — is the endpoint's doing as well.
      _pausedReason = e is _EndpointUnavailable ? e.reason : '$e';
      _timer?.cancel();
      if (!_disposed && _inForeground) _retryAfter(wait);
    } finally {
      _running = false;
      _notify();
    }
  }

  /// Embeds one batch. Returns how many vectors were written, so callers can
  /// loop until zero.
  ///
  /// A failure is held against the messages only when the endpoint answered
  /// and said something was wrong with *them* — and then only against the ones
  /// that still fail on their own. Everything else (no network, no model, a
  /// 401, a 429, a 5xx) throws [_EndpointUnavailable] and costs no attempts:
  /// counting those used to retire healthy messages for good after five bad
  /// minutes of Wi-Fi.
  Future<int> drainOnce({int batchSize = 32}) async {
    final batch = store.nextEmbeddingBatch(limit: batchSize);
    if (batch.isEmpty) return 0;

    try {
      return _save(
        batch,
        await provider.embed([for (final b in batch) b.body]),
      );
    } on EmbeddingException catch (e) {
      if (!_blamesMessages(e)) throw _EndpointUnavailable(_reason(e));
    }

    var wrote = 0;
    final rejected = <(int, String)>[];
    for (final item in batch) {
      try {
        wrote += _save([item], await provider.embed([item.body]));
      } on EmbeddingException catch (e) {
        if (!_blamesMessages(e)) throw _EndpointUnavailable(_reason(e));
        rejected.add((item.rowId, _reason(e)));
      }
    }
    // Several messages and not one of them accepted is a wrong model name,
    // not 32 poison messages — and blaming them would retire the whole
    // history in five quick rounds.
    if (wrote == 0 && batch.length > 1) {
      throw _EndpointUnavailable(rejected.first.$2);
    }
    for (final (rowId, reason) in rejected) {
      store.recordEmbeddingFailure(rowId, reason);
    }
    // A lone row that failed is still sinking — a nonzero return keeps the
    // drain going until it has sunk past the attempt limit.
    return wrote == 0 ? batch.length : wrote;
  }

  int _save(List<({int rowId, String body})> batch, List<Int8List> vectors) {
    // A provider swapped out mid-batch — a model change — must not file its
    // vectors under rows the new one has just re-queued.
    if (_disposed) return 0;
    for (var i = 0; i < batch.length; i++) {
      store.saveEmbedding(
        rowId: batch[i].rowId,
        vector: vectors[i],
        model: provider.modelId,
      );
    }
    return batch.length;
  }

  static bool _blamesMessages(EmbeddingException e) =>
      e.failure == EmbeddingFailure.other;

  static String _reason(EmbeddingException e) =>
      weftPlatformL10n().embeddingFailure(e) ?? e.message;

  /// Keeps draining until the queue is empty or progress stops.
  Future<void> drainAll({void Function(int remaining)? onProgress}) async {
    while (!_disposed && _inForeground) {
      final wrote = await drainOnce();
      onProgress?.call(pending);
      if (wrote == 0) return;
      // A breath between batches: on-device inference shares the UI isolate's
      // event loop, and a frame should get in between every 32 messages.
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    foreground?.removeListener(_onForegroundChanged);
    unawaited(_queued?.cancel());
    super.dispose();
  }
}

/// The endpoint, not a message, is why a batch failed.
class _EndpointUnavailable implements Exception {
  const _EndpointUnavailable(this.reason);
  final String reason;
}

/// The running backfill, rebuilt — and so restarted — whenever the embedding
/// provider changes: switching the on-device model on is enough to start
/// indexing, with no further button to find.
///
/// Something has to hold it for it to run at all: the app does from session
/// start, and the search screen listens to it for progress.
final embeddingBackfillProvider = Provider<EmbeddingBackfill?>((ref) {
  final provider = ref.watch(embeddingProviderProvider);
  if (provider == null) return null;
  final backfill = EmbeddingBackfill(
    store: ref.watch(storesProvider).search,
    provider: provider,
    foreground: ref.watch(appInForegroundProvider),
  )..start();
  ref.onDispose(backfill.dispose);
  return backfill;
});

/// Whether the app is in front of the user, kept current as it comes and goes.
///
/// `inactive` counts as in front — a call banner or the notification shade
/// pulled down over the app — and so does no state at all yet, which is an
/// engine its activity has only just started. Hidden, paused and detached are
/// the background.
final appInForegroundProvider = Provider<ValueListenable<bool>>((ref) {
  bool inFront(AppLifecycleState? state) => switch (state) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => false,
  };
  final foreground = ValueNotifier(
    inFront(WidgetsBinding.instance.lifecycleState),
  );
  final listener = AppLifecycleListener(
    onStateChange: (state) => foreground.value = inFront(state),
  );
  ref.onDispose(() {
    listener.dispose();
    foreground.dispose();
  });
  return foreground;
});
