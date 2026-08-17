import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

import 'support/fixtures.dart';

/// One message reaching Weft twice.
///
/// This is the normal case rather than an error: a push wakes the app and the
/// same event comes down `/sync` a second later — or the other way round on a
/// slow network, or three times when the app is foregrounded mid-flight. Both
/// paths call [evaluateNotification] with the same [NotificationDedupe], and
/// this file is where that contract is pinned down.
void main() {
  group('push and sync', () {
    test('a push followed by the sync decides once', () {
      final dedupe = NotificationDedupe();
      final push = decide(dedupe: dedupe);
      final sync = decide(dedupe: dedupe);

      expect(push.delivers, isTrue);
      expect(reasonFor(sync), NotificationSuppression.duplicate);
    });

    test('the sync arriving first makes the push the duplicate', () {
      // Order is not guaranteed and must not matter: whichever path gets there
      // first is the one that posts.
      final dedupe = NotificationDedupe();
      final sync = decide(dedupe: dedupe);
      final push = decide(dedupe: dedupe);

      expect(sync.delivers, isTrue);
      expect(reasonFor(push), NotificationSuppression.duplicate);
    });

    test('a third delivery is still a duplicate', () {
      final dedupe = NotificationDedupe();
      decide(dedupe: dedupe);
      expect(
        reasonFor(decide(dedupe: dedupe)),
        NotificationSuppression.duplicate,
      );
      expect(
        reasonFor(decide(dedupe: dedupe)),
        NotificationSuppression.duplicate,
      );
    });

    test('a suppressed first verdict is still remembered', () {
      // The push path decided not to post; the sync path must not reconsider.
      // Whatever the first answer was, it was *an* answer.
      final dedupe = NotificationDedupe();
      expect(
        reasonFor(decide(message: msg(isOwn: true), dedupe: dedupe)),
        NotificationSuppression.ownMessage,
      );
      expect(
        reasonFor(decide(dedupe: dedupe)),
        NotificationSuppression.duplicate,
      );
    });

    test('a duplicate is reported as a duplicate even when it mentions', () {
      // Dedupe runs before every other rule, so a mention that already broke
      // through a mute once does not break through again.
      final dedupe = NotificationDedupe();
      final mention = msg(body: 'Ada can you look at this');
      expect(decide(message: mention, dedupe: dedupe).mentioned, isTrue);
      expect(
        reasonFor(decide(message: mention, dedupe: dedupe)),
        NotificationSuppression.duplicate,
      );
    });

    test('a different event in the same chat still notifies', () {
      final dedupe = NotificationDedupe();
      expect(
        decide(
          message: msg(eventId: r'$a'),
          dedupe: dedupe,
        ).delivers,
        isTrue,
      );
      expect(
        decide(
          message: msg(eventId: r'$b'),
          dedupe: dedupe,
        ).delivers,
        isTrue,
      );
    });

    test('two messages with identical text are two notifications', () {
      // Keyed on the event id, not on what the message says. "ok" twice is two
      // messages and buzzes twice, which is what the sender meant.
      final dedupe = NotificationDedupe();
      expect(
        decide(
          message: msg(eventId: r'$a', body: 'ok'),
          dedupe: dedupe,
        ).delivers,
        isTrue,
      );
      expect(
        decide(
          message: msg(eventId: r'$b', body: 'ok'),
          dedupe: dedupe,
        ).delivers,
        isTrue,
      );
    });

    test('one event seen through two legs of a merged chat decides once', () {
      // Event ids are globally unique, so the same id reaching evaluation twice
      // is the same message however the caller resolved the conversation —
      // before the merge landed and after it, say. Keying on room + event would
      // have posted this twice.
      final dedupe = NotificationDedupe();
      final event = msg(eventId: r'$shared', roomId: '!wa:example.org');
      expect(
        decide(
          message: event,
          forChat: chat(id: '!wa:example.org'),
          dedupe: dedupe,
        ).delivers,
        isTrue,
      );
      expect(
        reasonFor(
          decide(message: event, forChat: mergedChat(), dedupe: dedupe),
        ),
        NotificationSuppression.duplicate,
      );
    });

    test('without a dedupe the same event decides twice', () {
      // The parameter is optional so a one-shot re-evaluation — a settings
      // change replaying a decision, or a test — gets a pure function back.
      expect(decide().delivers, isTrue);
      expect(decide().delivers, isTrue);
    });

    test('two chats keep their own decisions', () {
      final dedupe = NotificationDedupe();
      expect(
        decide(
          message: msg(eventId: r'$grace', roomId: '!grace:example.org'),
          forChat: chat(id: '!grace:example.org'),
          dedupe: dedupe,
        ).delivers,
        isTrue,
      );
      expect(
        decide(
          message: msg(
            eventId: r'$hopper',
            roomId: '!hopper:example.org',
            network: ChatNetwork.signal,
          ),
          forChat: chat(id: '!hopper:example.org', network: ChatNetwork.signal),
          dedupe: dedupe,
        ).delivers,
        isTrue,
      );
    });
  });

  group('the ledger', () {
    test('remembers the first sighting only', () {
      final dedupe = NotificationDedupe();
      expect(dedupe.remember(r'$a'), isTrue);
      expect(dedupe.remember(r'$a'), isFalse);
      expect(dedupe.contains(r'$a'), isTrue);
      expect(dedupe.length, 1);
    });

    test('evicts oldest first at capacity', () {
      final dedupe = NotificationDedupe(capacity: 2);
      dedupe
        ..remember(r'$a')
        ..remember(r'$b')
        ..remember(r'$c');
      expect(dedupe.length, 2);
      expect(dedupe.contains(r'$a'), isFalse);
      expect(dedupe.contains(r'$c'), isTrue);
    });

    test('re-seeing an id does not refresh it', () {
      // FIFO, not LRU. The only thing that has to be covered is the window
      // between two deliveries of one message, and an id that keeps arriving is
      // not evidence that it will arrive again.
      final dedupe = NotificationDedupe(capacity: 2);
      dedupe
        ..remember(r'$a')
        ..remember(r'$b')
        ..remember(r'$a')
        ..remember(r'$c');
      expect(dedupe.contains(r'$a'), isFalse);
      expect(dedupe.contains(r'$b'), isTrue);
      expect(dedupe.contains(r'$c'), isTrue);
    });

    test('forget lets an event decide again', () {
      // What a dismissed notification does: the user swiped it away, and the
      // next sighting of that event is allowed to post afresh.
      final dedupe = NotificationDedupe();
      expect(decide(dedupe: dedupe).delivers, isTrue);
      dedupe.forget(r'$event_1');
      expect(decide(dedupe: dedupe).delivers, isTrue);
    });

    test('forgetting an id that was never seen is not an error', () {
      final dedupe = NotificationDedupe();
      expect(() => dedupe.forget(r'$never'), returnsNormally);
      expect(dedupe.length, 0);
    });

    test('clear empties the ledger', () {
      // Signing out: the next account's events are not this account's.
      final dedupe = NotificationDedupe()
        ..remember(r'$a')
        ..remember(r'$b');
      dedupe.clear();
      expect(dedupe.length, 0);
      expect(dedupe.contains(r'$a'), isFalse);
    });

    test('a zero capacity is a programming error', () {
      expect(
        () => NotificationDedupe(capacity: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('memory stays bounded over a long-running isolate', () {
      // A background isolate can run for days. The ledger has to cover the gap
      // between a push and its sync, not the history of the account.
      final dedupe = NotificationDedupe();
      for (var i = 0; i < 5000; i++) {
        dedupe.remember('\$event_$i');
      }
      expect(dedupe.length, dedupe.capacity);
      expect(dedupe.contains(r'$event_4999'), isTrue);
      expect(dedupe.contains(r'$event_0'), isFalse);
    });
  });
}
