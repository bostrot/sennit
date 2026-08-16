import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../vector/vector_math.dart';

/// Thrown when an embedding backend fails in a way worth showing the user.
class EmbeddingException implements Exception {
  const EmbeddingException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'EmbeddingException: $message';
}

/// Turns text into vectors.
///
/// Weft never ships a hosted endpoint. The user supplies their own — a local
/// model, their own inference server, or a commercial API they already pay
/// for — which is why this is an interface with several adapters rather than
/// one hard-coded client.
abstract class EmbeddingProvider {
  /// Identifies the model, stored alongside each vector.
  ///
  /// Vectors from different models are not comparable, so a change here has to
  /// invalidate the index rather than silently corrupt search results.
  String get modelId;

  /// Vector length this provider emits.
  int get dimensions;

  /// Embeds a batch, returning one quantised vector per input, in order.
  ///
  /// Batched because per-message HTTP round trips make backfilling a real
  /// history impractically slow.
  Future<List<Int8List>> embed(List<String> texts);

  void dispose() {}
}

/// Talks to any endpoint implementing OpenAI's `/v1/embeddings` shape.
///
/// That covers far more than OpenAI itself: LocalAI, Ollama, llama.cpp's
/// server, text-embeddings-inference, vLLM and Infinity all speak it, so one
/// adapter serves both the privacy-conscious local case and the convenient
/// hosted one.
class OpenAiCompatibleEmbeddingProvider implements EmbeddingProvider {
  OpenAiCompatibleEmbeddingProvider({
    required this.baseUrl,
    required this.modelId,
    required this.dimensions,
    this.apiKey,
    this.batchSize = 32,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Endpoint root, e.g. `https://api.openai.com/v1` or `http://localhost:8080/v1`.
  final Uri baseUrl;

  @override
  final String modelId;

  @override
  final int dimensions;

  final String? apiKey;
  final int batchSize;

  final http.Client _http;
  final bool _ownsClient;

  @override
  Future<List<Int8List>> embed(List<String> texts) async {
    if (texts.isEmpty) return const [];

    final out = <Int8List>[];
    for (var start = 0; start < texts.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, texts.length);
      out.addAll(await _embedBatch(texts.sublist(start, end)));
    }
    return out;
  }

  Future<List<Int8List>> _embedBatch(List<String> batch) async {
    final uri = baseUrl.replace(
      path: '${baseUrl.path.replaceAll(RegExp(r'/$'), '')}/embeddings',
    );

    final http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: {
              'content-type': 'application/json',
              if (apiKey != null && apiKey!.isNotEmpty)
                'authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({'model': modelId, 'input': batch}),
          )
          .timeout(const Duration(seconds: 60));
    } on Exception catch (e) {
      throw EmbeddingException('Could not reach the embedding endpoint: $e');
    }

    if (response.statusCode != 200) {
      throw EmbeddingException(
        _describeFailure(response),
        statusCode: response.statusCode,
      );
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['data'] is! List) {
      throw const EmbeddingException('Endpoint returned an unexpected shape');
    }

    final data = decoded['data'] as List;
    if (data.length != batch.length) {
      throw EmbeddingException(
        'Endpoint returned ${data.length} vectors for ${batch.length} inputs',
      );
    }

    // The API permits results out of order; `index` is authoritative.
    final ordered = List<Int8List?>.filled(batch.length, null);
    for (var i = 0; i < data.length; i++) {
      final entry = data[i];
      if (entry is! Map || entry['embedding'] is! List) {
        throw const EmbeddingException('Endpoint returned a malformed vector');
      }
      final index = entry['index'] is int ? entry['index'] as int : i;
      final values = (entry['embedding'] as List)
          .map((v) => (v as num).toDouble())
          .toList();

      if (values.length != dimensions) {
        throw EmbeddingException(
          'Model returned ${values.length}-dimension vectors but the index '
          'expects $dimensions. Reindex after changing the embedding model.',
        );
      }
      if (index < 0 || index >= ordered.length) {
        throw const EmbeddingException(
          'Endpoint returned an out-of-range index',
        );
      }
      ordered[index] = quantize(values);
    }

    if (ordered.any((v) => v == null)) {
      throw const EmbeddingException('Endpoint skipped one or more inputs');
    }
    return ordered.cast<Int8List>();
  }

  /// Turns the common failures into something actionable rather than dumping
  /// a raw body at the user.
  static String _describeFailure(http.Response response) {
    final body = response.body.length > 300
        ? '${response.body.substring(0, 300)}…'
        : response.body;

    return switch (response.statusCode) {
      401 || 403 => 'The embedding endpoint rejected the API key.',
      404 =>
        'No embeddings endpoint at that URL. The base URL usually ends in /v1.',
      429 => 'The embedding endpoint is rate limiting. Backfill will retry.',
      >= 500 => 'The embedding endpoint failed (${response.statusCode}).',
      _ => 'Embedding request failed (${response.statusCode}): $body',
    };
  }

  @override
  void dispose() {
    if (_ownsClient) _http.close();
  }
}

/// Deterministic offline provider, for tests and for search that must work
/// before the user has configured anything.
///
/// It is a bag-of-words hash projection, not a semantic model: identical text
/// embeds identically and shared vocabulary moves vectors together, which is
/// enough to exercise ranking, fusion and the ingest pipeline end to end
/// without a network call.
@visibleForTesting
class HashingEmbeddingProvider implements EmbeddingProvider {
  const HashingEmbeddingProvider({this.dimensions = 64});

  @override
  final int dimensions;

  @override
  String get modelId => 'weft-hashing-v1-$dimensions';

  @override
  Future<List<Int8List>> embed(List<String> texts) async =>
      texts.map(embedOne).toList();

  @override
  void dispose() {}

  Int8List embedOne(String text) {
    final vector = Float64List(dimensions);
    final tokens = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty);

    for (final token in tokens) {
      // Two hashes per token: one picks the bucket, the other the sign, so
      // unrelated tokens cancel instead of always accumulating.
      final bucket = token.hashCode.abs() % dimensions;
      final sign = (token.hashCode ~/ dimensions).isEven ? 1.0 : -1.0;
      vector[bucket] += sign;
    }
    return quantize(vector);
  }
}
