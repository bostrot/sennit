import 'package:test/test.dart';
import 'package:weft_sms/weft_sms.dart';

void main() {
  // The device's home region. Every SMS address the provider hands over is
  // interpreted against exactly one of these, which is why it is parser state.
  const uk = PhoneNumberParser(defaultCountryCode: '44');
  const us = PhoneNumberParser(defaultCountryCode: '1');
  const nowhere = PhoneNumberParser();

  group('normalisation across formats', () {
    test('folds every way one UK number gets written onto one value', () {
      // This list is not hypothetical: the bridge writes the first, the SMS
      // provider the second or third, and the contacts app the rest. If any one
      // of them landed on a different string, the SMS thread and the WhatsApp
      // chat for this person would sit side by side in the inbox forever.
      const written = [
        '+441234567890',
        '+44 1234 567890',
        '01234 567890',
        '(01234) 567890',
        '01234-567890',
        '00441234567890',
        '  +441234567890  ',
      ];

      for (final raw in written) {
        expect(uk.parse(raw)?.value, '+441234567890', reason: 'parsing "$raw"');
      }
    });

    test('reads a number back out of a bridge ghost user id', () {
      // smsGhostUserId mints this shape on purpose. Anything that treats an SMS
      // handle like a bridged one — and the merge scorer does, it normalises
      // `phoneE164 ?? remoteId` — has to get the number back out.
      expect(nowhere.parse('@sms_+441234567890:local')?.value, '+441234567890');
      expect(
        nowhere.parse('@whatsapp_441234567890:example.org')?.value,
        '+441234567890',
      );
    });

    test('keeps an international number regardless of the region', () {
      // A `+` is unambiguous, so the region must not touch it. A parser set to
      // the US reading a UK number is the everyday case of someone travelling.
      expect(us.parse('+441234567890')?.value, '+441234567890');
      expect(nowhere.parse('+441234567890')?.value, '+441234567890');
      expect(uk.parse('+15551234567')?.value, '+15551234567');
    });

    test('interprets a national number against its own region', () {
      // Same ten digits, two countries, two different people. This is the whole
      // reason the region is carried rather than guessed.
      expect(us.parse('5551234567')?.value, '+15551234567');
      expect(uk.parse('01234 567890')?.value, '+441234567890');
    });

    test('is idempotent, so re-parsing a stored value is safe', () {
      final once = uk.parse('01234 567890')!;
      expect(uk.parse(once.value), once);
      expect(nowhere.parse(once.value), once);
    });
  });

  group('short codes', () {
    test('are recognised across the commercial length range', () {
      for (final code in ['202', '2020', '20202', '202020']) {
        final parsed = uk.parse(code);
        expect(parsed?.value, code, reason: 'parsing "$code"');
        expect(parsed!.isShortCode, isTrue, reason: 'parsing "$code"');
      }
    });

    test('are detected before normalisation, not after', () {
      // The order is the point. `normalizePhone` with a region set would read
      // `20202` as a national number and prefix it into a plausible-looking
      // +4420202 — turning every bank alert into a "person" who can be merged.
      expect(uk.parse('20202')?.value, '20202');
      expect(us.parse('20202')?.value, '20202');
      expect(nowhere.parse('20202')?.value, '20202');
    });

    test('stop at seven digits, which is a subscriber number', () {
      final parsed = uk.parse('2020202');
      expect(parsed!.isShortCode, isFalse);
      expect(parsed.value, startsWith('+'));
    });

    test('do not start with a trunk or international prefix', () {
      // `0…` and `00…` are dialling prefixes, and both are the normaliser's
      // business rather than a short code.
      expect(uk.parse('020202')!.isShortCode, isFalse);
      expect(uk.parse('002020')?.value, isNot('2020'));
    });

    test('are bare adjacent digits, so a spaced number stays a number', () {
      // `202 02` is a badly formatted real number far more often than it is a
      // short code, and guessing wrong in this direction only costs a merge.
      expect(uk.parse('202 02')!.isShortCode, isFalse);
      // A short code is never dialled internationally, so `+` plus five digits
      // is not one — and it is not a valid E.164 number either.
      expect(uk.parse('+20202'), isNull);
    });

    test('are told apart by the leading plus alone', () {
      // isShortCode is derived rather than stored: a second field saying the
      // same thing could disagree with the string it describes.
      expect(uk.parse('20202')!.isShortCode, isTrue);
      expect(uk.parse('+441234567890')!.isShortCode, isFalse);
    });

    test('compare equal across regions, which is why they are not evidence', () {
      // The same five digits are a different service in each country, and this
      // type cannot tell. linkSmsIdentity refuses short codes for exactly this
      // reason rather than trusting the comparison below.
      expect(uk.parse('20202'), us.parse('20202'));
    });
  });

  group('unparseable input', () {
    test('returns null rather than throwing', () {
      // Null is a normal outcome here, not an error path: the caller shows the
      // raw string and skips the identity work.
      const unparseable = [
        null,
        '',
        '   ',
        'Vodafone', // alphanumeric sender id
        'AMAZON',
        '-', // MMS group row with no usable address
        '+', // a plus and nothing else
      ];

      for (final raw in unparseable) {
        expect(uk.parse(raw), isNull, reason: 'parsing "$raw"');
      }
    });

    test('refuses a national number with no region to anchor it', () {
      // Guessing a country code merges strangers, so no region means no answer.
      expect(nowhere.parse('01234 567890'), isNull);
      expect(nowhere.parse('5551234567'), isNull);
    });

    test('refuses an eleven-digit national number with no region', () {
      // The regression the orientation turned up: this used to fall through
      // every branch and return "+01234567890", which is not E.164 — no country
      // code starts with 0 — and which *compares*, folding the same national
      // digits dialled in two countries onto one person.
      expect(nowhere.parse('01234567890'), isNull);
      expect(nowhere.parse('01234567890')?.value, isNot(startsWith('+0')));
    });

    test('refuses numbers too short or too long to be real', () {
      expect(uk.parse('20'), isNull); // shorter than a short code
      expect(uk.parse('+1234'), isNull); // below the E.164 floor
      expect(uk.parse('+1234567890123456'), isNull); // above the 15-digit cap
    });
  });

  group('equality', () {
    test('treats the three spellings of one number as one number', () {
      final a = uk.parse('+441234567890')!;
      final b = uk.parse('01234 567890')!;
      final c = uk.parse('+44 1234 567890')!;

      expect(a, b);
      expect(b, c);
      expect(a.hashCode, b.hashCode);
      expect({a, b, c}, hasLength(1));
    });

    test('separates numbers that differ by a digit', () {
      // A transposition is the near miss that matters: it looks like the same
      // person to a human skimming the inbox and is not one.
      expect(uk.parse('+441234567890'), isNot(uk.parse('+441234567891')));
      expect(uk.parse('+441234567890'), isNot(uk.parse('+441234567809')));
      // A prefix of a number is not that number.
      expect(uk.parse('+441234567890'), isNot(uk.parse('+44123456789')));
    });

    test('separates the same national digits dialled in different regions', () {
      expect(uk.parse('01234 567890'), isNot(us.parse('01234567890')));
    });

    test('is not equal to a plain string or another type', () {
      final number = uk.parse('+441234567890')!;
      expect(number == Object(), isFalse);
      expect(number.toString(), '+441234567890');
    });
  });
}
