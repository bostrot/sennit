/// Hybrid search: BM25 keywords and vector similarity, fused by Reciprocal
/// Rank Fusion.
///
/// Pure Dart. Storage lives behind [SearchBackend] and embeddings behind
/// [EmbeddingProvider], so ranking is testable with in-memory rows and no
/// network.
library;

export 'src/embedding/embedding_provider.dart';
export 'src/fusion/reciprocal_rank_fusion.dart';
export 'src/search_engine.dart';
export 'src/search_query.dart';
export 'src/vector/vector_index.dart';
export 'src/vector/vector_math.dart';
