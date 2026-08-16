import 'package:test/test.dart';
import 'package:weft_search/weft_search.dart';

void main() {
  group('reciprocalRankFusion', () {
    test('a document found by both outranks one found by either', () {
      // The whole point of hybrid search: agreement between two independent
      // methods is stronger evidence than a top rank in one.
      final fused = reciprocalRankFusion(
        keyword: const [
          RankedHit(id: 1, score: 9.0),
          RankedHit(id: 2, score: 8.0),
        ],
        vector: const [
          RankedHit(id: 3, score: 0.99),
          RankedHit(id: 2, score: 0.80),
        ],
      );

      expect(fused.first.id, 2);
      expect(fused.first.matchedBoth, isTrue);
    });

    test('ignores the raw score scales entirely', () {
      // BM25 is unbounded, cosine is in [-1, 1]. Fusion must depend only on
      // rank, or the balance between methods would drift with the corpus.
      final withHugeScores = reciprocalRankFusion(
        keyword: const [RankedHit(id: 1, score: 9999)],
        vector: const [RankedHit(id: 2, score: 0.5)],
      );
      final withTinyScores = reciprocalRankFusion(
        keyword: const [RankedHit(id: 1, score: 0.0001)],
        vector: const [RankedHit(id: 2, score: 0.5)],
      );

      expect(withHugeScores.map((f) => f.id), withTinyScores.map((f) => f.id));
    });

    test('records where each hit came from', () {
      final fused = reciprocalRankFusion(
        keyword: const [RankedHit(id: 1, score: 1)],
        vector: const [RankedHit(id: 2, score: 1)],
      );

      final keywordOnly = fused.firstWhere((f) => f.id == 1);
      expect(keywordOnly.keywordRank, 1);
      expect(keywordOnly.vectorRank, isNull);

      final vectorOnly = fused.firstWhere((f) => f.id == 2);
      expect(vectorOnly.vectorRank, 1);
      expect(vectorOnly.keywordRank, isNull);
    });

    test('weighting shifts the balance toward one method', () {
      const keyword = [RankedHit(id: 1, score: 1)];
      const vector = [RankedHit(id: 2, score: 1)];

      final keywordFirst = reciprocalRankFusion(
        keyword: keyword,
        vector: vector,
        keywordWeight: 5,
      );
      expect(keywordFirst.first.id, 1);

      final vectorFirst = reciprocalRankFusion(
        keyword: keyword,
        vector: vector,
        vectorWeight: 5,
      );
      expect(vectorFirst.first.id, 2);
    });

    test(
      'a duplicate id within one list is counted once, at its best rank',
      () {
        final fused = reciprocalRankFusion(
          keyword: const [
            RankedHit(id: 1, score: 9),
            RankedHit(id: 1, score: 8),
          ],
          vector: const [],
        );

        expect(fused, hasLength(1));
        expect(fused.single.keywordRank, 1);
      },
    );

    test('is deterministic for tied scores', () {
      final first = reciprocalRankFusion(
        keyword: const [RankedHit(id: 5, score: 1)],
        vector: const [RankedHit(id: 3, score: 1)],
      );
      final second = reciprocalRankFusion(
        keyword: const [RankedHit(id: 5, score: 1)],
        vector: const [RankedHit(id: 3, score: 1)],
      );

      expect(first.map((f) => f.id), second.map((f) => f.id));
      expect(first.map((f) => f.id), [3, 5], reason: 'ties break on id');
    });

    test('handles either list being empty', () {
      expect(
        reciprocalRankFusion(
          keyword: const [RankedHit(id: 1, score: 1)],
          vector: const [],
        ),
        hasLength(1),
      );
      expect(
        reciprocalRankFusion(
          keyword: const [],
          vector: const [RankedHit(id: 1, score: 1)],
        ),
        hasLength(1),
      );
      expect(
        reciprocalRankFusion(keyword: const [], vector: const []),
        isEmpty,
      );
    });

    test('respects the limit', () {
      final fused = reciprocalRankFusion(
        keyword: [for (var i = 0; i < 100; i++) RankedHit(id: i, score: 1)],
        vector: const [],
        limit: 10,
      );
      expect(fused, hasLength(10));
    });

    test('a smaller k sharpens the advantage of the top rank', () {
      List<FusedHit> withK(int k) => reciprocalRankFusion(
        keyword: const [RankedHit(id: 1, score: 1), RankedHit(id: 2, score: 1)],
        vector: const [],
        k: k,
      );

      final sharp = withK(1);
      final flat = withK(1000);

      final sharpGap = sharp[0].score - sharp[1].score;
      final flatGap = flat[0].score - flat[1].score;
      expect(sharpGap, greaterThan(flatGap));
    });
  });
}
