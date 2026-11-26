import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import 'device_memory.dart';
import 'on_device_models.dart';
import 'qwen_chat_template.dart';

/// Why an on-device completion did not happen.
enum OnDeviceFailure {
  /// The model asked for is not one Sennit offers.
  unknownModel,

  /// The model is not downloaded.
  notInstalled,

  /// The prompt does not fit the context the model runs with.
  promptTooLong,

  /// llama.cpp could not load the model — damaged file, too little memory.
  loadFailed,

  /// Generation itself failed.
  generationFailed,
}

class OnDeviceLlmException implements Exception {
  const OnDeviceLlmException(this.failure, [this.detail]);

  final OnDeviceFailure failure;
  final String? detail;

  @override
  String toString() =>
      'OnDeviceLlmException(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// The request was cancelled before it finished.
class OnDeviceCancelled implements Exception {
  const OnDeviceCancelled();
}

/// One finished on-device completion and how long it took.
class OnDeviceAnswer {
  const OnDeviceAnswer({
    required this.text,
    required this.finishReason,
    required this.promptTokens,
    required this.completionTokens,
    required this.loadTime,
    required this.firstTokenTime,
    required this.totalTime,
  });

  /// The answer, without any thinking.
  final String text;

  /// `stop` when the model finished, `length` when it hit the token limit.
  final String finishReason;

  final int promptTokens;
  final int completionTokens;

  /// How long loading the model took for this request; zero when it was
  /// already loaded.
  final Duration loadTime;

  /// From the start of generation to its first piece of text: the prompt's
  /// reading, mostly.
  final Duration firstTokenTime;

  /// From the start of generation to its end.
  final Duration totalTime;

  /// Generation speed after the first token, the number people compare.
  double get tokensPerSecond {
    final decoding = totalTime - firstTokenTime;
    if (completionTokens <= 1 || decoding <= Duration.zero) return 0;
    return (completionTokens - 1) * 1000000 / decoding.inMicroseconds;
  }

  /// How fast the prompt was read, in tokens a second.
  double get promptTokensPerSecond {
    if (promptTokens == 0 || firstTokenTime <= Duration.zero) return 0;
    return promptTokens * 1000000 / firstTokenTime.inMicroseconds;
  }
}

/// What runs a model: llama.cpp in production, a fake in tests.
abstract class OnDeviceRuntime {
  Future<void> load(
    String path, {
    required int contextTokens,
    required int threads,
  });

  /// Streams the text [prompt] continues with. Ends early, normally, after
  /// [cancel].
  Stream<String> generate(
    String prompt, {
    required int maxTokens,
    required double temperature,
    required double topP,
    required int topK,
    required List<String> stop,
  });

  void cancel();

  Future<int> countTokens(String text);

  Future<void> unload();
}

/// llama.cpp through llamadart.
///
/// llamadart runs llama.cpp in a worker isolate of its own, so neither a load
/// nor a generation blocks the UI; its stream delivers the text as it is
/// written. The GPU is used where llama.cpp trusts it — Metal on iOS and
/// Apple-silicon Macs — and the CPU everywhere else: Android's Vulkan is
/// experimental, and the 1-bit kernels Bonsai needs are NEON ones.
class LlamaCppRuntime implements OnDeviceRuntime {
  LlamaEngine? _engine;

  @override
  Future<void> load(
    String path, {
    required int contextTokens,
    required int threads,
  }) async {
    await unload();
    final engine = LlamaEngine(LlamaBackend());
    try {
      await engine.setModel(
        LlamaModel(ModelSource.path(path)),
        params: ModelParams(
          contextSize: contextTokens,
          numberOfThreads: threads,
          numberOfThreadsBatch: threads,
          device: defaultTargetPlatform == TargetPlatform.android
              ? ComputeDevice.cpu
              : ComputeDevice.auto,
        ),
      );
    } on Object {
      await engine.dispose();
      rethrow;
    }
    _engine = engine;
  }

  LlamaEngine get _loaded {
    final engine = _engine;
    if (engine == null) throw StateError('No model is loaded');
    return engine;
  }

  @override
  Stream<String> generate(
    String prompt, {
    required int maxTokens,
    required double temperature,
    required double topP,
    required int topK,
    required List<String> stop,
  }) => _loaded.generate(
    prompt,
    params: GenerationParams(
      maxTokens: maxTokens,
      temp: temperature,
      topK: topK,
      topP: topP,
      penalty: 1,
      stopSequences: stop,
      // A piece at a time rather than llamadart's batches, so a streamed
      // answer moves as it is written.
      streamBatchTokenThreshold: 1,
    ),
  );

  @override
  void cancel() => _engine?.cancelGeneration();

  @override
  Future<int> countTokens(String text) async =>
      (await _loaded.tokenize(text, addSpecial: false)).length;

  @override
  Future<void> unload() async {
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }
}

/// The model on the phone, as every AI feature uses it.
///
/// One model is loaded at a time, on first use, and unloaded after
/// [idleUnload] without a request — a gigabyte of memory is not something to
/// hold while the user is only reading. Requests run one after another, as
/// llama.cpp can only do one at a time; a request cancelled while it waits
/// never starts.
///
/// Only the isolate that set [instance] (the app's UI isolate) answers; the
/// engines a push wakes in the background have none, so their requests fail
/// at once instead of loading a second copy of the model next to the first.
class OnDeviceLlm {
  OnDeviceLlm({
    required this.modelPath,
    OnDeviceRuntime Function()? runtime,
    int? Function()? ramBytes,
    int? Function(OnDeviceLlmSpec spec)? requestedContext,
    this.idleUnload = const Duration(minutes: 5),
    int? threads,
  }) : _newRuntime = runtime ?? LlamaCppRuntime.new,
       _ramBytes = ramBytes ?? deviceMemoryBytes,
       _requestedContext = requestedContext ?? ((_) => null),
       _threads = threads;

  /// The one this isolate answers on-device requests with, if any.
  static OnDeviceLlm? instance;

  /// Where [spec]'s file is, or null when it is not downloaded.
  final Future<String?> Function(OnDeviceLlmSpec spec) modelPath;

  final Duration idleUnload;

  final OnDeviceRuntime Function() _newRuntime;
  final int? Function() _ramBytes;
  final int? Function(OnDeviceLlmSpec spec) _requestedContext;
  final int? _threads;

  OnDeviceRuntime? _runtime;
  ({String id, int context})? _loaded;
  Future<void> _queue = Future.value();
  Timer? _idle;

  /// Whether a model is in memory right now.
  bool get isLoaded => _loaded != null;

  /// The most context [spec] can have in this device's memory.
  int contextCapFor(OnDeviceLlmSpec spec) =>
      onDeviceContextCap(spec, _ramBytes());

  /// The context [spec] runs with on this device.
  int contextTokensFor(OnDeviceLlmSpec spec) => onDeviceContextTokens(
    spec,
    requested: _requestedContext(spec),
    ramBytes: _ramBytes(),
  );

  /// Writes the answer to [messages] with the model [modelId].
  ///
  /// [onText] is called with each piece of the answer as it is written —
  /// never with thinking, which is held back and dropped. Completing [cancel]
  /// stops the request wherever it is and throws [OnDeviceCancelled].
  Future<OnDeviceAnswer> complete({
    required String modelId,
    required List<ChatTurn> messages,
    required int maxTokens,
    bool thinking = false,
    double temperature = 0.5,
    double topP = 0.9,
    int topK = 20,
    Future<void>? cancel,
    void Function(String text)? onText,
  }) {
    final spec = OnDeviceLlmSpec.byId(modelId);
    if (spec == null) {
      return Future.error(
        OnDeviceLlmException(OnDeviceFailure.unknownModel, modelId),
      );
    }
    var cancelled = false;
    unawaited(
      cancel?.whenComplete(() {
        cancelled = true;
        _runtime?.cancel();
      }),
    );
    final done = Completer<OnDeviceAnswer>();
    final previous = _queue;
    _queue = done.future.then<void>((_) {}, onError: (_) {});
    unawaited(() async {
      await previous;
      _idle?.cancel();
      try {
        if (cancelled) throw const OnDeviceCancelled();
        done.complete(
          await _run(
            spec,
            messages: messages,
            maxTokens: maxTokens,
            thinking: thinking,
            temperature: temperature,
            topP: topP,
            topK: topK,
            cancelled: () => cancelled,
            onText: onText,
          ),
        );
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _idle = Timer(idleUnload, () => unawaited(unload()));
      }
    }());
    return done.future;
  }

  Future<OnDeviceAnswer> _run(
    OnDeviceLlmSpec spec, {
    required List<ChatTurn> messages,
    required int maxTokens,
    required bool thinking,
    required double temperature,
    required double topP,
    required int topK,
    required bool Function() cancelled,
    void Function(String text)? onText,
  }) async {
    final context = contextTokensFor(spec);
    final loadClock = Stopwatch()..start();
    var runtime = _runtime;
    if (runtime == null || _loaded != (id: spec.id, context: context)) {
      final path = await modelPath(spec);
      if (path == null) {
        throw OnDeviceLlmException(OnDeviceFailure.notInstalled, spec.id);
      }
      await _runtime?.unload();
      _runtime = null;
      _loaded = null;
      runtime = _newRuntime();
      try {
        await runtime.load(
          path,
          contextTokens: context,
          threads: _threads ?? onDeviceThreads(),
        );
      } on Object catch (error) {
        debugPrint('weft: on-device: load failed: $error');
        throw OnDeviceLlmException(OnDeviceFailure.loadFailed, '$error');
      }
      _runtime = runtime;
      _loaded = (id: spec.id, context: context);
      debugPrint(
        'weft: on-device: ${spec.id} loaded with $context tokens in '
        '${loadClock.elapsedMilliseconds} ms',
      );
    }
    loadClock.stop();
    if (cancelled()) throw const OnDeviceCancelled();

    final prompt = formatQwenChat(messages, thinking: thinking);
    final promptTokens = await runtime.countTokens(prompt);
    // A few tokens are left for the answer to be anything at all.
    if (promptTokens + 16 > context) {
      throw OnDeviceLlmException(
        OnDeviceFailure.promptTooLong,
        '$promptTokens of $context tokens',
      );
    }
    final limit = math.max(1, math.min(maxTokens, context - promptTokens));

    final clock = Stopwatch()..start();
    Duration? first;
    final raw = StringBuffer();
    // While thinking, nothing is passed on until the thought is closed.
    var streamed = 0;
    try {
      await for (final piece in runtime.generate(
        prompt,
        maxTokens: limit,
        temperature: temperature,
        topP: topP,
        topK: topK,
        stop: kQwenStopSequences,
      )) {
        if (piece.isEmpty) continue;
        first ??= clock.elapsed;
        raw.write(piece);
        if (cancelled()) break;
        if (onText == null) continue;
        final visible = thinking
            ? _afterThought(raw.toString())
            : raw.toString().trimLeft();
        if (visible != null && visible.length > streamed) {
          onText(visible.substring(streamed));
          streamed = visible.length;
        }
      }
    } on Object catch (error) {
      if (cancelled()) throw const OnDeviceCancelled();
      debugPrint('weft: on-device: generation failed: $error');
      throw OnDeviceLlmException(OnDeviceFailure.generationFailed, '$error');
    }
    clock.stop();
    if (cancelled()) throw const OnDeviceCancelled();
    final text = raw.toString();
    final completionTokens = text.isEmpty ? 0 : await runtime.countTokens(text);
    return OnDeviceAnswer(
      text: thinking ? stripThinking(text) : text.trim(),
      finishReason: completionTokens >= limit ? 'length' : 'stop',
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      loadTime: loadClock.elapsed,
      firstTokenTime: first ?? clock.elapsed,
      totalTime: clock.elapsed,
    );
  }

  /// What follows the closed thought in [text], or null while it is open.
  static String? _afterThought(String text) {
    final close = text.indexOf('</think>');
    if (close < 0) return text.contains('<think>') ? null : text;
    return text.substring(close + '</think>'.length).trimLeft();
  }

  /// Frees the model's memory; the next request loads it again.
  ///
  /// Waits for a request that is running to end first.
  Future<void> unload() async {
    _idle?.cancel();
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    try {
      await previous;
      final runtime = _runtime;
      _runtime = null;
      _loaded = null;
      await runtime?.unload();
    } finally {
      done.complete();
    }
  }
}
