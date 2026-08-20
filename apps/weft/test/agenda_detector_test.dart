import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/agenda/event_detector.dart';

void main() {
  // A Wednesday, mid-June, mid-morning.
  final now = DateTime(2026, 6, 17, 10, 0);

  AgendaCandidate? detect(String text) => detectAgendaEvent(text, now: now);

  group('what fires', () {
    test('weekday plus time, English', () {
      final hit = detect('dinner on friday at 19:30?');
      expect(hit, isNotNull);
      expect(hit!.start, DateTime(2026, 6, 19, 19, 30));
      expect(hit.hasTime, isTrue);
      expect(hit.keywordMatched, isTrue);
    });

    test('weekday plus "um X Uhr", German', () {
      final hit = detect('Zahnarzt am Dienstag um 14 Uhr');
      // Tuesday from a Wednesday is next week's Tuesday.
      expect(hit, isNotNull);
      expect(hit!.start, DateTime(2026, 6, 23, 14, 0));
      expect(hit.keywordMatched, isTrue);
    });

    test('tomorrow with am/pm time', () {
      final hit = detect('let\'s meet tomorrow at 5 pm');
      expect(hit, isNotNull);
      expect(hit!.start, DateTime(2026, 6, 18, 17, 0));
    });

    test('German numeric date with keyword and no time', () {
      final hit = detect('Abgabe ist am 30.06.');
      expect(hit, isNotNull);
      expect(hit!.start.day, 30);
      expect(hit.start.month, 6);
      expect(hit.hasTime, isFalse);
      expect(hit.keywordMatched, isTrue);
    });

    test('month-name date rolls into next year when already past', () {
      final hit = detect('the deadline is on May 12');
      expect(hit, isNotNull);
      expect(hit!.start, DateTime(2027, 5, 12, 9, 0));
    });

    test('keyword with bare time means today, or tomorrow when past', () {
      final later = detect('meeting at 15:00');
      expect(later!.start, DateTime(2026, 6, 17, 15, 0));

      final earlier = detect('meeting at 8:00');
      expect(earlier!.start, DateTime(2026, 6, 18, 8, 0));
    });

    test('same weekday names next week, not today', () {
      final hit = detect('besuch am mittwoch um 12:00');
      expect(hit!.start, DateTime(2026, 6, 24, 12, 0));
    });
  });

  group('what stays quiet', () {
    test('plain conversation', () {
      expect(detect('sounds good, thanks!'), isNull);
    });

    test('a number that is not a date', () {
      expect(detect('the bill was 42.50 in the end'), isNull);
    });

    test('a time with no intent and no date', () {
      expect(detect('it was 15:00 degrees somehow'), isNull);
    });

    test('a date with year, no time, no keyword is only a candidate', () {
      // The service layer refers this shape to the local model; the rules
      // alone still produce the candidate so it can be referred at all.
      final hit = detect('wir waren am 12.05.2027 dort');
      expect(hit, isNotNull);
      expect(hit!.keywordMatched, isFalse);
      expect(hit.hasTime, isFalse);
    });
  });
}
