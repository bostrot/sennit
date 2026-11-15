import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:weft/services/agenda/ics_calendar.dart';

/// The shared calendar: reading an ICS feed into busy times, and what of it
/// the AI features are told.
///
/// Times are compared as instants built the same way the parser builds them —
/// `DateTime.utc(...).toLocal()` for anything with a zone, plain `DateTime(...)`
/// for floating and all-day values — so the suite passes in whatever zone the
/// machine running it is in.
void main() {
  String calendar(String events) =>
      'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\n'
      '$events'
      'END:VCALENDAR\r\n';

  String event(String body) => 'BEGIN:VEVENT\r\n${body}END:VEVENT\r\n';

  List<BusyBlock> busy(String ics, DateTime from, DateTime to) =>
      parseIcs(ics).busyBetween(from, to)
        ..sort((a, b) => a.start.compareTo(b.start));

  final wideFrom = DateTime(2026);
  final wideTo = DateTime(2028);

  group('parsing single events', () {
    test('a UTC event is one block at its instant', () {
      final blocks = busy(
        calendar(
          event(
            'UID:a\r\nDTSTART:20261020T090000Z\r\nDTEND:20261020T103000Z\r\n'
            'SUMMARY:Dentist\r\n',
          ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks, [
        BusyBlock(
          start: DateTime.utc(2026, 10, 20, 9).toLocal(),
          end: DateTime.utc(2026, 10, 20, 10, 30).toLocal(),
        ),
      ]);
    });

    test('a TZID is read in that zone, across daylight saving', () {
      // Berlin is UTC+2 in summer and UTC+1 in winter; the same 09:00 is two
      // different UTC hours either side of the change.
      final blocks = busy(
        calendar(
          event(
                'UID:s\r\nDTSTART;TZID=Europe/Berlin:20260715T090000\r\n'
                'DTEND;TZID=Europe/Berlin:20260715T100000\r\n',
              ) +
              event(
                'UID:w\r\nDTSTART;TZID="Europe/Berlin":20261215T090000\r\n'
                'DTEND;TZID="Europe/Berlin":20261215T100000\r\n',
              ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.map((b) => b.start), [
        DateTime.utc(2026, 7, 15, 7).toLocal(),
        DateTime.utc(2026, 12, 15, 8).toLocal(),
      ]);
    });

    test('an unknown TZID is read as local wall-clock time', () {
      // Outlook writes Windows zone names the tz database does not have.
      final blocks = busy(
        calendar(
          event(
            'UID:o\r\nDTSTART;TZID=W. Europe Standard Time:20261020T140000\r\n'
            'DTEND;TZID=W. Europe Standard Time:20261020T150000\r\n',
          ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.single.start, DateTime(2026, 10, 20, 14));
    });

    test('an all-day event covers its date', () {
      final blocks = busy(
        calendar(
          event(
            'UID:d\r\nDTSTART;VALUE=DATE:20261024\r\n'
            'DTEND;VALUE=DATE:20261025\r\n',
          ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.single.allDay, isTrue);
      expect(blocks.single.start, DateTime(2026, 10, 24));
      expect(blocks.single.end, DateTime(2026, 10, 25));
    });

    test('a DURATION stands in for a missing DTEND', () {
      final block = busy(
        calendar(
          event('UID:p\r\nDTSTART:20261020T090000Z\r\nDURATION:PT1H30M\r\n'),
        ),
        wideFrom,
        wideTo,
      ).single;

      expect(block.end.difference(block.start), const Duration(minutes: 90));
    });

    test('folded lines are unfolded before reading', () {
      final blocks = busy(
        calendar(
          'BEGIN:VEVENT\r\nUID:f\r\nDTSTART:20261020T09\r\n 0000Z\r\n'
          'DTEND:20261020T100000Z\r\nEND:VEVENT\r\n',
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.single.start, DateTime.utc(2026, 10, 20, 9).toLocal());
    });

    test('cancelled, free and zero-length events block nothing', () {
      final blocks = busy(
        calendar(
          event(
                'UID:c\r\nSTATUS:CANCELLED\r\nDTSTART:20261020T090000Z\r\n'
                'DTEND:20261020T100000Z\r\n',
              ) +
              event(
                'UID:t\r\nTRANSP:TRANSPARENT\r\nDTSTART:20261020T110000Z\r\n'
                'DTEND:20261020T120000Z\r\n',
              ) +
              event('UID:z\r\nDTSTART:20261020T130000Z\r\n'),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks, isEmpty);
    });

    test("an alarm's trigger time is not taken for the event's", () {
      final blocks = busy(
        calendar(
          'BEGIN:VEVENT\r\nUID:al\r\n'
          'BEGIN:VALARM\r\nDTSTART:20300101T000000Z\r\nEND:VALARM\r\n'
          'DTSTART:20261020T090000Z\r\nDTEND:20261020T100000Z\r\n'
          'END:VEVENT\r\n',
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.single.start, DateTime.utc(2026, 10, 20, 9).toLocal());
    });

    test('garbage is ignored, not thrown', () {
      final set = parseIcs(
        calendar(
          '${event('UID:x\r\nDTSTART:not-a-date\r\n')}nonsense line\r\n'
          '${event('UID:ok\r\nDTSTART:20261020T090000Z\r\nDTEND:20261020T100000Z\r\n')}',
        ),
      );

      expect(set.length, 1);
    });

    test('only blocks overlapping the window are returned', () {
      final ics = calendar(
        event(
          'UID:a\r\nDTSTART:20261020T090000Z\r\nDTEND:20261020T100000Z\r\n',
        ),
      );
      final at = DateTime.utc(2026, 10, 20, 10).toLocal();

      // Ends exactly where the window starts: not busy.
      expect(busy(ics, at, at.add(const Duration(hours: 1))), isEmpty);
    });
  });

  group('recurring events', () {
    test('a weekly rule on two weekdays, ended by COUNT', () {
      // 2026-10-19 is a Monday.
      final blocks = busy(
        calendar(
          event(
            'UID:r\r\nDTSTART:20261019T080000Z\r\nDTEND:20261019T090000Z\r\n'
            'RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4\r\n',
          ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.map((b) => b.start), [
        DateTime.utc(2026, 10, 19, 8).toLocal(),
        DateTime.utc(2026, 10, 21, 8).toLocal(),
        DateTime.utc(2026, 10, 26, 8).toLocal(),
        DateTime.utc(2026, 10, 28, 8).toLocal(),
      ]);
    });

    test('a daily rule ended by a DATE until includes that day', () {
      final blocks = busy(
        calendar(
          event(
            'UID:d\r\nDTSTART:20261019T150000\r\nDTEND:20261019T160000\r\n'
            'RRULE:FREQ=DAILY;UNTIL=20261021\r\n',
          ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.map((b) => b.start.day), [19, 20, 21]);
    });

    test('a recurrence keeps its wall-clock time across daylight saving', () {
      // Europe/Berlin leaves summer time on 2026-10-25.
      final blocks = busy(
        calendar(
          event(
            'UID:dst\r\nDTSTART;TZID=Europe/Berlin:20261022T090000\r\n'
            'DTEND;TZID=Europe/Berlin:20261022T100000\r\n'
            'RRULE:FREQ=WEEKLY;COUNT=2\r\n',
          ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.map((b) => b.start), [
        DateTime.utc(2026, 10, 22, 7).toLocal(),
        DateTime.utc(2026, 10, 29, 8).toLocal(),
      ]);
    });

    test('EXDATE removes one instance', () {
      final blocks = busy(
        calendar(
          event(
            'UID:e\r\nDTSTART:20261019T080000Z\r\nDTEND:20261019T090000Z\r\n'
            'RRULE:FREQ=DAILY;COUNT=3\r\nEXDATE:20261020T080000Z\r\n',
          ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.map((b) => b.start.toUtc().day), [19, 21]);
    });

    test('a moved instance replaces the one it was moved from', () {
      final blocks = busy(
        calendar(
          event(
                'UID:m\r\nDTSTART:20261019T080000Z\r\nDTEND:20261019T090000Z\r\n'
                'RRULE:FREQ=DAILY;COUNT=2\r\n',
              ) +
              event(
                'UID:m\r\nRECURRENCE-ID:20261020T080000Z\r\n'
                'DTSTART:20261020T140000Z\r\nDTEND:20261020T150000Z\r\n',
              ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.map((b) => b.start), [
        DateTime.utc(2026, 10, 19, 8).toLocal(),
        DateTime.utc(2026, 10, 20, 14).toLocal(),
      ]);
    });

    test('a cancelled instance is taken out of the series', () {
      final blocks = busy(
        calendar(
          event(
                'UID:c\r\nDTSTART:20261019T080000Z\r\nDTEND:20261019T090000Z\r\n'
                'RRULE:FREQ=DAILY;COUNT=3\r\n',
              ) +
              event(
                'UID:c\r\nRECURRENCE-ID:20261020T080000Z\r\nSTATUS:CANCELLED\r\n'
                'DTSTART:20261020T080000Z\r\nDTEND:20261020T090000Z\r\n',
              ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.map((b) => b.start.toUtc().day), [19, 21]);
    });

    test('an open-ended daily rule from years ago still reaches today', () {
      // Over four thousand days before the window: further than a walk from
      // DTSTART would ever get.
      final from = DateTime.utc(2026, 10, 19).toLocal();
      final blocks = busy(
        calendar(
          event(
            'UID:old\r\nDTSTART:20120102T080000Z\r\nDTEND:20120102T090000Z\r\n'
            'RRULE:FREQ=DAILY\r\n',
          ),
        ),
        from,
        from.add(const Duration(days: 3)),
      );

      expect(blocks.map((b) => b.start), [
        DateTime.utc(2026, 10, 19, 8).toLocal(),
        DateTime.utc(2026, 10, 20, 8).toLocal(),
        DateTime.utc(2026, 10, 21, 8).toLocal(),
      ]);
    });

    test('the second Tuesday of every month', () {
      final blocks = busy(
        calendar(
          event(
            'UID:t\r\nDTSTART:20261013T170000Z\r\nDTEND:20261013T180000Z\r\n'
            'RRULE:FREQ=MONTHLY;BYDAY=2TU;COUNT=3\r\n',
          ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.map((b) => b.start.toUtc()), [
        DateTime.utc(2026, 10, 13, 17),
        DateTime.utc(2026, 11, 10, 17),
        DateTime.utc(2026, 12, 8, 17),
      ]);
    });

    test('a monthly rule on the 31st skips the short months', () {
      final blocks = busy(
        calendar(
          event(
            'UID:31\r\nDTSTART:20261031T120000Z\r\nDTEND:20261031T130000Z\r\n'
            'RRULE:FREQ=MONTHLY;COUNT=3\r\n',
          ),
        ),
        wideFrom,
        wideTo,
      );

      expect(blocks.map((b) => b.start.toUtc().month), [10, 12, 1]);
    });

    test('an endless rule is cut at the window, not followed forever', () {
      final from = DateTime.utc(2027, 3, 1).toLocal();
      final blocks = busy(
        calendar(
          event(
            'UID:inf\r\nDTSTART:20200106T080000Z\r\nDTEND:20200106T083000Z\r\n'
            'RRULE:FREQ=WEEKLY\r\n',
          ),
        ),
        from,
        from.add(const Duration(days: 14)),
      );

      expect(blocks, hasLength(2));
    });
  });

  group('mergeBusy', () {
    test('touching and overlapping blocks become one', () {
      final merged = mergeBusy([
        BusyBlock(
          start: DateTime(2026, 1, 1, 11),
          end: DateTime(2026, 1, 1, 12),
        ),
        BusyBlock(
          start: DateTime(2026, 1, 1, 9),
          end: DateTime(2026, 1, 1, 10),
        ),
        BusyBlock(
          start: DateTime(2026, 1, 1, 10),
          end: DateTime(2026, 1, 1, 11),
        ),
        BusyBlock(
          start: DateTime(2026, 1, 1, 14),
          end: DateTime(2026, 1, 1, 15),
        ),
      ]);

      expect(merged, [
        BusyBlock(
          start: DateTime(2026, 1, 1, 9),
          end: DateTime(2026, 1, 1, 12),
        ),
        BusyBlock(
          start: DateTime(2026, 1, 1, 14),
          end: DateTime(2026, 1, 1, 15),
        ),
      ]);
    });
  });

  group('icsUriFrom', () {
    test('webcal becomes https', () {
      expect(
        icsUriFrom(' webcal://cal.example/basic.ics '),
        Uri.parse('https://cal.example/basic.ics'),
      );
    });

    test('http and https are kept, anything else is refused', () {
      expect(icsUriFrom('http://cal.local/a.ics')?.scheme, 'http');
      expect(icsUriFrom('ftp://cal.example/a.ics'), isNull);
      expect(icsUriFrom('not a url'), isNull);
      expect(icsUriFrom(''), isNull);
      expect(icsUriFrom(null), isNull);
    });
  });

  group('icsUrisFrom', () {
    test('one address per line, the unusable and the repeated left out', () {
      expect(
        icsUrisFrom(
          'webcal://cal.example/work.ics\n'
          'not a url\n'
          '\n'
          ' https://cal.example/home.ics \n'
          'https://cal.example/work.ics',
        ),
        [
          Uri.parse('https://cal.example/work.ics'),
          Uri.parse('https://cal.example/home.ics'),
        ],
      );
    });

    test('a single stored address still reads as one calendar', () {
      expect(icsUrisFrom('https://cal.example/a.ics'), hasLength(1));
      expect(icsUrisFrom(''), isEmpty);
      expect(icsUrisFrom(null), isEmpty);
    });
  });

  group('IcsCalendarGroup', () {
    final work = calendar(
      event('UID:a\r\nDTSTART:20261020T090000\r\nDTEND:20261020T100000\r\n'),
    );
    // The same UID as the work calendar's event, on purpose.
    final home = calendar(
      '${event('UID:a\r\nDTSTART:20261020T093000\r\nDTEND:20261020T110000\r\n')}'
      '${event('UID:b\r\nDTSTART:20261021T180000\r\nDTEND:20261021T190000\r\n')}',
    );

    IcsCalendar cal(String name, http.Client client) => IcsCalendar(
      url: Uri.parse('https://cal.example/$name.ics'),
      client: client,
    );
    http.Client serving(String feed) =>
        MockClient((_) async => http.Response(feed, 200));

    test('busy in any calendar is busy, merged across them', () async {
      final group = IcsCalendarGroup([
        cal('work', serving(work)),
        cal('home', serving(home)),
      ]);

      expect((await group.load()).length, 3);
      expect(
        await group.busyBetween(DateTime(2026, 10, 20), DateTime(2026, 10, 22)),
        [
          BusyBlock(
            start: DateTime(2026, 10, 20, 9),
            end: DateTime(2026, 10, 20, 11),
          ),
          BusyBlock(
            start: DateTime(2026, 10, 21, 18),
            end: DateTime(2026, 10, 21, 19),
          ),
        ],
      );
    });

    test('one unreadable calendar fails the answer, not half of it', () async {
      final group = IcsCalendarGroup([
        cal('work', serving(work)),
        cal('home', MockClient((_) async => http.Response('gone', 404))),
      ]);

      await expectLater(group.load(), throwsA(isA<IcsFetchException>()));
      // …and so the AI is told nothing rather than "free at all other times".
      expect(
        await calendarContextFor(
          calendar: group,
          enabled: true,
          transcript: const ['Grace: are you free on Tuesday?'],
          clock: () => DateTime(2026, 10, 17, 12),
        ),
        isNull,
      );
    });
  });

  group('IcsCalendar', () {
    final feed = calendar(
      event('UID:a\r\nDTSTART:20261020T090000Z\r\nDTEND:20261020T100000Z\r\n'),
    );

    test('fetches once and answers from memory until it is old', () async {
      var requests = 0;
      var now = DateTime(2026, 10, 17, 12);
      final cal = IcsCalendar(
        url: Uri.parse('https://cal.example/a.ics'),
        client: MockClient((_) async {
          requests++;
          return http.Response(feed, 200);
        }),
        now: () => now,
      );

      await cal.load();
      await cal.load();
      expect(requests, 1);

      now = now.add(const Duration(minutes: 16));
      await cal.load();
      expect(requests, 2);
    });

    test('two callers at once share one request', () async {
      var requests = 0;
      final gate = Completer<void>();
      final cal = IcsCalendar(
        url: Uri.parse('https://cal.example/a.ics'),
        client: MockClient((_) async {
          requests++;
          await gate.future;
          return http.Response(feed, 200);
        }),
      );

      final both = Future.wait([cal.load(), cal.load()]);
      gate.complete();
      await both;

      expect(requests, 1);
    });

    test('a failed refresh answers from the last good copy', () async {
      var fail = false;
      var now = DateTime(2026, 10, 17, 12);
      final cal = IcsCalendar(
        url: Uri.parse('https://cal.example/a.ics'),
        client: MockClient(
          (_) async => fail ? http.Response('', 503) : http.Response(feed, 200),
        ),
        now: () => now,
      );

      await cal.load();
      fail = true;
      now = now.add(const Duration(hours: 1));

      expect((await cal.load()).length, 1);
    });

    test('a server error with nothing cached is an IcsFetchException', () {
      final cal = IcsCalendar(
        url: Uri.parse('https://cal.example/a.ics'),
        client: MockClient((_) async => http.Response('', 404)),
      );

      expect(cal.load(), throwsA(isA<IcsFetchException>()));
    });

    test('a page that is not a calendar is refused', () {
      final cal = IcsCalendar(
        url: Uri.parse('https://cal.example/a.ics'),
        client: MockClient(
          (_) async => http.Response('<html>Sign in</html>', 200),
        ),
      );

      expect(cal.load(), throwsA(isA<IcsFetchException>()));
    });
  });

  group('what the AI is told', () {
    final now = DateTime(2026, 10, 17, 21, 10);

    test('busy times as ISO days and clocks, and nothing else', () {
      final section = calendarPromptSection([
        BusyBlock(
          start: DateTime(2026, 10, 19, 9),
          end: DateTime(2026, 10, 19, 10, 30),
        ),
        BusyBlock(
          start: DateTime(2026, 10, 24),
          end: DateTime(2026, 10, 25),
          allDay: true,
        ),
        // Outside the two weeks: left out.
        BusyBlock(
          start: DateTime(2026, 12, 1, 9),
          end: DateTime(2026, 12, 1, 10),
        ),
      ], now: now);

      expect(section, contains('It is now Sat 2026-10-17 21:10.'));
      expect(section, contains('until Sat 2026-10-31 21:10'));
      expect(section, contains('- Mon 2026-10-19 09:00–10:30'));
      expect(section, contains('- Sat 2026-10-24 all day'));
      expect(section, isNot(contains('2026-12-01')));
    });

    test('an empty calendar says the user is free', () {
      final section = calendarPromptSection(const [], now: now);

      expect(section, contains('free all of that time'));
    });

    test('a very busy calendar shortens the window, not the list', () {
      final blocks = [
        for (var i = 0; i < kCalendarAiMaxBlocks + 5; i++)
          BusyBlock(
            start: now.add(Duration(hours: 3 * i + 1)),
            end: now.add(Duration(hours: 3 * i + 2)),
          ),
      ];

      final section = calendarPromptSection(blocks, now: now);
      final cut = blocks[kCalendarAiMaxBlocks].start;

      expect('\n- '.allMatches(section), hasLength(kCalendarAiMaxBlocks));
      expect(
        section,
        contains(
          '${cut.hour.toString().padLeft(2, '0')}:'
          '${cut.minute.toString().padLeft(2, '0')}:',
        ),
      );
    });

    group('mentionsScheduling', () {
      bool asks(List<String> lines) => mentionsScheduling(lines, now: now);

      test('questions about time, in the shipped languages', () {
        expect(asks(['Grace: are you free on Friday?']), isTrue);
        expect(asks(['Grace: Hast du morgen Zeit?']), isTrue);
        expect(asks(['Grace: tu es dispo demain ?']), isTrue);
        expect(asks(['Grace: ¿cuándo quedamos?']), isTrue);
        expect(asks(['Grace: 你明天有空吗？']), isTrue);
        expect(asks(['Grace: lunch 24.10.?']), isTrue);
      });

      test('chat that is not about time', () {
        expect(asks(['Grace: lol', 'You: haha']), isFalse);
        expect(asks(['Grace: did you see the photos']), isFalse);
        // A word *containing* a keyword is not the keyword.
        expect(asks(['Grace: freedom is overrated']), isFalse);
      });

      test('only the newest lines count', () {
        expect(
          asks([
            'Grace: free on Friday?',
            'You: yes',
            'Grace: great',
            'You: see the photos?',
            'Grace: lovely',
          ]),
          isFalse,
        );
      });
    });

    group('calendarContextFor', () {
      IcsCalendar cal(http.Client client) => IcsCalendar(
        url: Uri.parse('https://cal.example/a.ics'),
        client: client,
      );
      final ok = MockClient(
        (_) async => http.Response(
          calendar(
            event(
              'UID:a\r\nDTSTART:20261019T090000\r\nDTEND:20261019T100000\r\n',
            ),
          ),
          200,
        ),
      );
      const asking = ['Grace: are you free on Monday?'];

      test('a scheduling question gets the section', () async {
        final section = await calendarContextFor(
          calendar: cal(ok),
          enabled: true,
          transcript: asking,
          clock: () => now,
        );

        expect(section, contains('- Mon 2026-10-19 09:00–10:00'));
      });

      test('nothing without a calendar, when off, or off-topic', () async {
        expect(
          await calendarContextFor(
            calendar: null,
            enabled: true,
            transcript: asking,
            clock: () => now,
          ),
          isNull,
        );
        expect(
          await calendarContextFor(
            calendar: cal(ok),
            enabled: false,
            transcript: asking,
            clock: () => now,
          ),
          isNull,
        );
        expect(
          await calendarContextFor(
            calendar: cal(ok),
            enabled: true,
            transcript: const ['Grace: lol'],
            clock: () => now,
          ),
          isNull,
        );
      });

      test('an unreachable calendar is no calendar, not an error', () async {
        final section = await calendarContextFor(
          calendar: cal(MockClient((_) async => throw const _Offline())),
          enabled: true,
          transcript: asking,
          clock: () => now,
        );

        expect(section, isNull);
      });

      test('a calendar slower than the deadline is skipped', () async {
        final never = Completer<http.Response>();
        final section = await calendarContextFor(
          calendar: cal(MockClient((_) => never.future)),
          enabled: true,
          transcript: asking,
          clock: () => now,
          timeout: const Duration(milliseconds: 20),
        );

        expect(section, isNull);
      });
    });
  });
}

class _Offline implements Exception {
  const _Offline();
}
