import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/services/agenda/ics_calendar.dart';
import 'package:weft/services/ai/auto_reply_writer.dart';

import 'support/auto_reply_fakes.dart';

/// The whole road from an `.ics` address to the words an auto-reply is
/// written from, with nothing stubbed between the two HTTP calls.
///
/// Every seam on it has its own test; this is the one that fails when two of
/// them stop agreeing — a transcript the gate no longer recognises, a section
/// the prompt no longer carries.
void main() {
  const room = '!room:example.org';

  // Floating times, so the test reads the same in every zone it runs in.
  const ics =
      'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n'
      'BEGIN:VEVENT\r\nUID:one\r\nSUMMARY:Dentist\r\n'
      'DTSTART:20260116T090000\r\nDTEND:20260116T100000\r\nEND:VEVENT\r\n'
      'BEGIN:VEVENT\r\nUID:weekly\r\nSUMMARY:Team sync\r\n'
      'DTSTART:20251103T140000\r\nDTEND:20251103T150000\r\n'
      'RRULE:FREQ=WEEKLY;BYDAY=MO\r\nEND:VEVENT\r\n'
      'BEGIN:VEVENT\r\nUID:free\r\nSUMMARY:Birthday\r\nTRANSP:TRANSPARENT\r\n'
      'DTSTART:20260117T120000\r\nDTEND:20260117T130000\r\nEND:VEVENT\r\n'
      'END:VCALENDAR\r\n';

  // A Thursday morning.
  final now = DateTime(2026, 1, 15, 10);

  final chat = Chat(
    id: room,
    title: 'Grace',
    unreadCount: 1,
    sources: const [ChatSource(roomId: room, network: ChatNetwork.whatsapp)],
  );

  WeftMessage msg(String body) => WeftMessage(
    eventId: r'$in',
    roomId: room,
    network: ChatNetwork.whatsapp,
    senderId: '@whatsapp_grace:example.org',
    senderName: 'Grace',
    timestamp: DateTime.utc(2026, 1, 15, 9),
    kind: MessageKind.text,
    isOwn: false,
    body: body,
  );

  const away = AutoReplyRule(
    id: 'away',
    name: 'Away',
    prompt: 'Answer for me while I am out.',
    enabled: true,
  );

  /// Runs one incoming [body] through the service against the calendar above
  /// and returns the calendar section the model was handed, plus how often
  /// the calendar server was asked.
  Future<(String?, int)> calendarHandedOver(
    String body, {
    bool enabled = true,
  }) async {
    var fetches = 0;
    final calendar = IcsCalendar(
      url: Uri.parse('https://cal.example/a.ics'),
      client: MockClient((_) async {
        fetches++;
        return http.Response(ics, 200);
      }),
      now: () => now,
    );
    addTearDown(calendar.dispose);

    final h = buildAutoReplyService(
      chat: chat,
      rules: const [away],
      calendar: (transcript) => calendarContextFor(
        calendar: calendar,
        enabled: enabled,
        transcript: transcript,
        clock: () => now,
      ),
    );
    addTearDown(h.incoming.close);
    addTearDown(h.service.dispose);

    await h.service.handleMessage(msg(body));
    expect(h.transport.sent, hasLength(1));
    return (h.composer.calendars.single, fetches);
  }

  test('a question about time is answered from the fetched calendar', () async {
    final (section, fetches) = await calendarHandedOver(
      'Hast du am Freitag um 9 Zeit?',
    );

    expect(fetches, 1);
    expect(section, contains('It is now Thu 2026-01-15 10:00.'));
    expect(section, contains('- Fri 2026-01-16 09:00–10:00'));
    // The weekly series, expanded into the fortnight ahead.
    expect(section, contains('- Mon 2026-01-19 14:00–15:00'));
    expect(section, contains('- Mon 2026-01-26 14:00–15:00'));
    // Marked free in the calendar, so it blocks nothing.
    expect(section, isNot(contains('2026-01-17')));
    // Times only: what the user is busy with never leaves the device.
    expect(section, isNot(contains('Dentist')));
    expect(section, isNot(contains('Team sync')));

    // And the writer puts that section in front of the model.
    late Map<String, Object?> sent;
    final draft = await composeAutoReply(
      baseUrl: 'http://llm.test/v1',
      model: 'small',
      instruction: away.prompt,
      chatTitle: chat.title,
      transcript: const ['Grace: Hast du am Freitag um 9 Zeit?'],
      calendar: section,
      client: MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content':
                      '${kAutoReplyOpen}Um 9 nicht, ab 10 gern.'
                      '$kAutoReplyClose',
                },
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final system =
        ((sent['messages']! as List).first as Map)['content'] as String;
    expect(system, contains('- Fri 2026-01-16 09:00–10:00'));
    expect(system, contains('answer from this calendar'));
    expect(draft.text, 'Um 9 nicht, ab 10 gern.');
  });

  test('small talk does not send the week along', () async {
    final (section, fetches) = await calendarHandedOver('haha, stimmt');
    expect(section, isNull);
    expect(fetches, 0);
  });

  test('the calendar switched off for AI is never fetched', () async {
    final (section, fetches) = await calendarHandedOver(
      'are you free on Friday?',
      enabled: false,
    );
    expect(section, isNull);
    expect(fetches, 0);
  });
}
