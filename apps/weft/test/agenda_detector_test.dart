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

  group('titles', () {
    test('the date and time are cut out of the title', () {
      expect(detect('Zahnarzt am Dienstag um 14:30')!.title, 'Zahnarzt');
      expect(detect('dinner on friday at 19:30?')!.title, 'Dinner');
      expect(detect('let\'s meet tomorrow at 5 pm')!.title, 'Let\'s meet');
      expect(detect('Abgabe ist am 30.06.')!.title, 'Abgabe');
      expect(detect('the deadline is on May 12')!.title, 'The deadline');
      expect(
        detect('Kino mit Anna übermorgen um 20 Uhr, okay?')!.title,
        'Kino mit Anna, okay',
      );
    });

    test('words on both sides of the date are kept', () {
      expect(
        detect('Meeting on Monday at 10:00 with the design team')!.title,
        'Meeting with the design team',
      );
    });

    test('a message that is all date keeps its own words', () {
      expect(agendaTitleFor('Morgen um 9?'), 'Morgen um 9?');
    });
  });

  group('the day it resolves to', () {
    // Tue 24 Nov 2026, 08:17 in Berlin — the reported message.
    final tuesday = DateTime(2026, 11, 24, 8, 17);

    test('"Guten Morgen" is a greeting, not tomorrow', () {
      final hit = detectAgendaEvent(
        'Guten Morgen! Der Termin am Donnerstag ist bestätigt. '
        'Danke fürs Türe öffnen. Lg Christina',
        now: tuesday,
      );
      expect(hit, isNotNull);
      expect(hit!.start, DateTime(2026, 11, 26, 9, 0));
      expect(hit.hasTime, isFalse);
      expect(hit.title, isNot(contains('Donnerstag')));
    });

    test('the noun "Morgen" names no day', () {
      for (final text in [
        'Guten Morgen, Termin am Freitag',
        'Termin am Freitag, schönen Morgen noch',
        'am Morgen ist der Termin am Freitag',
        'jeden Morgen Termin, auch am Freitag',
      ]) {
        expect(
          detectAgendaEvent(text, now: tuesday)!.start,
          DateTime(2026, 11, 27, 9, 0),
          reason: text,
        );
      }
      expect(
        detectAgendaEvent('heute Morgen um 10 Uhr Termin', now: tuesday)!.start,
        DateTime(2026, 11, 24, 10, 0),
      );
    });

    test('morgen as tomorrow still counts', () {
      for (final text in [
        'Termin morgen um 9',
        'Morgen um 14:00 beim Arzt',
        'Guten Morgen! Treffen wir uns morgen um 15 Uhr?',
        'morgen früh Termin',
      ]) {
        expect(
          detectAgendaEvent(text, now: tuesday)!.start.day,
          25,
          reason: text,
        );
      }
    });

    test('relative words, German and English', () {
      final cases = {
        'Termin heute': DateTime(2026, 11, 24),
        'meeting today': DateTime(2026, 11, 24),
        'Termin morgen': DateTime(2026, 11, 25),
        'meeting tomorrow': DateTime(2026, 11, 25),
        'Termin übermorgen': DateTime(2026, 11, 26),
        'meeting the day after tomorrow': DateTime(2026, 11, 26),
        'Termin am Donnerstag': DateTime(2026, 11, 26),
        'Termin nächsten Donnerstag': DateTime(2026, 11, 26),
        'Termin diesen Freitag': DateTime(2026, 11, 27),
        'meeting next thursday': DateTime(2026, 11, 26),
        'meeting this friday': DateTime(2026, 11, 27),
        'Termin Donnerstagabend': DateTime(2026, 11, 26),
        'Termin in zwei Wochen': DateTime(2026, 12, 8),
        'Termin in 3 Tagen': DateTime(2026, 11, 27),
        'meeting in two weeks': DateTime(2026, 12, 8),
        'meeting in a week': DateTime(2026, 12, 1),
        'Termin am 3.12.': DateTime(2026, 12, 3),
        'Termin am 3. Dezember': DateTime(2026, 12, 3),
        'meeting on December 3rd': DateTime(2026, 12, 3),
        'meeting on 3 December': DateTime(2026, 12, 3),
        'Termin am 24.11.': DateTime(2026, 11, 24),
      };
      cases.forEach((text, day) {
        final hit = detectAgendaEvent(text, now: tuesday);
        expect(hit, isNotNull, reason: text);
        final start = hit!.start;
        expect(DateTime(start.year, start.month, start.day), day, reason: text);
      });
    });

    test('every weekday from every weekday', () {
      // 23–29 Nov 2026 is Monday to Sunday.
      for (var from = 0; from < 7; from++) {
        final sent = DateTime(2026, 11, 23 + from, 12);
        for (var to = 0; to < 7; to++) {
          // The same weekday is next week's; "this"/"diesen" makes it today.
          final ahead = to == from ? 7 : (to - from) % 7;
          final expected = DateTime(2026, 11, 23 + from + ahead, 9);
          for (final names in [_en, _de]) {
            final hit = detectAgendaEvent('Termin am ${names[to]}', now: sent);
            expect(
              hit!.start,
              expected,
              reason: '${names[to]} said on ${names[from]}',
            );
          }
          expect(
            detectAgendaEvent('meeting this ${_en[to]}', now: sent)!.start,
            DateTime(2026, 11, 23 + from + (to - from) % 7, 9),
            reason: 'this ${_en[to]} said on ${_en[from]}',
          );
        }
      }
    });

    test('days are counted on the calendar across DST changes', () {
      // EU summer time ends Sun 25 Oct 2026 and starts Sun 28 Mar 2027.
      final fallBack = DateTime(2026, 10, 24, 23, 30);
      expect(
        detectAgendaEvent('Termin morgen', now: fallBack)!.start,
        DateTime(2026, 10, 25, 9),
      );
      expect(
        detectAgendaEvent('Termin übermorgen', now: fallBack)!.start,
        DateTime(2026, 10, 26, 9),
      );
      expect(
        detectAgendaEvent('Termin am Montag', now: fallBack)!.start,
        DateTime(2026, 10, 26, 9),
      );
      final springForward = DateTime(2027, 3, 27, 23, 30);
      expect(
        detectAgendaEvent('Termin am Montag', now: springForward)!.start,
        DateTime(2027, 3, 29, 9),
      );
      expect(
        detectAgendaEvent('Termin in einer Woche', now: springForward)!.start,
        DateTime(2027, 4, 3, 9),
      );
      // A bare time already past rolls to the next calendar day, not 24h on.
      expect(
        detectAgendaEvent(
          'meeting at 8:00',
          now: DateTime(2026, 10, 25, 10),
        )!.start,
        DateTime(2026, 10, 26, 8),
      );
    });

    test('just before and after midnight', () {
      final lateMonday = DateTime(2026, 11, 23, 23, 59);
      final earlyTuesday = DateTime(2026, 11, 24, 0, 1);
      expect(
        detectAgendaEvent('Termin morgen', now: lateMonday)!.start,
        DateTime(2026, 11, 24, 9),
      );
      expect(
        detectAgendaEvent('Termin morgen', now: earlyTuesday)!.start,
        DateTime(2026, 11, 25, 9),
      );
      expect(
        detectAgendaEvent('Termin am Dienstag', now: lateMonday)!.start,
        DateTime(2026, 11, 24, 9),
      );
      expect(
        detectAgendaEvent('Termin am Dienstag', now: earlyTuesday)!.start,
        DateTime(2026, 12, 1, 9),
      );
      // Month and year ends.
      expect(
        detectAgendaEvent(
          'Termin morgen',
          now: DateTime(2026, 12, 31, 22),
        )!.start,
        DateTime(2027, 1, 1, 9),
      );
    });

    test('a UTC send time is read on the local calendar', () {
      final sent = DateTime.utc(2026, 11, 24, 7, 17);
      final local = sent.toLocal();
      final hit = detectAgendaEvent('Termin morgen', now: sent);
      expect(hit!.start, DateTime(local.year, local.month, local.day + 1, 9));
    });
  });
}

const _en = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];
const _de = [
  'Montag',
  'Dienstag',
  'Mittwoch',
  'Donnerstag',
  'Freitag',
  'Samstag',
  'Sonntag',
];
