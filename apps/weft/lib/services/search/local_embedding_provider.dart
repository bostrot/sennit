import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:weft_search/weft_search.dart';

/// Embeds message text on this device with a MiniLM ONNX model Weft downloaded.
///
/// This is the private path for semantic search: enabling a remote embedding
/// endpoint sends decrypted message text off the device, which undoes E2EE for
/// everything indexed. With this provider the text never leaves the phone.
///
/// Construction is cheap and synchronous — the model loads on the first
/// [embed] call. That laziness is load-bearing: the provider graph that builds
/// this object is synchronous, and the first embed already happens on a
/// background drain where a one-off model load is unremarkable.
class LocalEmbeddingProvider implements EmbeddingProvider {
  LocalEmbeddingProvider({
    required this.modelId,
    required Future<File> Function() modelFile,
    required Future<File> Function() vocabFile,
    this.dimensions = 384,
  }) : _modelFile = modelFile,
       _vocabFile = vocabFile;

  @override
  final String modelId;

  @override
  final int dimensions;

  final Future<File> Function() _modelFile;
  final Future<File> Function() _vocabFile;

  OrtSession? _session;
  WordPieceTokenizer? _tokenizer;
  Future<void>? _loading;
  bool _disposed = false;

  Future<void> _ensureReady() {
    // One shared future, so concurrent embed calls do not each load a model.
    return _loading ??= () async {
      final model = await _modelFile();
      final vocab = await _vocabFile();
      if (!model.existsSync() || !vocab.existsSync()) {
        throw const EmbeddingException(
          'The on-device search model is not installed. Download it under '
          'Settings → Endpoints → Local models.',
        );
      }
      _tokenizer = WordPieceTokenizer.fromVocabText(await vocab.readAsString());
      _session = await OnnxRuntime().createSession(model.path);
    }();
  }

  @override
  Future<List<Int8List>> embed(List<String> texts) async {
    if (texts.isEmpty) return const [];
    try {
      await _ensureReady();
    } on EmbeddingException {
      _loading = null; // Not installed *yet*; a later call may find it.
      rethrow;
    } on Exception catch (e) {
      _loading = null;
      throw EmbeddingException('Could not load the on-device model: $e');
    }

    final session = _session!;
    final tokenizer = _tokenizer!;

    // One text per run rather than a padded batch: batching would demand a
    // padding mask to keep the pooled mean honest, and the backfill's batches
    // are 32 short messages — the model load dominates, not the loop.
    final out = <Int8List>[];
    for (final text in texts) {
      final ids = tokenizer.encode(text);
      final seq = ids.length;

      final inputIds = await OrtValue.fromList(Int64List.fromList(ids), [
        1,
        seq,
      ]);
      final attention = await OrtValue.fromList(
        Int64List.fromList(List.filled(seq, 1)),
        [1, seq],
      );
      final tokenTypes = await OrtValue.fromList(
        Int64List.fromList(List.filled(seq, 0)),
        [1, seq],
      );

      Map<String, OrtValue>? outputs;
      try {
        outputs = await session.run({
          'input_ids': inputIds,
          'attention_mask': attention,
          'token_type_ids': tokenTypes,
        });

        final hidden = outputs[session.outputNames.first];
        if (hidden == null) {
          throw const EmbeddingException(
            'The on-device model returned nothing.',
          );
        }
        final flat = (await hidden.asFlattenedList()).cast<num>();

        // Mean-pool over the sequence — every position is real (no padding),
        // so the mean is a plain average — then L2-normalise, matching how
        // sentence-transformers trained this model to be compared.
        final pooled = List<double>.filled(dimensions, 0);
        for (var t = 0; t < seq; t++) {
          final base = t * dimensions;
          for (var d = 0; d < dimensions; d++) {
            pooled[d] += flat[base + d].toDouble();
          }
        }
        for (var d = 0; d < dimensions; d++) {
          pooled[d] /= seq;
        }
        out.add(quantize(pooled));
      } on EmbeddingException {
        rethrow;
      } on Exception catch (e) {
        throw EmbeddingException('On-device embedding failed: $e');
      } finally {
        await inputIds.dispose();
        await attention.dispose();
        await tokenTypes.dispose();
        for (final value in (outputs ?? const {}).values) {
          await value.dispose();
        }
      }
    }
    return out;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session?.close();
    _session = null;
    _tokenizer = null;
    _loading = null;
  }
}
