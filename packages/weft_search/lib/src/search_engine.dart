import 'dart:typed_data';

import 'embedding/embedding_provider.dart';
import 'fusion/reciprocal_rank_fusion.dart';
import 'search_query.dart';
import 'vector/vector_index.dart';

/// Storage operations the engine needs.
///
/// Implemented by `weft_store` against SQLite. Declared here as an interface so
/// this package stays pure Dart and the ranking logic is testable with a
/// handful of in-memory rows.
abstract class SearchBackend {
  /// BM25 search over the FTS index, best first.
  Future<List<RankedHit>> keywordSearch(
    String query, {
    int limit = 200,
    Set<int>? restrictTo,
  });

  /// Row ids matching [query]'s filters, or null when it has none.
  ///
  /// Null and the empty set mean different things: null is "no restriction",
  /// empty is "the filters excluded everything".
  Future<Set<int>?> candidateRowIds(SearchQuery query);

  /// Streams stored vectors for the flat index.
  Stream<StoredVector> streamVectors();

  /// Loads full rows for fused hits, preserving their order.
  Future<List<SearchResult>> hydrate(List<FusedHit> hits, String queryText);
}

/// Hybrid search: BM25 and vector kNN, fused.
///
/// Neither method alone is enough. Keywords miss "that place we talked about
/// for the offsite" when the message said "the barn near Lüneburg"; embeddings
/// miss exact identifiers like an order number or a `$eventId`. Running both
/// and fusing by rank is what makes search feel reliable rather than lucky.
class SearchEngine {
  SearchEngine({
    required SearchBackend backend,
    EmbeddingProvider? embeddings,
    VectorIndex? vectorIndex,
    this.rrfK = 60,
    this.candidateDepth = 200,
  }) : _backend = backend,
       _embeddings = embeddings,
       _vectorIndex = vectorIndex ?? FlatVectorIndex(backend.streamVectors);

  final SearchBackend _backend;
  final EmbeddingProvider? _embeddings;
  final VectorIndex _vectorIndex;

  final int rrfK;

  /// How deep each method searches before fusion. Fusion can only promote what
  /// it was given, so this is deliberately several times the display limit.
  final int candidateDepth;

  /// Whether semantic search is available at all. False until the user
  /// configures an embedding endpoint, which is why keyword search must always
  /// stand on its own.
  bool get semanticAvailable => _embeddings != null;

  Future<List<SearchResult>> search(SearchQuery query) async {
    if (query.isEmpty) return const [];

    final restrictTo = await _backend.candidateRowIds(query);
    if (restrictTo != null && restrictTo.isEmpty) return const [];

    // Fall back rather than returning nothing when semantic search was asked
    // for but no endpoint is configured.
    final mode = query.mode == SearchMode.semantic && !semanticAvailable
        ? SearchMode.keyword
        : query.mode;

    final wantsKeyword = mode != SearchMode.semantic;
    final wantsVector = mode != SearchMode.keyword && semanticAvailable;

    final keyword = wantsKeyword && query.text.trim().isNotEmpty
        ? await _backend.keywordSearch(
            query.text,
            limit: candidateDepth,
            restrictTo: restrictTo,
          )
        : const <RankedHit>[];

    final vector = wantsVector && query.text.trim().isNotEmpty
        ? await _vectorSearch(query.text, restrictTo)
        : const <RankedHit>[];

    // A filters-only query (no text) is a browse, not a search: return the
    // filtered set newest-first rather than an empty ranking.
    if (keyword.isEmpty && vector.isEmpty) {
      if (query.text.trim().isEmpty && restrictTo != null) {
        final browse = restrictTo
            .map(
              (id) => FusedHit(
                id: id,
                score: 0,
                keywordRank: null,
                vectorRank: null,
              ),
            )
            .toList();
        return _backend.hydrate(browse, query.text);
      }
      return const [];
    }

    final fused = reciprocalRankFusion(
      keyword: keyword,
      vector: vector,
      k: rrfK,
      // An exact-phrase query is a keyword intent; leaning on BM25 there stops
      // a fuzzy semantic neighbour outranking the literal match.
      keywordWeight: _looksLikeExactQuery(query.text) ? 2.0 : 1.0,
      limit: query.limit,
    );

    final hydrated = await _backend.hydrate(fused, query.text);
    return _tiered(hydrated, query.text);
  }

  /// Orders results the way a reader expects them, whatever the scores say:
  /// messages containing the typed words verbatim first, then any keyword
  /// match, then the purely semantic neighbours. Fusion is kept for ordering
  /// *within* a tier — its mistake was letting a close embedding outrank the
  /// message that literally says what was typed.
  static List<SearchResult> _tiered(
    List<SearchResult> results,
    String queryText,
  ) {
    final phrase = queryText.trim().toLowerCase().replaceAll('"', '');
    int tierOf(SearchResult result) {
      if (phrase.isNotEmpty && result.body.toLowerCase().contains(phrase)) {
        return 0;
      }
      if (result.matchedKeyword) return 1;
      return 2;
    }

    final indexed = results.indexed.toList()
      ..sort((a, b) {
        final tiers = tierOf(a.$2).compareTo(tierOf(b.$2));
        // Stable within a tier: fusion's order was position in the list.
        return tiers != 0 ? tiers : a.$1.compareTo(b.$1);
      });
    return [for (final entry in indexed) entry.$2];
  }

  Future<List<RankedHit>> _vectorSearch(
    String text,
    Set<int>? restrictTo,
  ) async {
    final provider = _embeddings;
    if (provider == null) return const [];

    // The whole query is always embedded; a multi-word query additionally
    // embeds its significant words on their own. "insurance letter deadline"
    // as one vector lands between three concepts, and the message that nails
    // one of them can sit closer to a single-word vector than to the blend —
    // per-word probes are what give multi-word semantic search its recall.
    final probes = <String>[text.trim()];
    final words = text
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((w) => w.length > 3)
        .toSet()
        .toList();
    if (words.length >= 2) probes.addAll(words.take(4));

    final List<Int8List> vectors;
    try {
      vectors = await provider.embed(probes);
      if (vectors.isEmpty) return const [];
    } on EmbeddingException {
      // A dead endpoint degrades search to keyword-only rather than failing
      // the whole query — partial results beat an error dialog.
      return const [];
    }

    // Merge by each row's best similarity across the probes. The full-query
    // vector is first, so a tie keeps its answer.
    final best = <int, double>{};
    for (final vector in vectors) {
      final hits = await _vectorIndex.search(
        vector,
        limit: candidateDepth,
        restrictTo: restrictTo,
      );
      for (final hit in hits) {
        final existing = best[hit.id];
        if (existing == null || hit.score > existing) {
          best[hit.id] = hit.score;
        }
      }
    }

    final merged = [
      for (final entry in best.entries)
        RankedHit(id: entry.key, score: entry.value),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return merged.length > candidateDepth
        ? merged.sublist(0, candidateDepth)
        : merged;
  }

  /// Quoted text, or anything with an identifier-ish token, reads as a request
  /// for a literal match.
  static bool _looksLikeExactQuery(String text) {
    final trimmed = text.trim();
    if (trimmed.length > 1 &&
        trimmed.startsWith('"') &&
        trimmed.endsWith('"')) {
      return true;
    }
    return RegExp(r'[$@#][\w.:-]{3,}|\b\d{5,}\b').hasMatch(trimmed);
  }
}
