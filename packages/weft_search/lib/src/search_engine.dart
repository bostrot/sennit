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

    return _backend.hydrate(fused, query.text);
  }

  Future<List<RankedHit>> _vectorSearch(
    String text,
    Set<int>? restrictTo,
  ) async {
    final provider = _embeddings;
    if (provider == null) return const [];

    final Int8List queryVector;
    try {
      final vectors = await provider.embed([text]);
      if (vectors.isEmpty) return const [];
      queryVector = vectors.first;
    } on EmbeddingException {
      // A dead endpoint degrades search to keyword-only rather than failing
      // the whole query — partial results beat an error dialog.
      return const [];
    }

    return _vectorIndex.search(
      queryVector,
      limit: candidateDepth,
      restrictTo: restrictTo,
    );
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
