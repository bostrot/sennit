import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';
import 'package:weft_store/weft_store.dart';

void main() {
  late WeftDatabase db;
  late SearchStore store;

  setUp(() {
    db = WeftDatabase.openAt(':memory:');
    store = SearchStore(db);
  });

  tearDown(() => db.dispose());

  WeftMessage msg(
    String eventId,
    String body, {
    String roomId = '!room:example.org',
    ChatNetwork network = ChatNetwork.whatsapp,
    String sender = '@peer:example.org',
    int minutesAgo = 0,
    MessageKind kind = MessageKind.text,
    String? transcript,
    String? attachmentUrl,
  }) {
    return WeftMessage(
      eventId: eventId,
      roomId: roomId,
      network: network,
      senderId: sender,
      senderName: 'Peer',
      timestamp: DateTime.utc(
        2026,
        8,
        15,
      ).subtract(Duration(minutes: minutesAgo)),
      kind: kind,
      isOwn: false,
      body: body,
      transcript: transcript,
      attachmentUrl: attachmentUrl,
    );
  }

  group('schema', () {
    test('migrates to the current version', () {
      expect(db.schemaVersion, weftMigrations.length);
    });

    test('re-opening an existing database does not re-run migrations', () {
      final version = db.schemaVersion;
      expect(migrate(db.raw), version);
    });
  });

  group('indexing', () {
    test('indexes a message and queues it for embedding', () {
      store.indexMessage(msg(r'$1', 'the barn near Lüneburg'), chatId: 'c1');

      expect(store.indexedCount, 1);
      expect(store.pendingEmbeddingCount, 1);
    });

    test('re-indexing an edited message replaces rather than duplicates', () {
      final first = store.indexMessage(msg(r'$1', 'original'), chatId: 'c1');
      final second = store.indexMessage(msg(r'$1', 'edited'), chatId: 'c1');

      expect(first, second, reason: 'same event should keep its row id');
      expect(store.indexedCount, 1);
    });

    test('indexes a voice message by its transcript', () async {
      store.indexMessage(
        msg(
          r'$v',
          '',
          kind: MessageKind.voice,
          transcript: 'are we still on for Thursday',
        ),
        chatId: 'c1',
      );

      final hits = await store.keywordSearch('Thursday');
      expect(
        hits,
        hasLength(1),
        reason: 'spoken words must be as findable as typed ones',
      );
    });

    test('removing a message drops it from the keyword index', () async {
      store.indexMessage(msg(r'$1', 'ephemeral'), chatId: 'c1');
      expect(await store.keywordSearch('ephemeral'), hasLength(1));

      store.removeMessage(eventId: r'$1', roomId: '!room:example.org');
      expect(await store.keywordSearch('ephemeral'), isEmpty);
    });
  });

  group('keyword search', () {
    setUp(() {
      store.indexMessages([
        msg(r'$1', 'the clinical trial summary is attached', minutesAgo: 10),
        msg(r'$2', 'lets meet at the barn near Lüneburg', minutesAgo: 20),
        msg(r'$3', 'completely unrelated chatter', minutesAgo: 30),
      ], chatId: 'c1');
    });

    test('finds a message by a word in it', () async {
      final hits = await store.keywordSearch('clinical');
      expect(hits, hasLength(1));
    });

    test('is diacritic insensitive', () async {
      // FTS5's unicode61 tokenizer is configured to fold diacritics, so a user
      // typing "Luneburg" still finds "Lüneburg".
      expect(await store.keywordSearch('Luneburg'), hasLength(1));
      expect(await store.keywordSearch('lüneburg'), hasLength(1));
    });

    test('matches a prefix as the user types', () async {
      expect(await store.keywordSearch('clin'), hasLength(1));
    });

    test('requires all terms', () async {
      expect(await store.keywordSearch('clinical trial'), hasLength(1));
      expect(await store.keywordSearch('clinical barn'), isEmpty);
    });

    test('honours a restrictTo filter', () async {
      final all = await store.keywordSearch('the');
      expect(all.length, greaterThan(1));

      final restricted = await store.keywordSearch(
        'the',
        restrictTo: {all.first.id},
      );
      expect(restricted, hasLength(1));
    });

    // One conversation's search reads the index through `restrictTo`. A word
    // the rest of the index says more often must not push this chat's rows
    // past the limit before the restriction is applied.
    test('restricts before limiting, not after', () async {
      for (var i = 0; i < 5; i++) {
        store.indexMessage(msg('\$elsewhere$i', 'ok ok ok'), chatId: 'other');
      }
      final mine = store.indexMessage(
        msg(r'$mine', 'ok then, a long sentence that dilutes the match'),
        chatId: 'mine',
      );

      final hits = await store.keywordSearch(
        'ok',
        limit: 3,
        restrictTo: {mine},
      );
      expect(hits.map((h) => h.id), [mine]);
    });
  });

  group('FTS query sanitising', () {
    test('quotes tokens so operators cannot leak through', () {
      expect(toFtsMatchQuery('hello world'), '"hello" "world"*');
    });

    test('neutralises FTS5 syntax in user input', () {
      // Each of these is valid FTS5 syntax and would otherwise be a hard error
      // mid-typing rather than a search.
      for (final input in ['foo"bar', 'foo OR', 'a:b', 'x^2', '*', '(']) {
        final result = toFtsMatchQuery(input);
        if (result == null) continue;
        expect(
          () => store.keywordSearch(input),
          returnsNormally,
          reason: 'input "$input" produced $result',
        );
      }
    });

    test('treats a quoted string as a phrase', () {
      expect(toFtsMatchQuery('"exact phrase"'), '"exact phrase"');
    });

    test('returns null when nothing searchable remains', () {
      expect(toFtsMatchQuery('   '), isNull);
      expect(toFtsMatchQuery('***'), isNull);
    });

    test('a phrase search matches only the contiguous phrase', () async {
      store.indexMessages([
        msg(r'$p1', 'the quick brown fox'),
        msg(r'$p2', 'brown the quick fox'),
      ], chatId: 'c1');

      final hits = await store.keywordSearch('"quick brown"');
      expect(hits, hasLength(1));
    });
  });

  group('searching by name', () {
    setUp(() {
      // Anna never says her own name; only the metadata carries it.
      store.indexMessages(
        [msg(r'\$n1', 'sending the summary over')],
        chatId: 'c1',
        chatTitle: 'Anna Maven',
      );
    });

    test('finds a chat by the person it is with', () async {
      final hits = await store.keywordSearch('Anna');
      expect(
        hits,
        hasLength(1),
        reason: 'typing a name must find their conversation',
      );
    });

    test('finds a message by who sent it', () async {
      expect(await store.keywordSearch('Peer'), isNotEmpty);
    });

    test('still finds by body text', () async {
      expect(await store.keywordSearch('summary'), hasLength(1));
    });

    test('a name and a word together still match', () async {
      expect(await store.keywordSearch('Anna summary'), hasLength(1));
    });
  });

  group('filters', () {
    setUp(() {
      store.indexMessages([
        msg(
          r'$w',
          'shared word',
          network: ChatNetwork.whatsapp,
          minutesAgo: 10,
        ),
        msg(r'$s', 'shared word', network: ChatNetwork.signal, minutesAgo: 500),
      ], chatId: 'c1');
      store.indexMessage(
        msg(
          r'$t',
          'shared word',
          network: ChatNetwork.telegram,
          roomId: '!other',
        ),
        chatId: 'c2',
      );
    });

    test('returns null when the query has no filters', () async {
      expect(
        await store.candidateRowIds(const SearchQuery(text: 'shared')),
        isNull,
        reason: 'null means unrestricted, which is not the same as empty',
      );
    });

    test('filters by network', () async {
      final ids = await store.candidateRowIds(
        const SearchQuery(text: 'shared', networks: {ChatNetwork.signal}),
      );
      expect(ids, hasLength(1));
    });

    test('filters by chat', () async {
      final ids = await store.candidateRowIds(
        const SearchQuery(text: 'shared', chatIds: {'c2'}),
      );
      expect(ids, hasLength(1));
    });

    test('filters by date range', () async {
      final ids = await store.candidateRowIds(
        SearchQuery(text: 'shared', after: DateTime.utc(2026, 8, 14, 23)),
      );
      expect(
        ids,
        hasLength(2),
        reason: 'the 500-minute-old message is excluded',
      );
    });

    test('an impossible filter yields an empty set, not null', () async {
      final ids = await store.candidateRowIds(
        const SearchQuery(text: 'shared', chatIds: {'nonexistent'}),
      );
      expect(ids, isNotNull);
      expect(ids, isEmpty);
    });
  });

  group('embeddings', () {
    test('round-trips a quantised vector', () async {
      const provider = HashingEmbeddingProvider(dimensions: 32);
      final rowId = store.indexMessage(msg(r'$1', 'hello there'), chatId: 'c1');

      final vector = provider.embedOne('hello there');
      store.saveEmbedding(
        rowId: rowId,
        vector: vector,
        model: provider.modelId,
      );

      expect(store.pendingEmbeddingCount, 0);

      final stored = await store.streamVectors().toList();
      expect(stored, hasLength(1));
      expect(stored.single.messageRowId, rowId);
      expect(stored.single.vector, vector);
    });

    test('drains the queue in batches', () {
      for (var i = 0; i < 10; i++) {
        store.indexMessage(msg('\$$i', 'message $i'), chatId: 'c1');
      }
      expect(store.nextEmbeddingBatch(limit: 4), hasLength(4));
      expect(store.pendingEmbeddingCount, 10);
    });

    test('a repeatedly failing row stops blocking the queue', () {
      final poison = store.indexMessage(msg(r'$bad', 'poison'), chatId: 'c1');
      store.indexMessage(msg(r'$good', 'fine'), chatId: 'c1');

      for (var i = 0; i < 5; i++) {
        store.recordEmbeddingFailure(poison, 'boom');
      }

      final batch = store.nextEmbeddingBatch();
      expect(
        batch.map((b) => b.rowId),
        isNot(contains(poison)),
        reason: 'exhausted rows must not stall the backfill behind them',
      );
      expect(batch, hasLength(1));
    });

    test('the pending count is only what a backfill can still take', () {
      final poison = store.indexMessage(msg(r'$bad', 'poison'), chatId: 'c1');
      store.indexMessage(msg(r'$blank', '   '), chatId: 'c1');
      store.indexMessage(msg(r'$good', 'fine'), chatId: 'c1');
      for (var i = 0; i < SearchStore.maxEmbeddingAttempts; i++) {
        store.recordEmbeddingFailure(poison, 'boom');
      }

      expect(
        store.pendingEmbeddingCount,
        1,
        reason:
            'an exhausted row and a blank one are never drained, so counting '
            'them keeps "still being embedded" on screen forever',
      );
      expect(store.nextEmbeddingBatch().map((b) => b.body), ['fine']);
    });

    test('announces writes that may have queued embeddings', () async {
      var announced = 0;
      final sub = store.embeddingQueued.listen((_) => announced++);
      addTearDown(sub.cancel);

      store.indexMessage(msg(r'$1', 'one'), chatId: 'c1');
      store.indexMessages([msg(r'$2', 'two')], chatId: 'c1');
      store.reindexEmbeddings();
      await Future<void>.delayed(Duration.zero);

      expect(announced, 3);
    });

    test('editing a message invalidates its stale vector', () async {
      const provider = HashingEmbeddingProvider(dimensions: 32);
      final rowId = store.indexMessage(msg(r'$1', 'original'), chatId: 'c1');
      store.saveEmbedding(
        rowId: rowId,
        vector: provider.embedOne('original'),
        model: provider.modelId,
      );
      expect(await store.streamVectors().toList(), hasLength(1));

      store.indexMessage(msg(r'$1', 'edited'), chatId: 'c1');

      expect(
        await store.streamVectors().toList(),
        isEmpty,
        reason: 'a vector for text that no longer exists would mis-rank',
      );
      expect(store.pendingEmbeddingCount, 1);
    });

    test('reindexing clears every vector and re-queues everything', () async {
      const provider = HashingEmbeddingProvider(dimensions: 32);
      for (var i = 0; i < 3; i++) {
        final rowId = store.indexMessage(msg('\$$i', 'text $i'), chatId: 'c1');
        store.saveEmbedding(
          rowId: rowId,
          vector: provider.embedOne('text $i'),
          model: provider.modelId,
        );
      }
      expect(store.pendingEmbeddingCount, 0);

      store.reindexEmbeddings();

      expect(await store.streamVectors().toList(), isEmpty);
      expect(store.pendingEmbeddingCount, 3);
    });

    test('deleting a message cascades to its vector and queue entry', () async {
      const provider = HashingEmbeddingProvider(dimensions: 32);
      final rowId = store.indexMessage(msg(r'$1', 'temporary'), chatId: 'c1');
      store.saveEmbedding(
        rowId: rowId,
        vector: provider.embedOne('temporary'),
        model: provider.modelId,
      );

      store.removeMessage(eventId: r'$1', roomId: '!room:example.org');

      expect(await store.streamVectors().toList(), isEmpty);
      expect(store.pendingEmbeddingCount, 0);
    });
  });

  group('hydrate', () {
    test('returns rows in fusion order', () async {
      final a = store.indexMessage(msg(r'$a', 'alpha'), chatId: 'c1');
      final b = store.indexMessage(msg(r'$b', 'beta'), chatId: 'c1');

      final results = await store.hydrate([
        FusedHit(id: b, score: 0.9, keywordRank: 1, vectorRank: null),
        FusedHit(id: a, score: 0.5, keywordRank: null, vectorRank: 1),
      ], 'query');

      expect(results.map((r) => r.eventId), [r'$b', r'$a']);
      expect(results.first.matchedKeyword, isTrue);
      expect(results.first.matchedSemantic, isFalse);
      expect(results.last.matchedSemantic, isTrue);
    });

    test('skips ids whose row disappeared mid-query', () async {
      final a = store.indexMessage(msg(r'$a', 'alpha'), chatId: 'c1');

      final results = await store.hydrate([
        FusedHit(id: a, score: 1, keywordRank: 1, vectorRank: null),
        FusedHit(id: 9999, score: 0.5, keywordRank: 2, vectorRank: null),
      ], 'query');

      expect(results, hasLength(1));
    });
  });

  group('re-indexing what is already there', () {
    void embedAll() {
      for (final item in store.nextEmbeddingBatch(limit: 100)) {
        store.saveEmbedding(
          rowId: item.rowId,
          vector: Int8List(4),
          model: 'test',
        );
      }
    }

    test('an unchanged message keeps its embedding and is not re-queued', () {
      final message = msg(r'$a', 'see you at six');
      store.indexMessages([message], chatId: 'chat', chatTitle: 'Peer');
      embedAll();
      expect(store.pendingEmbeddingCount, 0);

      store.indexMessages([message], chatId: 'chat', chatTitle: 'Peer');

      expect(store.pendingEmbeddingCount, 0);
      expect(
        db.raw.select('SELECT COUNT(*) AS c FROM search_embedding').first['c'],
        1,
      );
    });

    test('an edited message is re-queued and loses its old embedding', () {
      store.indexMessages([msg(r'$a', 'see you at six')], chatId: 'chat');
      embedAll();

      store.indexMessages([msg(r'$a', 'see you at seven')], chatId: 'chat');

      expect(store.pendingEmbeddingCount, 1);
      expect(
        db.raw.select('SELECT COUNT(*) AS c FROM search_embedding').first['c'],
        0,
      );
      expect(store.indexedCount, 1);
    });

    test('a message re-filed under a merged chat keeps its embedding', () async {
      final message = msg(r'$a', 'see you at six');
      store.indexMessages([message], chatId: '!room:example.org');
      embedAll();

      store.indexMessages([message], chatId: 'merged:1', chatTitle: 'Anna');

      expect(store.pendingEmbeddingCount, 0);
      final row = db.raw.select(
        'SELECT chat_id, chat_title FROM search_message',
      );
      expect(row.single['chat_id'], 'merged:1');
      expect(row.single['chat_title'], 'Anna');
      // And the new title is searchable, which is what the FTS trigger is for.
      expect(await store.keywordSearch('Anna'), hasLength(1));
    });

    test('a message that was never embedded is still offered for it', () {
      final message = msg(r'$a', 'see you at six');
      store.indexMessages([message], chatId: 'chat');
      db.raw.execute('DELETE FROM embedding_queue');

      store.indexMessages([message], chatId: 'chat');

      expect(store.pendingEmbeddingCount, 1);
    });
  });
}
