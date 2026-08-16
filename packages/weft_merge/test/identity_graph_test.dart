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

    test('when opted in, merges identity signals but not soft ones', () {
      final graph = IdentityGraph(
        handles: [
          handle('a', ChatNetwork.whatsapp, phone: '+4915112345678'),
          handle('b', ChatNetwork.signal, phone: '+4915112345678'),
          handle(
            'c',
            ChatNetwork.telegram,
            displayName: 'Michael Johnson',
            avatarDHash: 0x0F0F0F0F0F0F0F0F,
          ),
          handle(
            'd',
            ChatNetwork.discord,
            displayName: 'Michael Johnsen',
            avatarDHash: 0x0F0F0F0F0F0F0F0F,
          ),
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
        reason: 'name + avatar is not strong enough to merge unattended',
      );
    });
  });
}
