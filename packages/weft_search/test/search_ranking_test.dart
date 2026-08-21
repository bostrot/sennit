import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';

/// The ranking contract: what the user literally typed outranks everything
/// the embedding space merely finds similar.
class _Backend implements SearchBackend {
  _Backend(this.corpus);

  final Map<int, String> corpus;

  @override
  Future<List<RankedHit>> keywordSearch(
    String query, {
    int limit = 200,
    Set<int>? restrictTo,
  }) async {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\W+'))
        .where((t) => t.isNotEmpty);
    final hits = <RankedHit>[];
    for (final entry in corpus.entries) {
      final body = entry.value.toLowerCase();
      final matches = terms.where(body.contains).length;
      if (matches > 0) {
        hits.add(RankedHit(id: entry.key, score: matches.toDouble()));
      }
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  @override
  Future<Set<int>?> candidateRowIds(SearchQuery query) async => null;

  @override
  Stream<StoredVector> streamVectors() async* {
    const provider = HashingEmbeddingProvider(dimensions: 64);
    for (final entry in corpus.entries) {
      yield (messageRowId: entry.key, vector: provider.embedOne(entry.value));
    }
  }

  @override
  Future<List<SearchResult>> hydrate(
    List<FusedHit> hits,
    String queryText,
  ) async {
    return [
      for (final hit in hits)
        if (corpus.containsKey(hit.id))
          SearchResult(
            eventId: '\$${hit.id}',
            roomId: '!room',
            chatId: 'c1',
            network: ChatNetwork.whatsapp,
            senderId: '@peer:example.org',
            timestamp: DateTime.utc(2026, 8, 15),
            kind: MessageKind.text,
            body: corpus[hit.id]!,
            score: hit.score,
            matchedKeyword: hit.keywordRank != null,
            matchedSemantic: hit.vectorRank != null,
          ),
    ];
  }
}

/// Records every text it is asked to embed, so the multi-word probing is
/// observable, and answers with the deterministic hashing vectors.
class _RecordingEmbeddings implements EmbeddingProvider {
  final List<String> asked = [];
  final _inner = const HashingEmbeddingProvider(dimensions: 64);

  @override
  int get dimensions => 64;

  @override
  String get modelId => 'recording';

  @override
  Future<List<Int8List>> embed(List<String> texts) async {
    asked.addAll(texts);
    return _inner.embed(texts);
  }

  @override
  void dispose() {}
}

void main() {
  final corpus = {
    // The literal phrase, word-for-word.
    1: 'the insurance letter arrived today',
    // Semantically adjacent under the hashing embedder (shares words).
    2: 'a letter about the car insurance premium was mentioned',
    // A keyword match on one term only.
    3: 'renewed the insurance yesterday',
    // Noise.
    4: 'completely unrelated chatter about football',
  };

  test('the exact phrase outranks keyword and semantic matches', () async {
    final embeddings = _RecordingEmbeddings();
    final engine = SearchEngine(
      backend: _Backend(corpus),
      embeddings: embeddings,
    );

    final results = await engine.search(
      const SearchQuery(text: 'insurance letter arrived'),
    );

    expect(results, isNotEmpty);
    expect(
      results.first.body,
      'the insurance letter arrived today',
      reason: 'the message containing the typed words verbatim must be first',
    );

    // And every keyword-matched result sits above every semantic-only one.
    final firstSemanticOnly = results.indexWhere(
      (r) => !r.matchedKeyword && r.matchedSemantic,
    );
    final lastKeyword = results.lastIndexWhere((r) => r.matchedKeyword);
    if (firstSemanticOnly != -1) {
      expect(lastKeyword, lessThan(firstSemanticOnly));
    }
  });

  test('a multi-word query probes its significant words too', () async {
    final embeddings = _RecordingEmbeddings();
    final engine = SearchEngine(
      backend: _Backend(corpus),
      embeddings: embeddings,
    );

    await engine.search(const SearchQuery(text: 'insurance letter deadline'));

    expect(embeddings.asked, contains('insurance letter deadline'));
    expect(embeddings.asked, contains('insurance'));
    expect(embeddings.asked, contains('letter'));
    expect(embeddings.asked, contains('deadline'));
  });

  test('a single word embeds once, with no probe fan-out', () async {
    final embeddings = _RecordingEmbeddings();
    final engine = SearchEngine(
      backend: _Backend(corpus),
      embeddings: embeddings,
    );

    await engine.search(const SearchQuery(text: 'insurance'));

    expect(embeddings.asked, ['insurance']);
  });
}
