import 'dart:typed_data';

import '../fusion/reciprocal_rank_fusion.dart';
import 'vector_math.dart';

/// One stored embedding, keyed by the search-index row it describes.
typedef StoredVector = ({int messageRowId, Int8List vector});

/// Nearest-neighbour search over stored embeddings.
abstract class VectorIndex {
  /// Returns up to [limit] hits, most similar first.
  ///
  /// [restrictTo], when given, limits the search to those row ids — this is how
  /// filters (network, chat, date range) are applied without the index needing
  /// to know what any of them mean.
  Future<List<RankedHit>> search(
    Int8List query, {
    int limit = 50,
    Set<int>? restrictTo,
  });
}

/// Exhaustive scan over every stored vector.
///
/// ## Why flat, and when to stop using it
///
/// Vectors are streamed from SQLite in batches and scored with an integer dot
/// product, so memory stays flat regardless of index size. At 384 dimensions
/// that is ~384 bytes and a few hundred integer multiply-adds per message:
/// tens of thousands of messages score in well under a frame, and a personal
/// history of ~100k is still comfortably interactive.
///
/// It is *exact* — no recall loss — which is the right trade while the corpus
/// is small, and it needs no training step, no index rebuild, and no tuning.
///
/// Past roughly half a million messages a linear scan becomes the wrong shape
/// and this should be replaced with an approximate index (IVF over k-means
/// centroids is the natural next step: cluster once, probe the nearest few
/// clusters). Everything above depends only on [VectorIndex], so that swap
/// touches this file alone.
class FlatVectorIndex implements VectorIndex {
  FlatVectorIndex(this._loadVectors);

  /// Streams stored vectors, ideally in batches from the database rather than
  /// all at once.
  final Stream<StoredVector> Function() _loadVectors;

  @override
  Future<List<RankedHit>> search(
    Int8List query, {
    int limit = 50,
    Set<int>? restrictTo,
  }) async {
    // A filter that matched nothing means no results, and streaming the whole
    // table to discover that would be pure waste.
    if (restrictTo != null && restrictTo.isEmpty) return const [];

    final top = TopK<int>(limit);

    await for (final stored in _loadVectors()) {
      if (restrictTo != null && !restrictTo.contains(stored.messageRowId)) {
        continue;
      }
      if (stored.vector.length != query.length) {
        // A vector from a previous embedding model. Skip rather than throw:
        // one stale row should not break search until a reindex finishes.
        continue;
      }
      top.add(stored.messageRowId, quantizedSimilarity(stored.vector, query));
    }

    return top
        .results()
        .map((e) => RankedHit(id: e.item, score: e.score))
        .toList(growable: false);
  }
}
