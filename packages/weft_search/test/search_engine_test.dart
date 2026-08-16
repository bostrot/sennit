import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';

/// In-memory backend: enough to exercise orchestration without SQLite.
class _FakeBackend implements SearchBackend {
  _FakeBackend(this.corpus);

  /// rowId → body
  final Map<int, String> corpus;

  Set<int>? filterResult;
  List<String> keywordQueries = [];

  @override
  Future<List<RankedHit>> keywordSearch(
    String query, {
    int limit = 200,
    Set<int>? restrictTo,
  }) async {
    keywordQueries.add(query);
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\W+'))
        .where((t) => t.isNotEmpty);

    final hits = <RankedHit>[];
    for (final entry in corpus.entries) {
      if (restrictTo != null && !restrictTo.contains(entry.key)) continue;
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
  Future<Set<int>?> candidateRowIds(SearchQuery query) async =>
      query.hasFilters ? filterResult : null;

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
    return hits
        .where((h) => corpus.containsKey(h.id))
        .map(
          (h) => SearchResult(
            eventId: '\$${h.id}',
            roomId: '!room',
            chatId: 'c1',
            network: ChatNetwork.whatsapp,
            senderId: '@peer:example.org',
            timestamp: DateTime.utc(2026, 8, 15),
            kind: MessageKind.text,
            body: corpus[h.id]!,
            score: h.score,
            matchedKeyword: h.keywordRank != null,
            matchedSemantic: h.vectorRank != null,
          ),
        )
        .toList();
  }
}

/// Always fails, standing in for an endpoint that is down or misconfigured.
class _BrokenEmbeddings implements EmbeddingProvider {
  @override
  int get dimensions => 64;

  @override
  String get modelId => 'broken';

  @override
  Future<List<Int8List>> embed(List<String> texts) async =>
      throw const EmbeddingException('endpoint unreachable');

  @override
  void dispose() {}
}

void main() {
  final corpus = {
    1: 'the clinical trial summary is attached',
    2: 'lets meet at the barn near Luneburg',
    3: 'completely unrelated chatter',
    4: 'order 12345678 has shipped',
  };

  group('without an embedding provider', () {
    test('still searches by keyword', () async {
      final engine = SearchEngine(backend: _FakeBackend(corpus));

      expect(engine.semanticAvailable, isFalse);
      final results = await engine.search(const SearchQuery(text: 'clinical'));
      expect(results.map((r) => r.eventId), [r'$1']);
    });

    test('falls back to keyword when semantic mode is requested', () async {
      // Returning nothing because the user picked a mode they have not
      // configured would read as broken search.
      final engine = SearchEngine(backend: _FakeBackend(corpus));

      final results = await engine.search(
        const SearchQuery(text: 'clinical', mode: SearchMode.semantic),
      );
      expect(results, isNotEmpty);
    });
  });

  group('with an embedding provider', () {
    test('finds a message by meaning as well as by word', () async {
      final engine = SearchEngine(
        backend: _FakeBackend(corpus),
        embeddings: const HashingEmbeddingProvider(dimensions: 64),
      );

      expect(engine.semanticAvailable, isTrue);
      final results = await engine.search(
        const SearchQuery(text: 'the clinical trial summary is attached'),
      );
      expect(results.first.eventId, r'$1');
      expect(results.first.matchedBothMethods, isTrue);
    });

    test('degrades to keyword-only when the endpoint fails', () async {
      // A dead embedding endpoint must not fail the whole query.
      final engine = SearchEngine(
        backend: _FakeBackend(corpus),
        embeddings: _BrokenEmbeddings(),
      );

      final results = await engine.search(const SearchQuery(text: 'clinical'));
      expect(results.map((r) => r.eventId), [r'$1']);
      expect(results.first.matchedSemantic, isFalse);
    });
  });

  group('filters', () {
    test('an impossible filter returns nothing without searching', () async {
      final backend = _FakeBackend(corpus)..filterResult = {};
      final engine = SearchEngine(backend: backend);

      final results = await engine.search(
        const SearchQuery(text: 'clinical', chatIds: {'nope'}),
      );

      expect(results, isEmpty);
      expect(
        backend.keywordQueries,
        isEmpty,
        reason: 'no point searching when the filter already excluded all',
      );
    });

    test('filters-only query browses instead of returning nothing', () async {
      final backend = _FakeBackend(corpus)..filterResult = {2, 3};
      final engine = SearchEngine(backend: backend);

      final results = await engine.search(
        const SearchQuery(text: '', chatIds: {'c1'}),
      );

      expect(results.map((r) => r.eventId), containsAll([r'$2', r'$3']));
    });

    test('an empty query with no filters returns nothing', () async {
      final engine = SearchEngine(backend: _FakeBackend(corpus));
      expect(await engine.search(const SearchQuery(text: '')), isEmpty);
    });
  });
}

/// Convenience for asserting a hit came from both methods.
extension on SearchResult {
  bool get matchedBothMethods => matchedKeyword && matchedSemantic;
}
