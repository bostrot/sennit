import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import 'support/fixtures.dart';

void main() {
  /// Deterministic contact ids so assertions read clearly.
  String Function() counterIds() {
    var n = 0;
    return () => 'c${n++}';
  }

  group('partitioning', () {
    test('an unmerged handle is a contact of size one', () {
      final graph = IdentityGraph(
        handles: [handle('a', ChatNetwork.whatsapp, displayName: 'Anna Maven')],
        idFactory: counterIds(),
      );

      final contacts = graph.contacts();
      expect(contacts, hasLength(1));
      expect(contacts.single.isMerged, isFalse);
      expect(contacts.single.handles, hasLength(1));
    });

    test('only contacts holding more than one handle count as merged', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, displayName: 'Anna Maven'),
          handle('b', ChatNetwork.signal, displayName: 'Anna'),
          handle('c', ChatNetwork.telegram, displayName: 'Ben'),
        ],
        idFactory: counterIds(),
      );

      expect(graph.mergedContactIds(), isEmpty);

      graph.merge('a', 'b');

      expect(graph.mergedContactIds(), {graph.contactIdOf('a')});
      expect(graph.mergedContactIds(), isNot(contains(graph.contactIdOf('c'))));

      graph.unmerge('b');

      expect(graph.mergedContactIds(), isEmpty);
    });

    test('merging two handles yields one contact spanning both networks', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, displayName: 'Anna Maven'),
          handle('b', ChatNetwork.signal, displayName: 'Anna'),
        ],
        idFactory: counterIds(),
      );

      graph.merge('a', 'b');

      final contacts = graph.contacts();
      expect(contacts, hasLength(1));
      expect(contacts.single.networks, [
        ChatNetwork.whatsapp,
        ChatNetwork.signal,
      ]);
      expect(
        contacts.single.displayName,
        'Anna Maven',
        reason: 'the more informative name should win',
      );
    });

    test('merging is transitive across three networks', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp),
          handle('b', ChatNetwork.signal),
          handle('c', ChatNetwork.telegram),
        ],
        idFactory: counterIds(),
      );

      graph.merge('a', 'b');
      graph.merge('b', 'c');

      expect(graph.contacts(), hasLength(1));
      expect(graph.contactIdOf('a'), graph.contactIdOf('c'));
    });

    test('merging two already-merged groups unions both', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp),
          handle('b', ChatNetwork.signal),
          handle('c', ChatNetwork.telegram),
          handle('d', ChatNetwork.discord),
        ],
        idFactory: counterIds(),
      );

      graph.merge('a', 'b');
      graph.merge('c', 'd');
      expect(graph.contacts(), hasLength(2));

      graph.merge('a', 'c');
      expect(graph.contacts(), hasLength(1));
      expect(graph.handlesInContact(graph.contactIdOf('d')!), hasLength(4));
    });
  });

  group('handleFor', () {
    test('resolves a bridge ghost back to its handle and contact', () {
      // The lookup reaction dedupe runs on: an annotation arrives from
      // `@whatsapp_a:example.org`, and the only way to ask whether that ghost
      // is a person already merged with another is to find its handle first.
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp),
          handle('b', ChatNetwork.signal),
        ],
        idFactory: counterIds(),
      );
      graph.merge('a', 'b');

      expect(graph.handleFor('@whatsapp_a:example.org')?.id, 'a');
      expect(
        graph.contactIdForUser('@whatsapp_a:example.org'),
        graph.contactIdForUser('@signal_b:example.org'),
        reason: 'one merged person, one identity, one thumbs-up',
      );
    });

    test('two unmerged handles stay two people', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp),
          handle('b', ChatNetwork.signal),
        ],
        idFactory: counterIds(),
      );

      expect(
        graph.contactIdForUser('@whatsapp_a:example.org'),
        isNot(graph.contactIdForUser('@signal_b:example.org')),
      );
    });

    test('an unknown ghost resolves to nothing rather than to a guess', () {
      // A bridgebot, a group member with no DM, a ghost from a room the graph
      // has never folded. The caller treats null as "their own person": a
      // wrong merge here does not show a bad suggestion, it deletes someone's
      // reaction from the tally.
      final graph = IdentityGraph(
        handles: [handle('a', ChatNetwork.whatsapp)],
        idFactory: counterIds(),
      );

      expect(graph.handleFor('@whatsapp_stranger:example.org'), isNull);
      expect(graph.contactIdForUser('@whatsapp_stranger:example.org'), isNull);
    });

    test('a handle added after construction is findable', () {
      final graph = IdentityGraph(handles: const [], idFactory: counterIds());
      graph.upsertHandle(handle('a', ChatNetwork.whatsapp));

      expect(graph.handleFor('@whatsapp_a:example.org')?.id, 'a');
    });

    test('an unmerge is reflected in the identity, not just the partition', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp),
          handle('b', ChatNetwork.signal),
        ],
        idFactory: counterIds(),
      );
      graph.merge('a', 'b');
      graph.unmerge('b');

      expect(
        graph.contactIdForUser('@whatsapp_a:example.org'),
        isNot(graph.contactIdForUser('@signal_b:example.org')),
      );
    });
  });

  group('unmerge', () {
    test('splits a handle back out into its own contact', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp),
          handle('b', ChatNetwork.signal),
        ],
        idFactory: counterIds(),
      );

      graph.merge('a', 'b');
      graph.unmerge('b');

      expect(graph.contacts(), hasLength(2));
      expect(graph.contactIdOf('a'), isNot(graph.contactIdOf('b')));
    });

    test('sticks — the scorer must not re-suggest what was just undone', () {
      // Without a recorded rejection the phone match would immediately
      // re-propose the merge and the unmerge would look broken.
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, phone: '+4915112345678'),
          handle('b', ChatNetwork.signal, phone: '+4915112345678'),
        ],
        idFactory: counterIds(),
      );

      expect(graph.suggestions(), hasLength(1));

      graph.merge('a', 'b');
      graph.unmerge('b');

      expect(graph.suggestions(), isEmpty);
    });

    test('leaves the remaining group intact', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp),
          handle('b', ChatNetwork.signal),
          handle('c', ChatNetwork.telegram),
        ],
        idFactory: counterIds(),
      );

      graph.merge('a', 'b');
      graph.merge('b', 'c');
      graph.unmerge('c');

      expect(graph.contactIdOf('a'), graph.contactIdOf('b'));
      expect(graph.contactIdOf('c'), isNot(graph.contactIdOf('a')));
    });
  });

  group('decisions', () {
    test('rejecting suppresses the suggestion without changing grouping', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, phone: '+4915112345678'),
          handle('b', ChatNetwork.signal, phone: '+4915112345678'),
        ],
        idFactory: counterIds(),
      );

      graph.reject('a', 'b');

      expect(graph.suggestions(), isEmpty);
      expect(graph.contacts(), hasLength(2));
    });

    test('rehydrates a persisted partition from stored decisions', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp),
          handle('b', ChatNetwork.signal),
        ],
        decisions: [
          MergeDecision(
            pair: pairKey('a', 'b'),
            verdict: MergeVerdict.merged,
            source: MergeDecisionSource.user,
            decidedAt: DateTime.utc(2026, 8, 15),
          ),
        ],
        idFactory: counterIds(),
      );

      expect(graph.contacts(), hasLength(1));
    });

    test('rejects an unknown handle id rather than failing silently', () {
      final graph = IdentityGraph(
        handles: [handle('a', ChatNetwork.whatsapp)],
        idFactory: counterIds(),
      );

      expect(() => graph.merge('a', 'nope'), throwsArgumentError);
    });
  });

  group('auto-merge', () {
    test('is off by default even for an exact phone match', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, phone: '+4915112345678'),
          handle('b', ChatNetwork.signal, phone: '+4915112345678'),
        ],
        idFactory: counterIds(),
      );

      expect(graph.applyAutoMerges(), isEmpty);
      expect(graph.contacts(), hasLength(2));
    });

    test('when opted in, merges only cross-network identical names', () {
      final graph = IdentityGraph(
        handles: [
          // The one shape that merges unattended: the same substantial name
          // on two different messengers.
          handle('a', ChatNetwork.whatsapp, displayName: 'Joanne Trenkel'),
          handle('b', ChatNetwork.signal, displayName: 'Joanne Trenkel'),
          // A shared phone still only *suggests*: shared devices and family
          // numbers are real.
          handle('c', ChatNetwork.telegram, phone: '+4915112345678'),
          handle('d', ChatNetwork.discord, phone: '+4915112345678'),
          // Nearly identical is not identical.
          handle('e', ChatNetwork.telegram, displayName: 'Michael Johnson'),
          handle('f', ChatNetwork.discord, displayName: 'Michael Johnsen'),
        ],
        scorer: const MergeScorer(
          config: MergeScoringConfig(autoMergeOnIdentitySignal: true),
        ),
        idFactory: counterIds(),
      );

      final applied = graph.applyAutoMerges();

      expect(applied, hasLength(1));
      expect(graph.contactIdOf('a'), graph.contactIdOf('b'));
      expect(
        graph.contactIdOf('c'),
        isNot(graph.contactIdOf('d')),
        reason: 'a shared number is a suggestion, never an unattended merge',
      );
      expect(
        graph.contactIdOf('e'),
        isNot(graph.contactIdOf('f')),
        reason: 'a similar name is a suggestion, never an unattended merge',
      );
    });

    test('a middle name on one side only merges on its own', () {
      // The owner's call (item 101): "Joanne Trenkel" on WhatsApp and
      // "Joanne Kristina Trenkel" on Telegram are one person.
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, displayName: 'Joanne Trenkel'),
          handle(
            'b',
            ChatNetwork.telegram,
            displayName: 'joanne kristína TRENKEL',
          ),
          // Single words and same-network namesakes stay apart.
          handle('c', ChatNetwork.instagram, displayName: 'Joanne'),
          handle('d', ChatNetwork.whatsapp, displayName: 'Joanne K. Trenkel'),
        ],
        scorer: const MergeScorer(
          config: MergeScoringConfig(autoMergeOnIdentitySignal: true),
        ),
        idFactory: counterIds(),
      );

      graph.applyAutoMerges();

      expect(graph.contactIdOf('a'), graph.contactIdOf('b'));
      expect(graph.contactIdOf('c'), isNot(graph.contactIdOf('a')));
      expect(
        graph.contactIdOf('d'),
        isNot(graph.contactIdOf('a')),
        reason: 'two WhatsApp chats under one name are two people',
      );
    });

    test('two contacts that both reach someone on one network stay apart', () {
      // a+b are one Anna (WhatsApp, Signal); c is another Anna on WhatsApp
      // who also has Telegram (d). Merging d's contact into a's would put two
      // WhatsApp chats in one person.
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, displayName: 'Anna Maven'),
          handle('b', ChatNetwork.signal, displayName: 'Anna Maven'),
          handle('c', ChatNetwork.whatsapp, displayName: 'Anna Maven'),
          handle('d', ChatNetwork.telegram, displayName: 'Anna Maven'),
        ],
        scorer: const MergeScorer(
          config: MergeScoringConfig(autoMergeOnIdentitySignal: true),
        ),
        idFactory: counterIds(),
      );

      graph.applyAutoMerges();

      final contacts = {
        for (final id in ['a', 'b', 'c', 'd']) graph.contactIdOf(id),
      };
      expect(contacts.length, greaterThanOrEqualTo(2));
      expect(graph.contactIdOf('a'), isNot(graph.contactIdOf('c')));
    });

    test('an unmerged middle-name match is not merged again', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, displayName: 'Joanne Trenkel'),
          handle(
            'b',
            ChatNetwork.telegram,
            displayName: 'Joanne Kristina Trenkel',
          ),
        ],
        scorer: const MergeScorer(
          config: MergeScoringConfig(autoMergeOnIdentitySignal: true),
        ),
        idFactory: counterIds(),
      );

      expect(graph.applyAutoMerges(), hasLength(1));
      graph.unmerge('a');
      expect(graph.applyAutoMerges(), isEmpty);
      expect(graph.suggestions(), isEmpty);
      expect(graph.contactIdOf('a'), isNot(graph.contactIdOf('b')));
    });

    test('a number wearing a name is not name evidence', () {
      // Bridge ghosts without a profile show their phone number as the
      // display name; two strangers formatting alike must not merge.
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, displayName: '+49 151 234 5678'),
          handle('b', ChatNetwork.signal, displayName: '+49 151 234 5678'),
        ],
        scorer: const MergeScorer(
          config: MergeScoringConfig(autoMergeOnIdentitySignal: true),
        ),
        idFactory: counterIds(),
      );

      // The *number* itself is still phone-exact evidence — a suggestion —
      // but nothing merges unattended on it.
      expect(graph.applyAutoMerges(), isEmpty);
    });

    test('an unmerge outlives the scorer: no re-suggest, no re-merge', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, displayName: 'Joanne Trenkel'),
          handle('b', ChatNetwork.signal, displayName: 'Joanne Trenkel'),
        ],
        scorer: const MergeScorer(
          config: MergeScoringConfig(autoMergeOnIdentitySignal: true),
        ),
        idFactory: counterIds(),
      );

      expect(graph.applyAutoMerges(), hasLength(1));
      graph.unmerge('a');

      // The strongest possible evidence still stands — and the user's verdict
      // still wins, pass after pass.
      expect(graph.applyAutoMerges(), isEmpty);
      expect(graph.suggestions(), isEmpty);
      expect(graph.contactIdOf('a'), isNot(graph.contactIdOf('b')));
    });

    test('a rejection silences every handle pair of the same two people', () {
      final graph = IdentityGraph(
        handles: [
          // One person, two handles, already one contact.
          handle('a_wa', ChatNetwork.whatsapp, displayName: 'Anna Maven'),
          handle('a_sg', ChatNetwork.signal, displayName: 'Anna Maven'),
          // The look-alike stranger.
          handle('other', ChatNetwork.telegram, displayName: 'Anna Maven'),
        ],
        idFactory: counterIds(),
      );
      graph.merge('a_wa', 'a_sg');

      // Dismiss the stranger against ONE handle…
      graph.reject('other', 'a_wa');

      // …and the same two people must not come back through the other one.
      expect(
        graph.suggestions().where(
          (c) => c.a.id == 'other' || c.b.id == 'other',
        ),
        isEmpty,
        reason: 'the identical card returned through the second handle',
      );
      expect(graph.applyAutoMerges(), isEmpty);
    });

    test('colliding stored contact ids are split apart on load', () {
      // What the broken id factory wrote: two strangers wearing one contact
      // id with no merge decision anywhere — and a legitimate merged pair,
      // which must survive the repair.
      final graph = IdentityGraph(
        handles: [
          handle(
            'stranger1',
            ChatNetwork.whatsapp,
            displayName: 'Garten',
          ).copyWith(unifiedContactId: 'contact_00'),
          handle(
            'stranger2',
            ChatNetwork.telegram,
            displayName: 'Lin',
          ).copyWith(unifiedContactId: 'contact_00'),
          handle(
            'real_a',
            ChatNetwork.whatsapp,
            displayName: 'Anna Maven',
          ).copyWith(unifiedContactId: 'contact_11'),
          handle(
            'real_b',
            ChatNetwork.signal,
            displayName: 'Anna Maven',
          ).copyWith(unifiedContactId: 'contact_11'),
        ],
        decisions: [
          MergeDecision(
            pair: pairKey('real_a', 'real_b'),
            verdict: MergeVerdict.merged,
            source: MergeDecisionSource.user,
            decidedAt: DateTime(2026, 8, 20),
          ),
        ],
        idFactory: counterIds(),
      );

      expect(
        graph.contactIdOf('stranger1'),
        isNot(graph.contactIdOf('stranger2')),
        reason: 'no decision ever joined them — the id collision did',
      );
      expect(graph.contactIdOf('real_a'), graph.contactIdOf('real_b'));
    });

    test('a fresh id is never one somebody already wears', () {
      // A factory that returns a taken id — the graph must refuse it.
      var calls = 0;
      final graph = IdentityGraph(
        handles: [
          handle(
            'a',
            ChatNetwork.whatsapp,
            displayName: 'Anna Maven',
          ).copyWith(unifiedContactId: 'dup'),
        ],
        idFactory: () => ['dup', 'dup', 'fresh'][calls++],
      );

      graph.upsertHandle(handle('b', ChatNetwork.signal, displayName: 'Ben'));

      expect(graph.contactIdOf('b'), 'fresh');
      expect(graph.contactIdOf('a'), isNot(graph.contactIdOf('b')));
    });

    test('the same name on the same network never merges or suggests', () {
      // Two colleagues named alike on one messenger are two people; a
      // bridge gives one person exactly one handle per network.
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, displayName: 'Anna Schmidt'),
          handle('b', ChatNetwork.whatsapp, displayName: 'Anna Schmidt'),
        ],
        scorer: const MergeScorer(
          config: MergeScoringConfig(autoMergeOnIdentitySignal: true),
        ),
        idFactory: counterIds(),
      );

      expect(graph.applyAutoMerges(), isEmpty);
      expect(graph.suggestions(), isEmpty);
    });
  });

  group('rehydrating with verdicts from another device', () {
    test('an unmerge made elsewhere splits the stored contact', () {
      final a = handle('a', ChatNetwork.whatsapp, displayName: 'Anna');
      final b = handle('b', ChatNetwork.signal, displayName: 'Anna');
      final here = IdentityGraph(handles: [a, b], idFactory: counterIds())
        ..merge('a', 'b');
      expect(here.contactIdOf('a'), here.contactIdOf('b'));

      // The other device's rejection overrules the merge verdict; the stored
      // assignment still says "together".
      final rejected = MergeDecision(
        pair: pairKey('a', 'b'),
        verdict: MergeVerdict.rejected,
        source: MergeDecisionSource.user,
        decidedAt: DateTime.utc(2026),
      );
      final rebuilt = IdentityGraph(
        handles: [
          for (final h in here.handles)
            h.copyWith(unifiedContactId: here.contactIdOf(h.id)),
        ],
        decisions: [rejected],
        idFactory: counterIds(),
      );
      expect(rebuilt.contactIdOf('a'), isNot(rebuilt.contactIdOf('b')));
    });

    test('a merge made elsewhere joins two stored contacts', () {
      final rebuilt = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, displayName: 'Anna'),
          handle('b', ChatNetwork.signal, displayName: 'Ben'),
        ],
        decisions: [
          MergeDecision(
            pair: pairKey('a', 'b'),
            verdict: MergeVerdict.merged,
            source: MergeDecisionSource.user,
            decidedAt: DateTime.utc(2026),
          ),
        ],
        idFactory: counterIds(),
      );
      expect(rebuilt.contactIdOf('a'), rebuilt.contactIdOf('b'));
    });
  });
}
