import 'package:test/test.dart';
import 'package:weft_sms/weft_sms.dart';

void main() {
  group('encoding detection', () {
    test('keeps plain Latin text in GSM-7', () {
      expect(segmentMessage('on my way').encoding, SmsEncoding.gsm7);
      expect(segmentMessage('').encoding, SmsEncoding.gsm7);
      expect(
        segmentMessage(r'''!"#$%&'()*+,-./0123456789:;<=>?@''').encoding,
        SmsEncoding.gsm7,
      );
    });

    test('keeps the accented characters GSM 03.38 actually has', () {
      // The basic table is not ASCII: it carries a specific set of European
      // letters and symbols, and treating them as "unicode" would double the
      // cost of ordinary German, Spanish and Scandinavian messages.
      for (final body in ['über', 'Ça va', 'año', 'Grüße', '£10', '¿qué?']) {
        expect(
          segmentMessage(body).encoding,
          SmsEncoding.gsm7,
          reason: 'encoding "$body"',
        );
      }
    });

    test('drops to UCS-2 for one character outside the table', () {
      // 'à' is in GSM 03.38 and 'á' is not — which is exactly the kind of
      // distinction no user can be expected to make, and the reason the
      // composer has to show the result rather than explain the rule.
      expect(segmentMessage('à').encoding, SmsEncoding.gsm7);
      expect(segmentMessage('á').encoding, SmsEncoding.ucs2);

      // The everyday case: a curly apostrophe pasted from a word processor.
      expect(segmentMessage("don't").encoding, SmsEncoding.gsm7);
      expect(segmentMessage('don’t').encoding, SmsEncoding.ucs2);

      expect(segmentMessage('ok 👍').encoding, SmsEncoding.ucs2);
      expect(segmentMessage('日本語').encoding, SmsEncoding.ucs2);
    });

    test('treats a literal ESC as unicode, since it is not a character', () {
      // 0x1B introduces the extension table rather than printing, so a body
      // containing one cannot be sent as GSM-7 at all.
      expect(segmentMessage('\u001B').encoding, SmsEncoding.ucs2);
    });

    test('reports the drop to unicode on its own', () {
      // The user can usually fix it by deleting one character and cannot
      // possibly guess which one without being told.
      expect(segmentMessage('hello').isUnicode, isFalse);
      expect(segmentMessage('hello ’').isUnicode, isTrue);
    });
  });

  group('GSM-7 counting', () {
    test('counts an ordinary body against the 160-septet capacity', () {
      final plan = segmentMessage('on my way');

      expect(plan.encoding, SmsEncoding.gsm7);
      expect(plan.units, 9);
      expect(plan.segments, 1);
      expect(plan.unitsPerSegment, 160);
      expect(plan.remainingInLastSegment, 151);
      expect(plan.isMultipart, isFalse);
    });

    test('bills the empty body as the one segment it would cost', () {
      final plan = segmentMessage('');

      expect(plan.units, 0);
      expect(plan.segments, 1);
      expect(plan.remainingInLastSegment, 160);
    });

    test('holds exactly 160 in one segment and spills at 161', () {
      final full = segmentMessage('a' * 160);
      expect(full.segments, 1);
      expect(full.remainingInLastSegment, 0);

      // Not 160 + 1: the concatenation header costs seven septets out of every
      // segment, so one character over the line re-cuts the whole message into
      // two segments of 153.
      final spilled = segmentMessage('a' * 161);
      expect(spilled.segments, 2);
      expect(spilled.units, 161);
      expect(spilled.unitsPerSegment, 153);
      expect(spilled.remainingInLastSegment, 153 - 8);
      expect(spilled.isMultipart, isTrue);
    });

    test('counts further segments at 153', () {
      expect(segmentMessage('a' * 306).segments, 2);
      expect(segmentMessage('a' * 306).remainingInLastSegment, 0);
      expect(segmentMessage('a' * 307).segments, 3);
      expect(segmentMessage('a' * 459).segments, 3);
      expect(segmentMessage('a' * 460).segments, 4);
    });
  });

  group('extended GSM characters', () {
    test('cost two septets each', () {
      // The euro sign is the one users hit constantly with no idea it is
      // double-width; braces and backslashes hurt anyone pasting code.
      for (final c in ['€', '{', '}', '[', ']', '~', '|', '\\', '^']) {
        expect(segmentMessage(c).units, 2, reason: 'counting "$c"');
        expect(
          segmentMessage(c).encoding,
          SmsEncoding.gsm7,
          reason: 'counting "$c"',
        );
      }
    });

    test('halve the capacity of a body made of them', () {
      // 80 braces is 160 septets — a full single segment from 80 typed
      // characters, where 80 letters would have used half of it.
      final full = segmentMessage('{' * 80);
      expect(full.units, 160);
      expect(full.segments, 1);
      expect(full.remainingInLastSegment, 0);

      expect(segmentMessage('{' * 81).segments, 2);
      expect(segmentMessage('{' * 81).units, 162);
    });

    test('are never split across a segment boundary', () {
      // An escape sequence whose ESC lands in one segment and whose character
      // lands in the next renders as garbage on the receiving handset, so the
      // odd septet is left unused and the pair starts the next segment.
      //
      // 152 letters then 77 braces is 306 septets, which a plain division by
      // 153 would call two segments. It is three, because segment one can only
      // hold 152 of its 153 septets and every later segment only 152 of its.
      final plan = segmentMessage('a' * 152 + '{' * 77);

      expect(plan.units, 306);
      expect(plan.segments, 3);
      expect((plan.units / plan.unitsPerSegment).ceil(), 2);
    });

    test('pad rather than overfill when the boundary falls mid-pair', () {
      // Same shape, one segment smaller: 152 letters plus 76 braces is 304
      // septets in two segments, the second of which is exactly full.
      final plan = segmentMessage('a' * 152 + '{' * 76);

      expect(plan.units, 304);
      expect(plan.segments, 2);
      expect(plan.remainingInLastSegment, 1);
    });
  });

  group('UCS-2 counting', () {
    test('counts UTF-16 code units against the 70-unit capacity', () {
      final plan = segmentMessage('don’t');

      expect(plan.encoding, SmsEncoding.ucs2);
      expect(plan.units, 5);
      expect(plan.segments, 1);
      expect(plan.unitsPerSegment, 70);
      expect(plan.remainingInLastSegment, 65);
    });

    test('holds exactly 70 in one segment and spills at 71', () {
      final full = segmentMessage('é' * 69 + '’');
      expect(full.encoding, SmsEncoding.ucs2);
      expect(full.units, 70);
      expect(full.segments, 1);

      final spilled = segmentMessage('é' * 70 + '’');
      expect(spilled.segments, 2);
      expect(spilled.unitsPerSegment, 67);
    });

    test('makes one stray character triple the cost of a full message', () {
      // 160 characters is one free segment as GSM-7 and three billable ones the
      // moment a single curly quote joins them. This is the number the composer
      // exists to show.
      expect(segmentMessage('a' * 160).segments, 1);

      final unicode = segmentMessage('a' * 159 + '’');
      expect(unicode.encoding, SmsEncoding.ucs2);
      expect(unicode.units, 160);
      expect(unicode.segments, 3);
      expect(unicode.remainingInLastSegment, 41);
    });

    test('counts an emoji as the surrogate pair it is', () {
      // Outside the BMP, so two UTF-16 code units, not one character.
      final plan = segmentMessage('😀');

      expect(plan.units, 2);
      expect(plan.segments, 1);
      expect(plan.remainingInLastSegment, 68);
    });

    test('never splits a surrogate pair across a boundary', () {
      // A lone surrogate is not a character at all — the receiving handset
      // shows a replacement box for the first half and another for the second.
      //
      // 67 emoji is 134 code units, which a plain division by 67 would call two
      // segments. It is three: only 33 pairs fit in each 67-unit segment.
      final plan = segmentMessage('😀' * 67);

      expect(plan.units, 134);
      expect(plan.segments, 3);
      expect((plan.units / plan.unitsPerSegment).ceil(), 2);
      expect(plan.remainingInLastSegment, 65);
    });

    test('mixes emoji and text without losing count', () {
      final plan = segmentMessage('ok 👍');
      expect(plan.units, 5); // 'o', 'k', ' ', and one pair
      expect(plan.segments, 1);
    });
  });

  group('SegmentPlan value semantics', () {
    test('equals another plan for the same body', () {
      expect(segmentMessage('a' * 200), segmentMessage('b' * 200));
      expect(
        segmentMessage('a' * 200).hashCode,
        segmentMessage('b' * 200).hashCode,
      );
    });

    test('differs when the cost differs', () {
      expect(segmentMessage('a' * 160), isNot(segmentMessage('a' * 161)));
      expect(segmentMessage('a' * 70), isNot(segmentMessage('’' * 70)));
    });

    test('describes itself for the composer indicator', () {
      expect(segmentMessage('hi').toString(), contains('GSM-7'));
      expect(segmentMessage('hi').toString(), contains('1 segment'));
      expect(segmentMessage('a' * 200).toString(), contains('2 segments'));
      expect(segmentMessage('😀').toString(), contains('UCS-2'));
    });
  });
}
