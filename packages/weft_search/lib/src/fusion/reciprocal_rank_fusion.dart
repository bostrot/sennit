import 'package:meta/meta.dart';

/// A single ranked hit from one retrieval method.
@immutable
class RankedHit {
  const RankedHit({required this.id, required this.score});

  /// Identifies the underlying message. Fusion joins on this.
  final int id;

  /// Method-native score. Comparable *within* a method, meaningless across
  /// them — which is exactly why fusion uses ranks instead.
  final double score;
}

/// A fused result: the message, its combined score, and where it came from.
@immutable
class FusedHit {
  const FusedHit({
    required this.id,
    required this.score,
    required this.keywordRank,
    required this.vectorRank,
  });

  final int id;
  final double score;

  /// 1-based rank in each list, or null when that method didn't return it.
  /// Surfaced so the UI can explain *why* something matched.
  final int? keywordRank;
  final int? vectorRank;

  bool get matchedBoth => keywordRank != null && vectorRank != null;

  @override
  String toString() =>
      'FusedHit($id, ${score.toStringAsFixed(4)}, kw=$keywordRank, vec=$vectorRank)';
}

/// Merges keyword and vector results with Reciprocal Rank Fusion.
///
/// RRF scores each document as `Σ 1 / (k + rankᵢ)` across the lists it appears
/// in. It is used instead of a weighted sum of the raw scores because BM25 and
/// cosine similarity live on incomparable scales — BM25 is unbounded and
/// corpus-dependent, cosine is bounded — so any fixed weighting between them
/// drifts as the corpus grows. Ranks are stable under both.
///
/// [k] damps the influence of the very top ranks; 60 is the value from the
/// original Cormack et al. paper and behaves well without tuning.
///
/// [keywordWeight] and [vectorWeight] scale each method's contribution, for
/// the cases where the user explicitly wants one or the other — an exact-phrase
/// search should lean on keywords.
List<FusedHit> reciprocalRankFusion({
  required List<RankedHit> keyword,
  required List<RankedHit> vector,
  int k = 60,
  double keywordWeight = 1.0,
  double vectorWeight = 1.0,
  int? limit,
}) {
  final scores = <int, double>{};
  final keywordRanks = <int, int>{};
  final vectorRanks = <int, int>{};

  for (var i = 0; i < keyword.length; i++) {
    final hit = keyword[i];
    final rank = i + 1;
    // Duplicate ids in one list would double-count; keep the best rank only.
    if (keywordRanks.containsKey(hit.id)) continue;
    keywordRanks[hit.id] = rank;
    scores[hit.id] = (scores[hit.id] ?? 0) + keywordWeight / (k + rank);
  }

  for (var i = 0; i < vector.length; i++) {
    final hit = vector[i];
    final rank = i + 1;
    if (vectorRanks.containsKey(hit.id)) continue;
    vectorRanks[hit.id] = rank;
    scores[hit.id] = (scores[hit.id] ?? 0) + vectorWeight / (k + rank);
  }

  final fused = scores.entries
      .map(
        (e) => FusedHit(
          id: e.key,
          score: e.value,
          keywordRank: keywordRanks[e.key],
          vectorRank: vectorRanks[e.key],
        ),
      )
      .toList();

  fused.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    // Deterministic ordering for ties, so repeated searches don't reshuffle.
    return a.id.compareTo(b.id);
  });

  if (limit != null && fused.length > limit) {
    return fused.sublist(0, limit);
  }
  return fused;
}
