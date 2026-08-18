import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_sms/weft_sms.dart';

void main() {
  const uk = PhoneNumberParser(defaultCountryCode: '44');

  // The scorer as the app runs it, with no SMS-specific tuning whatsoever —
  // if these tests had to loosen a threshold to pass, the claim that SMS needs
  // no merge-engine changes would be false.
  const scorer = MergeScorer();

  /// A bridged handle for [phone], in the shape mautrix-whatsapp produces.
  NetworkHandle whatsapp(
    String phone, {
    String? displayName,
    String? phoneE164,
  }) {
    final digits = phone.replaceAll('+', '');
    return NetworkHandle(
      id: 'whatsapp:$digits',
      network: ChatNetwork.whatsapp,
      remoteId: digits,
      matrixUserId: '@whatsapp_$digits:example.org',
      roomId: '!abcdef:example.org',
      displayName: displayName,
      phoneE164: phoneE164,
    );
  }

  group('linkSmsIdentity shape', () {
    test('produces a handle keyed on the normalised number', () {
      final handle = linkSmsIdentity(
        '01234 567890',
        parser: uk,
        displayName: 'Anna Maven',
        threadId: '7',
      )!;

      expect(handle.id, 'sms:+441234567890');
      expect(handle.network, ChatNetwork.sms);
      expect(handle.remoteId, '+441234567890');
      expect(handle.matrixUserId, '@sms_+441234567890:local');
      expect(handle.roomId, 'sms:thread:7');
      expect(handle.displayName, 'Anna Maven');
      expect(handle.phoneE164, '+441234567890');
      expect(handle.unifiedContactId, isNull);
    });

    test('sets phoneE164 explicitly rather than leaving it to be recovered', () {
      // The scorer would match on remoteId either way. The field is set because
      // the merge UI shows it, and evidence the user can read is evidence they
      // will act on.
      final handle = linkSmsIdentity('+441234567890')!;
      expect(handle.phoneE164, isNotNull);
      expect(handle.phoneE164, handle.remoteId);
    });

    test('leaves the room unset when the thread is not known yet', () {
      expect(linkSmsIdentity('+441234567890')!.roomId, isNull);
    });

    test('upserts rather than multiplies across formats', () {
      // Two syncs, the provider writing the address differently each time. A
      // second id here would grow one node per sync and merge none of them.
      final a = linkSmsIdentity('01234 567890', parser: uk)!;
      final b = linkSmsIdentity('+44 1234 567890', parser: uk)!;

      expect(a.id, b.id);
      expect(a.matrixUserId, b.matrixUserId);
    });
  });

  group('merging an SMS thread with a bridged chat', () {
    test('joins an SMS number to a WhatsApp handle for the same number', () {
      final sms = linkSmsIdentity(
        '+441234567890',
        displayName: 'Anna Maven',
        threadId: '7',
      )!;
      final bridged = whatsapp(
        '+441234567890',
        displayName: 'Anna Maven',
        phoneE164: '+441234567890',
      );

      final candidate = scorer.score(sms, bridged)!;

      expect(candidate.signals, contains(MergeSignal.phoneExact));
      expect(candidate.hasIdentitySignal, isTrue);
      expect(candidate.score, greaterThanOrEqualTo(0.95));
      expect(candidate.explanation, contains('Same phone number'));
    });

    test('merges a national SMS address with an international handle', () {
      // The case the whole normalisation exists for: the provider hands over
      // `01234 567890` and the bridge `441234567890`, and these are one person.
      final sms = linkSmsIdentity('01234 567890', parser: uk)!;
      final bridged = whatsapp('+441234567890');

      final candidate = scorer.score(sms, bridged);

      expect(candidate, isNotNull);
      expect(candidate!.signals, contains(MergeSignal.phoneExact));
    });

    test('matches on the number alone, with no name on either side', () {
      // Bridges frequently expose nothing but the number, and a merge that
      // needed a display name would never fire for those contacts.
      final candidate = scorer.score(
        linkSmsIdentity('+441234567890')!,
        whatsapp('+441234567890'),
      );

      expect(candidate, isNotNull);
      expect(candidate!.signals, [MergeSignal.phoneExact]);
    });

    test('surfaces exactly one suggestion among unrelated handles', () {
      final handles = [
        linkSmsIdentity('+441234567890', threadId: '7')!,
        whatsapp('+441234567890', phoneE164: '+441234567890'),
        whatsapp('+441111222333', phoneE164: '+441111222333'),
        linkSmsIdentity('+441999888777', threadId: '9')!,
      ];

      final candidates = scorer.scoreAll(handles);

      expect(candidates, hasLength(1));
      expect(candidates.single.a.network, ChatNetwork.sms);
      expect(candidates.single.b.network, ChatNetwork.whatsapp);
    });

    test('suggests rather than merges, because SMS numbers get recycled', () {
      // The evidence is strong enough to auto-merge on, and deliberately isn't
      // acted on: a number is recycled, spoofed or shared by a household, and a
      // silent auto-merge on a wrong one mixes two people's conversations with
      // nothing on screen to say it happened.
      const config = MergeScoringConfig();
      expect(config.autoMergeOnIdentitySignal, isFalse);

      final candidate = scorer.score(
        linkSmsIdentity('+441234567890')!,
        whatsapp('+441234567890'),
      )!;
      expect(candidate.hasIdentitySignal, isTrue);
    });
  });

  group('near misses do not merge', () {
    test('rejects a number differing by its last digit', () {
      expect(
        scorer.score(
          linkSmsIdentity('+441234567890')!,
          whatsapp('+441234567891'),
        ),
        isNull,
      );
    });

    test('rejects a transposition', () {
      // Two adjacent digits swapped reads as the same number to anyone
      // skimming, and is somebody else.
      expect(
        scorer.score(
          linkSmsIdentity('+441234567890')!,
          whatsapp('+441234567809'),
        ),
        isNull,
      );
    });

    test('rejects a number that is a prefix of the other', () {
      expect(
        scorer.score(
          linkSmsIdentity('+441234567890')!,
          whatsapp('+44123456789'),
        ),
        isNull,
      );
    });

    test('rejects the same national digits from a different country', () {
      // Same ten digits, two regions, two people — and the reason a national
      // number with no region resolves to nothing at all.
      const us = PhoneNumberParser(defaultCountryCode: '1');
      final ukNumber = linkSmsIdentity('01234 567890', parser: uk)!;
      final usNumber = linkSmsIdentity('01234567890', parser: us)!;

      expect(scorer.score(ukNumber, usNumber), isNull);
    });

    test('does not merge two SMS handles that share only a first name', () {
      // A bare first name is not evidence, and SMS threads carry contact names
      // constantly — without this the inbox would fill with bad suggestions.
      final a = linkSmsIdentity(
        '+441234567890',
        displayName: 'Anna',
        threadId: '7',
      )!;
      final b = linkSmsIdentity(
        '+441999888777',
        displayName: 'Anna',
        threadId: '9',
      )!;

      expect(scorer.score(a, b), isNull);
    });
  });

  group('addresses that are not people', () {
    test('refuses a short code', () {
      // 20202 is a bank, an aggregator, or three of each, and the same digits
      // are a different service in the next country. Merging on one would join
      // every bank alert thread into a single "person".
      for (final code in ['202', '20202', '202020']) {
        expect(linkSmsIdentity(code), isNull, reason: 'linking "$code"');
        expect(linkSmsIdentity(code, parser: uk), isNull, reason: code);
      }
    });

    test('refuses an alphanumeric sender id', () {
      expect(linkSmsIdentity('Vodafone'), isNull);
      expect(linkSmsIdentity('AMAZON', parser: uk), isNull);
    });

    test('refuses an empty or blank address', () {
      // An MMS group row can carry one.
      expect(linkSmsIdentity(''), isNull);
      expect(linkSmsIdentity('   '), isNull);
    });

    test('refuses a national number with no region to anchor it', () {
      // The alternative is guessing a country code, which merges strangers.
      expect(linkSmsIdentity('01234 567890'), isNull);
      expect(linkSmsIdentity('01234 567890', parser: uk), isNotNull);
    });
  });

  group('linkSmsThreadIdentities', () {
    test('contributes one handle per member of a group thread', () {
      const thread = SmsThread(
        id: '7',
        addresses: ['+441234567890', '+441999888777'],
        title: 'Climbing',
      );

      final handles = linkSmsThreadIdentities(thread);

      expect(handles, hasLength(2));
      expect(handles.map((h) => h.roomId), everyElement('sms:thread:7'));
      expect(handles.map((h) => h.id), [
        'sms:+441234567890',
        'sms:+441999888777',
      ]);
    });

    test('does not put the group name on its members', () {
      // A group thread's title names the group, not the person, and a handle
      // called "Climbing" is a name-similarity match waiting to happen.
      const thread = SmsThread(
        id: '7',
        addresses: ['+441234567890', '+441999888777'],
        title: 'Climbing',
      );

      expect(
        linkSmsThreadIdentities(thread).map((h) => h.displayName),
        everyElement(isNull),
      );
    });

    test('borrows a one-to-one thread title as the contact name', () {
      const thread = SmsThread(
        id: '7',
        addresses: ['+441234567890'],
        title: 'Anna Maven',
      );

      expect(linkSmsThreadIdentities(thread).single.displayName, 'Anna Maven');
    });

    test('drops members that resolve to nothing rather than faking them', () {
      // A handle with no number is a node the scorer can only ever match on
      // name, which is how a short code becomes a person by the back door.
      const thread = SmsThread(
        id: '7',
        addresses: ['+441234567890', '20202', 'Vodafone', ''],
      );

      final handles = linkSmsThreadIdentities(thread);

      expect(handles, hasLength(1));
      expect(handles.single.remoteId, '+441234567890');
    });

    test('yields nothing for a thread with no resolvable member', () {
      const thread = SmsThread(id: '7', addresses: ['20202']);
      expect(linkSmsThreadIdentities(thread), isEmpty);
    });

    test('interprets national addresses against the parser it is given', () {
      const thread = SmsThread(id: '7', addresses: ['01234 567890']);

      expect(linkSmsThreadIdentities(thread), isEmpty);
      expect(
        linkSmsThreadIdentities(thread, parser: uk).single.phoneE164,
        '+441234567890',
      );
    });
  });
}
