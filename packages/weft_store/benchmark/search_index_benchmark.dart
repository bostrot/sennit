import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

/// What opening a conversation costs the search index.
///
///   cd packages/weft_store
///   flutter test benchmark/search_index_benchmark.dart
///
/// The chat view files every message it loads, and it loads the same ones
/// again each time the conversation is opened. The two numbers that matter
/// are the second pass over an unchanged page — the common case, and the one
/// that should cost nearly nothing — and how many of those rows it leaves
/// waiting to be embedded again.
void main() {
  test('indexing a page of history, first and second time', () {
    final db = WeftDatabase.openAt(':memory:');
    final store = SearchStore(db);
    addTearDown(db.dispose);

    final page = [
      for (var i = 0; i < 300; i++)
        WeftMessage(
          eventId: '\$event_$i',
          roomId: '!room:example.org',
          network: ChatNetwork.whatsapp,
          senderId: '@peer:example.org',
          senderName: 'Peer',
          timestamp: DateTime.utc(2026, 8, 15).subtract(Duration(minutes: i)),
          kind: MessageKind.text,
          isOwn: false,
          body: 'Message number $i about the plan for Thursday and the review',
        ),
    ];

    double run() {
      final clock = Stopwatch()..start();
      store.indexMessages(page, chatId: 'chat', chatTitle: 'Peer');
      return clock.elapsedMicroseconds / 1000;
    }

    final first = run();
    // The embedder has caught up, as it has by the next visit.
    for (final item in store.nextEmbeddingBatch(limit: page.length)) {
      store.saveEmbedding(
        rowId: item.rowId,
        vector: Int8List(8),
        model: 'bench',
      );
    }
    final again = [for (var i = 0; i < 5; i++) run()]..sort();

    // ignore: avoid_print
    print(
      'BENCH search_index 300 msgs: first ${first.toStringAsFixed(1)}ms, '
      'unchanged re-index ${again[2].toStringAsFixed(1)}ms (median of 5), '
      're-queued for embedding ${store.pendingEmbeddingCount}',
    );
  });
}
