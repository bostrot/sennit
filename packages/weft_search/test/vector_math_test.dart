import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_search/weft_search.dart';

void main() {
  group('normalize', () {
    test('produces a unit vector', () {
      final result = normalize([3, 4]);
      expect(result[0], closeTo(0.6, 1e-6));
      expect(result[1], closeTo(0.8, 1e-6));
    });

    test('returns zeros for a zero vector instead of NaN', () {
      // A NaN here would poison every subsequent comparison in the index.
      final result = normalize([0, 0, 0]);
      expect(result.every((v) => v == 0), isTrue);
    });

    test('survives a non-finite component', () {
      final result = normalize([double.infinity, 1]);
      expect(result.every((v) => v.isFinite), isTrue);
    });
  });

  group('quantize', () {
    test('round-trips approximately', () {
      final original = normalize([0.1, -0.5, 0.84]);
      final restored = dequantize(quantize([0.1, -0.5, 0.84]));

      for (var i = 0; i < original.length; i++) {
        expect(restored[i], closeTo(original[i], 0.01));
      }
    });

    test('stays inside the signed byte range', () {
      final result = quantize([1000, -1000]);
      expect(result.every((v) => v >= -127 && v <= 127), isTrue);
    });
  });

  group('quantizedSimilarity', () {
    test('is ~1 for identical vectors', () {
      final v = quantize([0.2, 0.5, -0.3, 0.8]);
      expect(quantizedSimilarity(v, v), closeTo(1.0, 0.01));
    });

    test('is ~-1 for opposed vectors', () {
      final a = quantize([1, 0, 0]);
      final b = quantize([-1, 0, 0]);
      expect(quantizedSimilarity(a, b), closeTo(-1.0, 0.01));
    });

    test('is ~0 for orthogonal vectors', () {
      final a = quantize([1, 0]);
      final b = quantize([0, 1]);
      expect(quantizedSimilarity(a, b), closeTo(0.0, 0.01));
    });

    test('tracks float cosine closely enough for ranking', () {
      // The quantisation error must not reorder results. Ranking is what
      // matters, not the absolute score.
      final rng = Random(20260815);
      for (var trial = 0; trial < 200; trial++) {
        final query = List.generate(64, (_) => rng.nextDouble() * 2 - 1);
        final a = List.generate(64, (_) => rng.nextDouble() * 2 - 1);
        final b = List.generate(64, (_) => rng.nextDouble() * 2 - 1);

        final exactA = cosineSimilarity(normalize(query), normalize(a));
        final exactB = cosineSimilarity(normalize(query), normalize(b));
        // Only assert order preservation when the true scores are clearly
        // apart; ties are allowed to flip.
        if ((exactA - exactB).abs() < 0.05) continue;

        final qq = quantize(query);
        final approxA = quantizedSimilarity(quantize(a), qq);
        final approxB = quantizedSimilarity(quantize(b), qq);

        expect(
          approxA > approxB,
          exactA > exactB,
          reason: 'quantisation reordered $exactA vs $exactB',
        );
      }
    });

    test('refuses to compare different dimensions', () {
      expect(
        () => quantizedSimilarity(quantize([1, 0]), quantize([1, 0, 0])),
        throwsArgumentError,
      );
    });
  });

  group('encode/decode', () {
    test('round-trips through a blob', () {
      final vector = quantize([0.5, -0.25, 0.75, 1.0]);
      expect(decodeVector(encodeVector(vector)), vector);
    });
  });

  group('TopK', () {
    test('keeps only the best k, best first', () {
      final top = TopK<String>(3);
      for (final entry in [
        ('a', 0.1),
        ('b', 0.9),
        ('c', 0.5),
        ('d', 0.7),
        ('e', 0.2),
      ]) {
        top.add(entry.$1, entry.$2);
      }

      expect(top.results().map((r) => r.item), ['b', 'd', 'c']);
    });

    test('reports a threshold only once full', () {
      final top = TopK<int>(2);
      expect(top.threshold, double.negativeInfinity);
      top.add(1, 0.5);
      expect(top.threshold, double.negativeInfinity);
      top.add(2, 0.9);
      expect(top.threshold, 0.5);
    });

    test('agrees with a full sort', () {
      final rng = Random(7);
      final scores = List.generate(500, (_) => rng.nextDouble());

      final top = TopK<int>(10);
      for (var i = 0; i < scores.length; i++) {
        top.add(i, scores[i]);
      }

      final expected = (List.generate(
        scores.length,
        (i) => i,
      )..sort((a, b) => scores[b].compareTo(scores[a]))).take(10);
      expect(top.results().map((r) => r.item), expected);
    });
  });

  group('FlatVectorIndex', () {
    const provider = HashingEmbeddingProvider(dimensions: 64);

    Stream<StoredVector> vectorsFrom(Map<int, String> corpus) async* {
      for (final entry in corpus.entries) {
        yield (messageRowId: entry.key, vector: provider.embedOne(entry.value));
      }
    }

    test('ranks an exact match first', () async {
      final corpus = {
        1: 'the clinical trial summary',
        2: 'completely unrelated chatter',
        3: 'lunch tomorrow',
      };
      final index = FlatVectorIndex(() => vectorsFrom(corpus));

      final hits = await index.search(
        provider.embedOne('the clinical trial summary'),
        limit: 3,
      );
      expect(hits.first.id, 1);
    });

    test('honours restrictTo', () async {
      final corpus = {1: 'alpha beta', 2: 'alpha gamma'};
      final index = FlatVectorIndex(() => vectorsFrom(corpus));

      final hits = await index.search(
        provider.embedOne('alpha'),
        restrictTo: {2},
      );
      expect(hits.map((h) => h.id), [2]);
    });

    test('an empty restrictTo short-circuits to no results', () async {
      var streamed = false;
      final index = FlatVectorIndex(() async* {
        streamed = true;
        yield (messageRowId: 1, vector: provider.embedOne('anything'));
      });

      expect(
        await index.search(provider.embedOne('x'), restrictTo: {}),
        isEmpty,
      );
      expect(
        streamed,
        isFalse,
        reason: 'scanning the table to find nothing is pure waste',
      );
    });

    test('skips vectors from a different model instead of throwing', () async {
      final index = FlatVectorIndex(() async* {
        yield (messageRowId: 1, vector: Int8List(32));
        yield (messageRowId: 2, vector: provider.embedOne('good row'));
      });

      final hits = await index.search(provider.embedOne('good row'));
      expect(
        hits.map((h) => h.id),
        [2],
        reason: 'one stale row must not break search during a reindex',
      );
    });
  });
}
