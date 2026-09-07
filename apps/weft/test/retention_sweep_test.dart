import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/services/retention/retention_sweeper.dart';
import 'package:weft_domain/weft_domain.dart';

/// What a retention sweep actually deletes, and what it refuses to.
///
/// Against a real database and a real search index — the two things a sweep
/// deletes out of — with only the network stubbed. The interesting cases are
/// all about the difference between *redacting* a message and *forgetting* it,
/// and about what happens when the first of those fails: get either wrong and
/// the failure is silent, permanent and in the user's favour exactly never.
void main() {
  late WeftStores stores;
  late _StubRepository repository;
  late List<String> purgedMedia;

  const own = '@me:example.org';
  const peer = '@peer:example.org';
  const roomId = '!room:example.org';
  const chatId = 'c1';
  final now = DateTime.utc(2026, 5, 1, 12);

  setUp(() {
    stores = WeftStores.inMemory();
    repository = _StubRepository();
    purgedMedia = [];
  });

  tearDown(() => stores.dispose());

  RetentionSweeper sweeper({String? ownUserId = own}) => RetentionSweeper(
    retention: stores.retention,
    search: stores.search,
    repository: repository,
    ownUserId: ownUserId,
    purgeMedia: (eventId) async => purgedMedia.add(eventId),
  );

  void index(
    String eventId, {
    required Duration ago,
    String sender = peer,
    MessageKind kind = MessageKind.text,
    String? attachmentUrl,
  }) {
    stores.search.indexMessage(
      WeftMessage(
        eventId: eventId,
        roomId: roomId,
        network: ChatNetwork.whatsapp,
        senderId: sender,
        senderName: 'Peer',
        timestamp: now.subtract(ago),
        kind: kind,
        isOwn: sender == own,
        body: 'said something in $eventId',
        attachmentUrl: attachmentUrl,
      ),
      chatId: chatId,
    );
  }

  void policy(RetentionPolicy value) =>
      stores.retention.save(RetentionSettings.empty.withChat(chatId, value));

  Future<SweepResult> sweep([RetentionSweeper? s]) =>
      withClock(Clock.fixed(now), () => (s ?? sweeper()).sweepAll());

  test(
    'a chat with no policy loses nothing, however old its messages',
    () async {
      index(r'$ancient', ago: const Duration(days: 900));

      final result = await sweep();

      expect(result, (redacted: 0, forgotten: 0, deferred: 0));
      expect(stores.search.indexedCount, 1);
      expect(repository.calls, isEmpty);
    },
  );

  test('a message inside the window is left alone', () async {
    policy(const RetentionPolicy(after: Duration(hours: 24)));
    index(r'$fresh', ago: const Duration(hours: 2));

    await sweep();

    expect(stores.search.indexedCount, 1);
    expect(stores.retention.purgedCount, 0);
  });

  group('a due message', () {
    setUp(() => policy(const RetentionPolicy(after: Duration(hours: 24))));

    test(
      "of the user's own is redacted for everyone, then forgotten",
      () async {
        index(r'$mine', ago: const Duration(days: 2), sender: own);

        final result = await sweep();

        expect(result.redacted, 1);
        expect(repository.redacted, [r'$mine']);
        expect(repository.forgotten, [r'$mine']);
        expect(stores.search.indexedCount, 0);
        expect(
          stores.retention.isPurged(roomId: roomId, eventId: r'$mine'),
          isTrue,
        );
      },
    );

    test('somebody else\'s is forgotten here and never redacted', () async {
      index(r'$theirs', ago: const Duration(days: 2));

      final result = await sweep();

      expect(result, (redacted: 0, forgotten: 1, deferred: 0));
      expect(
        repository.redacted,
        isEmpty,
        reason:
            'redacting a message the user did not send is not Braid'
            's to do',
      );
      expect(repository.forgotten, [r'$theirs']);
      expect(stores.search.indexedCount, 0);
    });

    test('with media has its staged bytes deleted too', () async {
      index(
        r'$photo',
        ago: const Duration(days: 2),
        kind: MessageKind.image,
        attachmentUrl: 'mxc://example.org/photo',
      );

      await sweep();

      expect(purgedMedia, [r'$photo']);
    });

    test('without media asks for no file deletion', () async {
      index(r'$text', ago: const Duration(days: 2));

      await sweep();

      expect(purgedMedia, isEmpty);
    });

    test('is not redacted when the account is unknown', () async {
      // Before the session restores there is nobody to be. Forgetting locally
      // is the safe half; redacting on a guess would delete somebody else's
      // message for everyone.
      index(r'$mine', ago: const Duration(days: 2), sender: own);

      final result = await sweep(sweeper(ownUserId: null));

      expect(repository.redacted, isEmpty);
      expect(result.forgotten, 1);
    });
  });

  group('when a redaction fails', () {
    setUp(() => policy(const RetentionPolicy(after: Duration(hours: 24))));

    test('a message the room no longer holds is forgotten anyway', () async {
      // The repository's own signal that nothing holds the event: already
      // redacted, or the room was left. Deferring would defer forever.
      repository.redactFailure = StateError('Cannot delete');
      index(r'$gone', ago: const Duration(days: 2), sender: own);

      final result = await sweep();

      expect(result, (redacted: 0, forgotten: 1, deferred: 0));
      expect(stores.search.indexedCount, 0);
    });

    test(
      'an offline failure defers the whole message for the next pass',
      () async {
        repository.redactFailure = Exception('no route to host');
        index(r'$mine', ago: const Duration(days: 2), sender: own);

        final result = await sweep();

        expect(result, (redacted: 0, forgotten: 0, deferred: 1));
        expect(
          stores.search.indexedCount,
          1,
          reason:
              'dropping the row locally would lose the only record that it '
              'still needs redacting on the server',
        );
        expect(stores.retention.purgedCount, 0);
        expect(repository.forgotten, isEmpty);

        // And the retry works.
        repository.redactFailure = null;
        final second = await sweep();
        expect(second.redacted, 1);
        expect(stores.search.indexedCount, 0);
      },
    );
  });

  test('the read anchor waits for the message to have been read', () async {
    policy(
      const RetentionPolicy(
        after: Duration(hours: 1),
        anchor: RetentionAnchor.read,
      ),
    );
    index(r'$unread', ago: const Duration(days: 5));

    expect((await sweep()).forgotten, 0);

    // Read four hours ago, so its hour is long past.
    stores.retention.recordRead(
      chatId: chatId,
      at: now.subtract(const Duration(hours: 4)),
      upTo: now,
    );

    expect((await sweep()).forgotten, 1);
  });

  test('one pass is bounded, and the rest go on the next', () async {
    policy(const RetentionPolicy(after: Duration(hours: 1)));
    for (var i = 0; i < 5; i++) {
      index('\$m$i', ago: Duration(days: 10 - i));
    }

    final bounded = RetentionSweeper(
      retention: stores.retention,
      search: stores.search,
      repository: repository,
      ownUserId: own,
      batchSize: 2,
    );

    expect((await sweep(bounded)).forgotten, 2);
    expect(stores.search.indexedCount, 3);
    expect((await sweep(bounded)).forgotten, 2);
    expect((await sweep(bounded)).forgotten, 1);
    expect(stores.search.indexedCount, 0);
  });

  test('sweeping one chat leaves the others alone', () async {
    policy(const RetentionPolicy(after: Duration(hours: 1)));
    stores.search.indexMessage(
      WeftMessage(
        eventId: r'$elsewhere',
        roomId: '!other:example.org',
        network: ChatNetwork.signal,
        senderId: peer,
        senderName: 'Peer',
        timestamp: now.subtract(const Duration(days: 30)),
        kind: MessageKind.text,
        isOwn: false,
        body: 'in a chat that keeps everything',
      ),
      chatId: 'c2',
    );
    index(r'$here', ago: const Duration(days: 30));

    await sweep();

    expect(stores.search.indexedCount, 1);
    expect(
      stores.retention.isPurged(
        roomId: '!other:example.org',
        eventId: r'$elsewhere',
      ),
      isFalse,
    );
  });
}

/// A repository that records what was asked of it and can be made to fail.
///
/// Extends the demo repository rather than implementing the interface, because
/// a sweep touches exactly the two methods below and the other forty would be
/// forty no-ops to keep in step with an interface that is still growing.
class _StubRepository extends DemoChatRepository {
  final List<String> redacted = [];
  final List<String> forgotten = [];
  final List<String> calls = [];

  /// Thrown by the next [redact]. A `StateError` stands for "no room here
  /// holds it"; anything else for a failure that might not recur.
  Object? redactFailure;

  @override
  Future<void> redact(String chatId, String eventId) async {
    calls.add('redact');
    final failure = redactFailure;
    if (failure != null) throw failure;
    redacted.add(eventId);
  }

  @override
  Future<void> forgetLocally(String roomId, String eventId) async {
    calls.add('forget');
    forgotten.add(eventId);
  }
}
