import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import 'support/fixtures.dart';

void main() {
  const scorer = MergeScorer();

  group('identity signals', () {
    test('a matching phone number alone is enough to suggest', () {
      final candidate = scorer.score(
        handle('a', ChatNetwork.whatsapp, phone: '+4915112345678'),
        handle('b', ChatNetwork.signal, phone: '+49 151 12345678'),
      );

      expect(candidate, isNotNull);
      expect(candidate!.signals, contains(MergeSignal.phoneExact));
      expect(candidate.score, closeTo(0.95, 0.001));
      expect(candidate.hasIdentitySignal, isTrue);
    });

    test('a matching email alone is enough to suggest', () {
      final candidate = scorer.score(
        handle('a', ChatNetwork.slack, email: 'anna@example.org'),
        handle('b', ChatNetwork.email, email: 'Anna@Example.ORG'),
      );

      expect(candidate!.signals, contains(MergeSignal.emailExact));
      expect(candidate.hasIdentitySignal, isTrue);
    });

    test('reads the phone number out of a bridge ghost user id', () {
      final candidate = scorer.score(
        handle('a', ChatNetwork.whatsapp, remoteId: '4915112345678'),
        handle('b', ChatNetwork.signal, phone: '+4915112345678'),
      );

      expect(candidate, isNotNull);
      expect(candidate!.signals, contains(MergeSignal.phoneExact));
    });
  });

  group('weak signals', () {
    test('an identical full name across networks is suggested on its own', () {
      // The realistic case: bridges expose a display name and little else.
      // If this does not cross the bar, no suggestion is ever possible.
      final candidate = scorer.score(
        handle('a', ChatNetwork.whatsapp, displayName: 'Anna Maven'),
        handle('b', ChatNetwork.signal, displayName: 'Anna Maven'),
      );

      expect(candidate, isNotNull);
      expect(candidate!.signals, contains(MergeSignal.nameExact));
      expect(
        candidate.hasIdentitySignal,
        isFalse,
        reason: 'a name is never strong enough to merge unattended',
      );
    });

    test('an identical single-word name is still not evidence', () {
      expect(
        scorer.score(
          handle('a', ChatNetwork.whatsapp, displayName: 'Anna'),
          handle('b', ChatNetwork.telegram, displayName: 'Anna'),
        ),
        isNull,
      );
    });

    test('cosmetic differences still count as identical', () {
      final candidate = scorer.score(
        handle('a', ChatNetwork.whatsapp, displayName: 'Anna Maven'),
        handle('b', ChatNetwork.signal, displayName: 'anna  maven 💼'),
      );
      expect(candidate!.signals, contains(MergeSignal.nameExact));
    });

    test('a similar full name alone is below the suggest threshold', () {
      // 0.50 on its own must not cross 0.55 — one soft signal should never be
      // enough to propose mixing two people's conversations.
      final candidate = scorer.score(
        handle('a', ChatNetwork.whatsapp, displayName: 'Michael Johnson'),
        handle('b', ChatNetwork.telegram, displayName: 'Michael Johnsen'),
      );

      expect(candidate, isNull);
    });

    test('resemblance alone opens no suggestion', () {
      // Similar name plus similar avatar clears the score bar numerically —
      // and is exactly the look-alike drip that made the merge screen feel
      // endless. Without one *exact* signal there is no candidate at all.
      final candidate = scorer.score(
        handle(
          'a',
          ChatNetwork.whatsapp,
          displayName: 'Michael Johnson',
          avatarDHash: 0x0F0F0F0F0F0F0F0F,
        ),
        handle(
          'b',
          ChatNetwork.telegram,
          displayName: 'Michael Johnsen',
          avatarDHash: 0x0F0F0F0F0F0F0F0E,
        ),
      );

      expect(candidate, isNull);
    });

    test('a bare first name is not treated as evidence', () {
      // "Anna" matching "Anna" is far too common to mean anything.
      final candidate = scorer.score(
        handle('a', ChatNetwork.whatsapp, displayName: 'Anna'),
        handle('b', ChatNetwork.telegram, displayName: 'Anna'),
      );

      expect(candidate, isNull);
    });

    test('unrelated people produce no candidate', () {
      final candidate = scorer.score(
        handle('a', ChatNetwork.whatsapp, displayName: 'Anna Maven'),
        handle('b', ChatNetwork.telegram, displayName: 'Sofia Martinez'),
      );

      expect(candidate, isNull);
    });

    test('an avatar beyond the Hamming threshold does not count', () {
      final candidate = scorer.score(
        handle(
          'a',
          ChatNetwork.whatsapp,
          displayName: 'Michael Johnson',
          avatarDHash: 0x0000000000000000,
        ),
        handle(
          'b',
          ChatNetwork.telegram,
          displayName: 'Michael Johnsen',
          avatarDHash: 0x00000000000000FF,
        ),
      );

      expect(candidate, isNull, reason: '8 bits differ, threshold is 6');
    });
  });

  group('scoreAll', () {
    test('ranks strongest evidence first', () {
      final handles = [
        handle(
          'a',
          ChatNetwork.whatsapp,
          displayName: 'Anna Maven',
          phone: '+4915112345678',
        ),
        handle(
          'b',
          ChatNetwork.signal,
          displayName: 'Anna Maven',
          phone: '+4915112345678',
        ),
        handle(
          'c',
          ChatNetwork.telegram,
          displayName: 'Michael Johnson',
          avatarDHash: 0x0F0F0F0F0F0F0F0F,
        ),
        handle(
          'd',
          ChatNetwork.discord,
          // Exact name; the shared avatar raises the score above name alone.
          displayName: 'Michael Johnson',
          avatarDHash: 0x0F0F0F0F0F0F0F0F,
        ),
      ];

      final results = scorer.scoreAll(handles);

      expect(results, hasLength(2));
      expect(results.first.score, greaterThan(results.last.score));
      expect(results.first.signals.first, MergeSignal.phoneExact);
    });

    test('skips pairs the user has already rejected', () {
      final handles = [
        handle('a', ChatNetwork.whatsapp, phone: '+4915112345678'),
        handle('b', ChatNetwork.signal, phone: '+4915112345678'),
      ];

      expect(scorer.scoreAll(handles), hasLength(1));
      expect(
        scorer.scoreAll(handles, rejectedPairs: {pairKey('a', 'b')}),
        isEmpty,
      );
    });

    test('skips pairs already in the same contact', () {
      final handles = [
        handle(
          'a',
          ChatNetwork.whatsapp,
          phone: '+4915112345678',
          contactId: 'c1',
        ),
        handle(
          'b',
          ChatNetwork.signal,
          phone: '+4915112345678',
          contactId: 'c1',
        ),
      ];

      expect(scorer.scoreAll(handles), isEmpty);
    });
  });

  group('pairKey', () {
    test('is order independent', () {
      expect(pairKey('a', 'b'), pairKey('b', 'a'));
    });
  });

  group('configuration', () {
    test('a stricter threshold suppresses combined soft signals', () {
      const strict = MergeScorer(
        config: MergeScoringConfig(suggestThreshold: 0.8),
      );

      final candidate = strict.score(
        handle(
          'a',
          ChatNetwork.whatsapp,
          displayName: 'Michael Johnson',
          avatarDHash: 0x0F0F0F0F0F0F0F0F,
        ),
        handle(
          'b',
          ChatNetwork.telegram,
          displayName: 'Michael Johnsen',
          avatarDHash: 0x0F0F0F0F0F0F0F0F,
        ),
      );

      expect(candidate, isNull, reason: '0.70 is below the raised bar of 0.80');
    });

    test('a default country code lets national numbers match', () {
      const german = MergeScorer(
        config: MergeScoringConfig(defaultCountryCode: '49'),
      );

      final candidate = german.score(
        handle('a', ChatNetwork.whatsapp, phone: '0151 12345678'),
        handle('b', ChatNetwork.signal, phone: '+4915112345678'),
      );

      expect(candidate, isNotNull);
      expect(candidate!.signals, contains(MergeSignal.phoneExact));
    });
  });
}
