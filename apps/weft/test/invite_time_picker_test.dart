import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/calendar_providers.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/chat/invite_time_picker.dart';
import 'package:weft/services/agenda/ics_calendar.dart';

/// Composing an invitation with the user's own calendar in view: the day's
/// busy times in the time picker's header, and a question before a busy time
/// is used.
void main() {
  // 2030-03-04 10:00, so the picker offers 11:00 — inside the meeting below.
  final from = DateTime(2030, 3, 4, 10);

  IcsCalendar meetingAtEleven() => IcsCalendar(
    url: Uri.parse('https://cal.example/a.ics'),
    client: MockClient(
      (_) async => http.Response(
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:m\r\n'
        'DTSTART:20300304T110000\r\nDTEND:20300304T120000\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n',
        200,
      ),
    ),
  );

  /// Pumps a button that runs the picker, and returns where its answer lands.
  Future<List<DateTime?>> pump(
    WidgetTester tester, {
    required IcsCalendar? calendar,
  }) async {
    final results = <DateTime?>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [icsCalendarProvider.overrideWithValue(calendar)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async =>
                    results.add(await pickInviteTime(context, ref, from: from)),
                child: const Text('pick'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();
    // The date picker: keep the offered day.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('the busy times of the day head the time picker', (tester) async {
    await pump(tester, calendar: meetingAtEleven());

    expect(find.text('Busy: 11:00–12:00'), findsOneWidget);
  });

  testWidgets('a busy time is questioned, and can be kept', (tester) async {
    final results = await pump(tester, calendar: meetingAtEleven());

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text("You're busy then"), findsOneWidget);
    expect(find.textContaining('11:00–12:00'), findsWidgets);

    await tester.tap(find.text('Keep this time'));
    await tester.pumpAndSettle();
    expect(results, [DateTime(2030, 3, 4, 11)]);
  });

  testWidgets('picking another time goes back to the clock', (tester) async {
    final results = await pump(tester, calendar: meetingAtEleven());

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick another time'));
    await tester.pumpAndSettle();

    // The time picker again, still showing the day's busy times.
    expect(find.text('Busy: 11:00–12:00'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });

  testWidgets('without a calendar it is the plain date and time', (
    tester,
  ) async {
    final results = await pump(tester, calendar: null);

    expect(find.textContaining('Busy:'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text("You're busy then"), findsNothing);
    expect(results, [DateTime(2030, 3, 4, 11)]);
  });

  testWidgets('a calendar that cannot be read does not block the invite', (
    tester,
  ) async {
    final results = await pump(
      tester,
      calendar: IcsCalendar(
        url: Uri.parse('https://cal.example/a.ics'),
        client: MockClient((_) async => http.Response('', 500)),
      ),
    );

    expect(find.textContaining('Busy:'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(results, [DateTime(2030, 3, 4, 11)]);
  });

  group('describeBusyOnDay', () {
    final day = DateTime(2030, 3, 4);

    test('a block inside the day is its clock span', () {
      expect(
        describeBusyOnDay(
          BusyBlock(
            start: DateTime(2030, 3, 4, 9),
            end: DateTime(2030, 3, 4, 10, 30),
          ),
          day,
          'all day',
        ),
        '09:00–10:30',
      );
    });

    test('a block over midnight is cut at the edges of the day', () {
      expect(
        describeBusyOnDay(
          BusyBlock(
            start: DateTime(2030, 3, 4, 22),
            end: DateTime(2030, 3, 5, 2),
          ),
          day,
          'all day',
        ),
        '22:00–24:00',
      );
    });

    test('a block covering the day is all day', () {
      expect(
        describeBusyOnDay(
          BusyBlock(
            start: DateTime(2030, 3, 3),
            end: DateTime(2030, 3, 6),
            allDay: true,
          ),
          day,
          'all day',
        ),
        'all day',
      );
    });
  });
}
