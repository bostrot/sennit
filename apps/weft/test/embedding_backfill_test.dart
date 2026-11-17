import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/search_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';

/// The search backfill draining on its own.
///
/// It used to run only when the search screen's button was pressed, so the
/// "still being embedded" notice came back on every visit. These run the real
/// `SearchStore` against an in-memory database with a scripted provider, and
/// real timers shortened to milliseconds.
void main() {
  late WeftStores stores;
  late _ScriptedProvider provider;
  late EmbeddingBackfill backfill;

  setUp(() {
    stores = WeftStores.inMemory();
    provider = _ScriptedProvider();
    backfill = EmbeddingBackfill(
      store: stores.search,
      provider: provider,
      settle: const Duration(milliseconds: 1),
      firstRetry: const Duration(milliseconds: 50),
      maxRetry: const Duration(milliseconds: 200),
    );
  });

  tearDown(() {
    backfill.dispose();
    stores.dispose();
  });

  void index(String eventId, String body) => stores.search.indexMessage(
    WeftMessage(
      eventId: eventId,
      roomId: '!room:example.org',
      network: ChatNetwork.whatsapp,
      senderId: '@grace:example.org',
      senderName: 'Grace',
      timestamp: DateTime.utc(2026, 11, 17),
      kind: MessageKind.text,
      isOwn: false,
      body: body,
    ),
    chatId: '!room:example.org',
  );

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('drains what was queued before it started, unasked', () async {
    for (var i = 0; i < 40; i++) {
      index('\$$i', 'message $i');
    }

    backfill.start();
    await until(() => backfill.pending == 0 && !backfill.running);

    expect(provider.embedded, 40);
  });

  test('a newly indexed message is embedded without anyone asking', () async {
    backfill.start();
    await until(() => !backfill.running);

    index(r'$new', 'arrived later');
    await until(() => backfill.pending == 0 && provider.embedded == 1);
  });

  test('an endpoint failure pauses, costs no attempts, and resumes', () async {
    index(r'$1', 'hello');
    index(r'$2', 'there');
    provider.failNext(
      const EmbeddingException(
        'slow down',
        statusCode: 429,
        failure: EmbeddingFailure.rateLimited,
      ),
      times: 6,
    );

    backfill.start();
    await until(() => backfill.pausedReason != null);
    expect(backfill.pending, 2, reason: 'still waiting, not written off');

    // Six refusals is more than the five attempts a row gets: had they been
    // held against the messages, both would be retired for good by now.
    await until(() => backfill.pending == 0);
    expect(backfill.pausedReason, isNull);
    expect(provider.embedded, 2);
  });

  test('only the message the endpoint rejected is held against', () async {
    index(r'$good', 'fine');
    index(r'$bad', 'poison');
    index(r'$also', 'also fine');
    provider.rejects = 'poison';

    backfill.start();
    await until(() => backfill.pending == 0 && !backfill.running);

    expect(provider.embedded, 2);
    expect(backfill.pausedReason, isNull);
    expect(
      stores.search.nextEmbeddingBatch(),
      isEmpty,
      reason: 'the poison row sank past its attempts instead of looping',
    );
  });

  test(
    'an endpoint that rejects every message is paused, not believed',
    () async {
      index(r'$1', 'hello');
      index(r'$2', 'there');
      provider.rejectsAll = true;

      backfill.start();
      await until(() => backfill.pausedReason != null);

      expect(
        stores.search.nextEmbeddingBatch(),
        hasLength(2),
        reason: 'a wrong model name must not retire the whole history',
      );
    },
  );

  test('retryNow ends a pause early', () async {
    index(r'$1', 'hello');
    provider.failNext(const EmbeddingException('unreachable'), times: 1);
    final patient = EmbeddingBackfill(
      store: stores.search,
      provider: provider,
      settle: const Duration(milliseconds: 1),
      firstRetry: const Duration(hours: 1),
    );
    addTearDown(patient.dispose);

    patient.start();
    await until(() => patient.pausedReason != null);

    await patient.retryNow();
    expect(patient.pending, 0);
    expect(patient.pausedReason, isNull);
  });
}

class _ScriptedProvider implements EmbeddingProvider {
  final _inner = const HashingEmbeddingProvider(dimensions: 16);

  int embedded = 0;
  String? rejects;
  bool rejectsAll = false;
  EmbeddingException? _failure;
  int _failures = 0;

  void failNext(EmbeddingException error, {required int times}) {
    _failure = error;
    _failures = times;
  }

  @override
  String get modelId => _inner.modelId;

  @override
  int get dimensions => _inner.dimensions;

  @override
  Future<List<Int8List>> embed(List<String> texts) async {
    if (_failures > 0) {
      _failures--;
      throw _failure!;
    }
    if (rejectsAll || rejects != null && texts.contains(rejects)) {
      throw const EmbeddingException(
        'input rejected',
        statusCode: 400,
        failure: EmbeddingFailure.other,
      );
    }
    embedded += texts.length;
    return _inner.embed(texts);
  }

  @override
  void dispose() {}
}
