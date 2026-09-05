import 'package:test/test.dart';
import 'package:weft_autoreply/weft_autoreply.dart';

import 'support/fixtures.dart';

/// The ledger is the only mutable thing in this package, and the only thing
/// standing between a hard cap and a process that runs for a week.
///
/// Two properties, then: it remembers long enough for the cap to mean anything,
/// and it forgets fast enough that a phone left on does not accumulate an entry
/// per conversation for ever.
void main() {
  group('recording and reading back', () {
    test('an empty ledger has nothing to say about any conversation', () {
      final ledger = AutoReplyLedger();

      expect(ledger.repliesIn('!room:example.org', now: now), isEmpty);
      expect(ledger.conversationCount, 0);
    });

    test('a recorded reply comes back for its own conversation only', () {
      final ledger = AutoReplyLedger()
        ..record('!a:example.org', sent(ruleId: 'holiday'));

      expect(ledger.repliesIn('!a:example.org', now: now), hasLength(1));
      expect(
        ledger.repliesIn('!a:example.org', now: now).single.ruleId,
        'holiday',
      );
      expect(ledger.repliesIn('!b:example.org', now: now), isEmpty);
    });

    test('the list it hands out cannot be written through', () {
      // The cap is read off this list. A caller that could append to it could
      // also clear it.
      final ledger = AutoReplyLedger()..record('!a:example.org', sent());

      expect(
        () => ledger.repliesIn('!a:example.org', now: now).add(sent()),
        throwsUnsupportedError,
      );
    });

    test('entries come back oldest first', () {
      final ledger = AutoReplyLedger()
        ..record(
          '!a:example.org',
          sent(ruleId: 'first', ago: const Duration(minutes: 20)),
        )
        ..record(
          '!a:example.org',
          sent(ruleId: 'second', ago: const Duration(minutes: 5)),
        );

      expect(
        ledger
            .repliesIn('!a:example.org', now: now)
            .map((r) => r.ruleId)
            .toList(),
        ['first', 'second'],
      );
    });
  });

  group('forgetting', () {
    test('an entry older than the retention is not returned', () {
      final ledger = AutoReplyLedger()
        ..record(
          '!a:example.org',
          sent(ago: kAutoReplyCapWindow + const Duration(minutes: 1)),
        );

      expect(ledger.repliesIn('!a:example.org', now: now), isEmpty);
    });

    test('an entry exactly at the retention edge is still returned', () {
      // The cap must not be steppable over by arriving on the boundary second.
      final ledger = AutoReplyLedger()
        ..record('!a:example.org', sent(ago: kAutoReplyCapWindow));

      expect(ledger.repliesIn('!a:example.org', now: now), hasLength(1));
    });

    test('recording prunes what the new entry has outlived', () {
      final ledger = AutoReplyLedger();
      for (var i = 0; i < 5; i++) {
        ledger.record(
          '!a:example.org',
          sent(ago: kAutoReplyCapWindow * 2 + Duration(minutes: i)),
        );
      }
      ledger.record('!a:example.org', sent());

      // Only the fresh one survives, and the growth is bounded by writes rather
      // than by a timer nobody would remember to start.
      expect(ledger.repliesIn('!a:example.org', now: now), hasLength(1));
    });

    test('pruning drops a conversation whose last entry expired', () {
      final ledger = AutoReplyLedger()
        ..record('!a:example.org', sent(ago: const Duration(minutes: 5)))
        ..record('!b:example.org', sent(ago: const Duration(minutes: 5)));

      expect(ledger.conversationCount, 2);

      ledger.prune(now.add(kAutoReplyCapWindow + const Duration(minutes: 6)));

      expect(ledger.conversationCount, 0);
    });

    test('pruning keeps a conversation with something live in it', () {
      final ledger = AutoReplyLedger()
        ..record('!a:example.org', sent(ago: const Duration(minutes: 50)))
        ..record('!a:example.org', sent(ago: const Duration(minutes: 1)));

      ledger.prune(now.add(const Duration(minutes: 20)));

      expect(ledger.conversationCount, 1);
      expect(ledger.repliesIn('!a:example.org', now: now), hasLength(1));
    });

    test('clear forgets everything', () {
      final ledger = AutoReplyLedger()..record('!a:example.org', sent());

      ledger.clear();

      expect(ledger.conversationCount, 0);
    });
  });

  group('the ledger and the cap together', () {
    test('three replies in the hour close the conversation to a fourth', () {
      final ledger = AutoReplyLedger();
      for (var i = 0; i < kAutoReplyMaxPerConversation; i++) {
        ledger.record('!room:example.org', sent(ago: Duration(minutes: i + 1)));
      }

      final decision = decide(
        forChat: state(
          recentReplies: ledger.repliesIn('!room:example.org', now: now),
        ),
      );

      expect(decision.refusal, AutoReplyRefusal.conversationCap);
    });

    test('waiting out the window opens it again', () {
      final ledger = AutoReplyLedger();
      for (var i = 0; i < kAutoReplyMaxPerConversation; i++) {
        ledger.record('!room:example.org', sent(ago: Duration(minutes: i + 1)));
      }
      final later = now.add(kAutoReplyCapWindow + const Duration(minutes: 1));

      final decision = decide(
        when: later,
        forChat: state(
          recentReplies: ledger.repliesIn('!room:example.org', now: later),
        ),
      );

      expect(decision.willReply, isTrue);
    });
  });

  group('newestAutoReply', () {
    test('is null for an empty ledger', () {
      expect(newestAutoReply(const []), isNull);
    });

    test('does not assume the list is sorted', () {
      // The ledger keeps it sorted; a helper that quietly relied on that would
      // break the first time something appended out of order.
      final newest = newestAutoReply([
        sent(ruleId: 'middle', ago: const Duration(minutes: 10)),
        sent(ruleId: 'newest', ago: const Duration(minutes: 1)),
        sent(ruleId: 'oldest', ago: const Duration(minutes: 40)),
      ]);

      expect(newest?.ruleId, 'newest');
    });
  });
}
