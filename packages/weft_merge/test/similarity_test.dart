import 'package:test/test.dart';
import 'package:weft_merge/weft_merge.dart';

void main() {
  group('jaroWinkler', () {
    test('is 1.0 for identical strings', () {
      expect(jaroWinkler('anna maven', 'anna maven'), 1.0);
    });

    test('is 0.0 when nothing matches', () {
      expect(jaroWinkler('abc', 'xyz'), 0.0);
    });

    test('rewards a shared prefix, which suits personal names', () {
      // Same Jaro base, but the prefix bonus should push the name pair higher.
      expect(
        jaroWinkler('jonathan', 'jon'),
        greaterThan(jaro('jonathan', 'jon')),
      );
    });

    test('rates a nickname/full-name pair above an unrelated pair', () {
      expect(
        jaroWinkler('michael johnson', 'michael johnsen'),
        greaterThan(jaroWinkler('michael johnson', 'sofia martinez')),
      );
    });

    test('handles empty input without throwing', () {
      expect(jaroWinkler('', 'anna'), 0.0);
      expect(jaroWinkler('anna', ''), 0.0);
    });
  });

  group('normalizeName', () {
    test('folds case, accents and punctuation', () {
      expect(normalizeName('Änna  Måven!'), 'aenna maven');
      expect(normalizeName('anna maven'), 'anna maven');
    });

    test('strips emoji and collapses whitespace', () {
      expect(normalizeName('Anna Maven 💼  '), 'anna maven');
    });

    test('folds German sharp s', () {
      expect(normalizeName('Straßer'), 'strasser');
    });

    test('makes cosmetically different bridge names compare equal', () {
      expect(normalizeName('Anna Maven'), normalizeName('anna  maven'));
    });
  });

  group('normalizePhone', () {
    test('accepts international format with separators', () {
      expect(normalizePhone('+49 151 12345678'), '+4915112345678');
      expect(normalizePhone('+49-151-12345678'), '+4915112345678');
    });

    test('treats a 00 prefix as +', () {
      expect(normalizePhone('004915112345678'), '+4915112345678');
    });

    test('applies the trunk prefix rule with a default region', () {
      expect(
        normalizePhone('0151 12345678', defaultCountryCode: '49'),
        '+4915112345678',
      );
    });

    test('extracts the number from a bridge ghost user id', () {
      expect(
        normalizePhone('@whatsapp_4915112345678:example.org'),
        '+4915112345678',
      );
    });

    test('refuses to guess when it cannot be confident', () {
      // No country code and no default region: merging on this would be a coin
      // flip, and a wrong merge mixes two people's conversations.
      expect(normalizePhone('12345'), isNull);
      expect(normalizePhone('0151234', defaultCountryCode: null), isNull);
      expect(normalizePhone('not a phone'), isNull);
      expect(normalizePhone(null), isNull);
    });

    test('rejects numbers outside E.164 length bounds', () {
      expect(normalizePhone('+123456'), isNull);
      expect(normalizePhone('+1234567890123456'), isNull);
    });
  });

  group('normalizeEmail', () {
    test('lowercases and trims valid addresses', () {
      expect(normalizeEmail('  Anna@Example.ORG '), 'anna@example.org');
    });

    test('rejects non-addresses', () {
      expect(normalizeEmail('anna'), isNull);
      expect(normalizeEmail('anna@example'), isNull);
      expect(normalizeEmail(null), isNull);
    });
  });

  group('hammingDistance64', () {
    test('is 0 for identical hashes', () {
      expect(hammingDistance64(0x0F0F0F0F0F0F0F0F, 0x0F0F0F0F0F0F0F0F), 0);
    });

    test('counts differing bits', () {
      expect(hammingDistance64(0x0, 0x1), 1);
      expect(hammingDistance64(0x0, 0xFF), 8);
    });

    test('is correct for negative (high-bit-set) hashes', () {
      expect(hammingDistance64(-1, 0), 64);
      expect(hammingDistance64(-1, -1), 0);
    });
  });
}
