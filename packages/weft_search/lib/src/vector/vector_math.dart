/// Encoding, quantisation and similarity for embedding vectors.
///
/// Embeddings are stored **L2-normalised and int8-quantised**:
///
/// * Normalising first means cosine similarity reduces to a plain dot product,
///   so the hot loop has no square roots in it.
/// * int8 cuts storage and scan time to a quarter of float32 at a recall cost
///   that is negligible for retrieval — the ranking barely moves, and results
///   are re-ranked by fusion afterwards anyway.
///
/// A 384-dimension model therefore costs 384 bytes per message rather than
/// 1536.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Scale factor for int8 quantisation. A normalised component is in [-1, 1],
/// and 127 maps that onto the full signed byte range.
const int quantizationScale = 127;

/// L2-normalises [vector] in place-safe fashion, returning a new list.
///
/// A zero vector is returned unchanged rather than producing NaNs — some
/// providers emit one for empty input, and poisoning the index with NaN would
/// silently break every subsequent search.
Float32List normalize(List<double> vector) {
  var sum = 0.0;
  for (final value in vector) {
    sum += value * value;
  }
  final magnitude = math.sqrt(sum);

  final out = Float32List(vector.length);
  if (magnitude == 0 || magnitude.isNaN || magnitude.isInfinite) {
    return out;
  }
  for (var i = 0; i < vector.length; i++) {
    out[i] = vector[i] / magnitude;
  }
  return out;
}

/// Normalises then quantises to int8, ready for storage.
Int8List quantize(List<double> vector) {
  final normalized = normalize(vector);
  final out = Int8List(normalized.length);
  for (var i = 0; i < normalized.length; i++) {
    // Rounding then clamping, so 1.0 maps to 127 rather than overflowing.
    final scaled = (normalized[i] * quantizationScale).round();
    out[i] = scaled.clamp(-quantizationScale, quantizationScale);
  }
  return out;
}

/// Reverses [quantize], approximately.
Float32List dequantize(Int8List quantized) {
  final out = Float32List(quantized.length);
  for (var i = 0; i < quantized.length; i++) {
    out[i] = quantized[i] / quantizationScale;
  }
  return out;
}

/// Similarity between a quantised stored vector and a quantised query.
///
/// Both are already normalised, so this is a dot product rescaled back into
/// roughly [-1, 1]. Integer accumulation keeps the inner loop cheap.
double quantizedSimilarity(Int8List a, Int8List b) {
  if (a.length != b.length) {
    throw ArgumentError(
      'Vector dimension mismatch: ${a.length} vs ${b.length}. '
      'Embeddings from different models cannot be compared; reindex after '
      'changing the embedding model.',
    );
  }

  var dot = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot / (quantizationScale * quantizationScale);
}

/// Cosine similarity of two already-normalised float vectors.
double cosineSimilarity(Float32List a, Float32List b) {
  if (a.length != b.length) {
    throw ArgumentError(
      'Vector dimension mismatch: ${a.length} vs ${b.length}',
    );
  }
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}

/// Serialises a quantised vector for a BLOB column.
Uint8List encodeVector(Int8List vector) => Uint8List.view(vector.buffer);

/// Reads a quantised vector back out of a BLOB.
Int8List decodeVector(Uint8List bytes) =>
    Int8List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);

/// Keeps the best [k] items by score without sorting everything.
///
/// A search over a large index only ever needs the top handful, and sorting
/// the whole candidate set to get them is wasted work.
class TopK<T> {
  TopK(this.k) : assert(k > 0, 'k must be positive');

  final int k;
  final List<({T item, double score})> _entries = [];

  /// Lowest score currently retained, or negative infinity while not yet full.
  /// Callers can use this to skip scoring candidates that cannot place.
  double get threshold =>
      _entries.length < k ? double.negativeInfinity : _entries.last.score;

  void add(T item, double score) {
    if (_entries.length >= k && score <= _entries.last.score) return;

    // Linear insert into a short, already-sorted list: k is small (typically
    // 10–50), which makes this faster in practice than a heap.
    var index = _entries.length;
    while (index > 0 && _entries[index - 1].score < score) {
      index--;
    }
    _entries.insert(index, (item: item, score: score));
    if (_entries.length > k) _entries.removeLast();
  }

  /// Results, best first.
  List<({T item, double score})> results() => List.unmodifiable(_entries);
}
