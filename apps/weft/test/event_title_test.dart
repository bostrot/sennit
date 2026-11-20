import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/services/ai/event_title.dart';

void main() {
  http.Client answering(String content, {int status = 200}) =>
      MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': content},
              },
            ],
          }),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

  Future<String?> ask(http.Client client) => suggestEventTitle(
    baseUrl: 'http://llm.test/v1/',
    model: 'small',
    transcript: const ['>> Lea: Zahnarzt am Dienstag um 14:30'],
    client: client,
  );

  test('the model names the event', () async {
    expect(await ask(answering('{"title": "Zahnarzt"}')), 'Zahnarzt');
  });

  test('the transcript is what the model is asked about', () async {
    late Map<String, Object?> body;
    final client = MockClient((request) async {
      expect(request.url.toString(), 'http://llm.test/v1/chat/completions');
      body = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response('{"choices": []}', 200);
    });
    expect(await ask(client), isNull);
    final last = (body['messages']! as List).last as Map;
    expect(last['content'], contains('Zahnarzt am Dienstag um 14:30'));
  });

  test('a failing endpoint is no title, not an error', () async {
    expect(await ask(answering('{"title": "Zahnarzt"}', status: 500)), isNull);
    expect(
      await ask(MockClient((_) async => throw http.ClientException('down'))),
      isNull,
    );
  });

  test('no transcript, no request', () async {
    var asked = false;
    final client = MockClient((_) async {
      asked = true;
      return http.Response('{}', 200);
    });
    expect(
      await suggestEventTitle(
        baseUrl: 'http://llm.test/v1',
        model: 'small',
        transcript: const [],
        client: client,
      ),
      isNull,
    );
    expect(asked, isFalse);
  });

  test('the prompt explains the speakers and the marked line', () async {
    late Map<String, Object?> body;
    final client = MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response('{"choices": []}', 200);
    });
    await ask(client);
    final system = ((body['messages']! as List).first as Map)['content'];
    expect(system, contains('"You" is the user'));
    expect(system, contains('marked "$kEventTitleMarker"'));
    expect(system, contains('not "Meeting"'));
  });

  group('eventTitleTranscript', () {
    final start = DateTime(2026, 11, 20, 18);
    var seq = 0;
    WeftMessage msg(
      String body, {
      String from = 'Anna',
      bool own = false,
      int minute = 0,
      String? id,
      MessageKind kind = MessageKind.text,
      String? transcript,
      bool redacted = false,
      bool bridgeNotice = false,
      bool autoReply = false,
      String? replyTo,
      String? thread,
    }) => WeftMessage(
      eventId: id ?? '\$${seq++}',
      roomId: '!room:x',
      network: ChatNetwork.matrix,
      senderId: own ? '@me:x' : '@${from.toLowerCase()}:x',
      senderName: own ? 'Eric' : from,
      timestamp: start.add(Duration(minutes: minute)),
      kind: kind,
      isOwn: own,
      body: body,
      transcript: transcript,
      redacted: redacted,
      isBridgeNotice: bridgeNotice,
      isAutoReply: autoReply,
      replyToEventId: replyTo,
      threadRootId: thread,
    );

    test('both sides, oldest first, the date marked', () {
      final trigger = msg('yes! friday at 7?', minute: 2);
      final lines = eventTitleTranscript(trigger, [
        // Newest first, as the chat view holds them.
        msg('perfect, I will book a table', own: true, minute: 3),
        trigger,
        msg("Luigi's? heard it's great", own: true, minute: 1),
        msg('we should try that new italian place', minute: 0),
      ]);
      expect(lines, [
        'Anna: we should try that new italian place',
        "You: Luigi's? heard it's great",
        '>> Anna: yes! friday at 7?',
        'You: perfect, I will book a table',
      ]);
    });

    test('a group chat names every speaker', () {
      final trigger = msg(
        'Saturday 10am at the gym then',
        from: 'Ben',
        minute: 2,
      );
      final lines = eventTitleTranscript(trigger, [
        msg('bouldering this weekend?', from: 'Anna', minute: 0),
        msg('in!', own: true, minute: 1),
        trigger,
      ]);
      expect(lines, [
        'Anna: bouldering this weekend?',
        'You: in!',
        '>> Ben: Saturday 10am at the gym then',
      ]);
    });

    test('bounded by count, centred on the message with the date', () {
      final trigger = msg('so tuesday 3pm?', minute: 100);
      final lines = eventTitleTranscript(trigger, [
        for (var i = 0; i < 40; i++) msg('earlier $i', minute: i),
        trigger,
        for (var i = 0; i < 10; i++)
          msg('later $i', own: true, minute: 101 + i),
      ]);
      expect(lines, hasLength(kEventTitleContextMessages));
      expect(
        lines.where((l) => l.startsWith('You: later')),
        hasLength(kEventTitleFollowingMessages),
      );
      expect(
        lines.first,
        'Anna: earlier ${40 - (kEventTitleContextMessages - 1 - kEventTitleFollowingMessages)}',
      );
      expect(lines, contains('>> Anna: so tuesday 3pm?'));
      expect(lines.last, 'You: later ${kEventTitleFollowingMessages - 1}');
    });

    test('bounded by characters, dropping the oldest lines first', () {
      final trigger = msg('dentist tomorrow 9:00', minute: 50);
      final lines = eventTitleTranscript(trigger, [
        for (var i = 0; i < 10; i++) msg('x' * 250, minute: i),
        trigger,
      ], maxChars: 800);
      expect(lines.join('\n').length, lessThanOrEqualTo(800));
      expect(lines.last, '>> Anna: dentist tomorrow 9:00');
      expect(lines.length, greaterThan(1));
    });

    test('a very long line is cut rather than spending the budget', () {
      final trigger = msg('ok monday 8pm', minute: 1);
      final lines = eventTitleTranscript(trigger, [msg('y' * 2000), trigger]);
      expect(lines.first.length, lessThan(320));
      expect(lines.first, endsWith('…'));
    });

    test('noise stays out', () {
      final trigger = msg('dinner friday 7pm?', minute: 9);
      final lines = eventTitleTranscript(trigger, [
        msg('deleted', redacted: true, minute: 1),
        msg(
          'State update: CONNECTED',
          from: 'bridge',
          bridgeNotice: true,
          minute: 2,
        ),
        msg('I am away until Monday', own: true, autoReply: true, minute: 3),
        msg('IMG_2041.jpg', kind: MessageKind.image, minute: 4),
        msg('voice.ogg', kind: MessageKind.voice, minute: 5),
        msg(
          'voice.ogg',
          kind: MessageKind.voice,
          transcript: 'at the thai place?',
          minute: 6,
        ),
        msg('   ', minute: 7),
        trigger,
      ]);
      expect(lines, [
        'Anna: at the thai place?',
        '>> Anna: dinner friday 7pm?',
      ]);
    });

    test('a thread reply is read with its thread, a room message without', () {
      final root = msg('climbing trip planning', id: r'$root', minute: 0);
      final inThread = msg('the cabin in Arco', thread: r'$root', minute: 1);
      final elsewhere = msg('unrelated room chatter', minute: 2);
      final threadTrigger = msg(
        'arrive saturday 2pm',
        thread: r'$root',
        minute: 3,
      );
      final roomTrigger = msg('lunch tomorrow 12:30?', minute: 4);
      final all = [root, inThread, elsewhere, threadTrigger, roomTrigger];

      expect(eventTitleTranscript(threadTrigger, all), [
        'Anna: climbing trip planning',
        'Anna: the cabin in Arco',
        '>> Anna: arrive saturday 2pm',
      ]);
      expect(eventTitleTranscript(roomTrigger, all), [
        'Anna: climbing trip planning',
        'Anna: unrelated room chatter',
        '>> Anna: lunch tomorrow 12:30?',
      ]);
    });

    test('the message replied to is kept, without its quoted fallback', () {
      final target = msg('Concert at the Olympiahalle?', id: r'$q', minute: 0);
      final trigger = msg(
        '> <@anna:x> Concert at the Olympiahalle?\n\nyes, saturday 8pm!',
        own: true,
        replyTo: r'$q',
        minute: 60,
      );
      final lines = eventTitleTranscript(trigger, [
        target,
        for (var i = 0; i < 30; i++) msg('chat $i', minute: 10 + i),
        trigger,
      ]);
      expect(lines, hasLength(kEventTitleContextMessages));
      expect(lines.first, '(replied to) Anna: Concert at the Olympiahalle?');
      expect(lines.last, '>> You: yes, saturday 8pm!');
    });

    test('the trigger alone when nothing was loaded', () {
      final trigger = msg('Zahnarzt am Dienstag um 14:30');
      expect(eventTitleTranscript(trigger, const []), [
        '>> Anna: Zahnarzt am Dienstag um 14:30',
      ]);
    });
  });

  group('chooseEventTitle', () {
    test('a title that names something wins', () {
      expect(
        chooseEventTitle(
          model: "Dinner with Sam at Luigi's",
          fallback: 'Yes! friday at 7?',
        ),
        "Dinner with Sam at Luigi's",
      );
    });

    test('no title, the rule-made one', () {
      expect(chooseEventTitle(model: null, fallback: 'Zahnarzt'), 'Zahnarzt');
    });

    test('a generic title is no title', () {
      for (final generic in ['Meeting', 'termin', 'Appointment.', 'Réunion']) {
        expect(
          chooseEventTitle(model: generic, fallback: 'Zahnarzt'),
          'Zahnarzt',
          reason: generic,
        );
      }
    });

    test('a long message copied back is no title, a short one may be', () {
      const message = 'can we meet at the station cafe on friday at 7';
      expect(
        isGenericEventTitle(
          'Can we meet at the station cafe',
          message: message,
        ),
        isTrue,
      );
      expect(isGenericEventTitle('Zahnarzt', message: 'Zahnarzt'), isFalse);
      expect(
        isGenericEventTitle('Coffee at the station cafe', message: message),
        isFalse,
      );
    });
  });

  group('parseEventTitle', () {
    test('takes fenced JSON and drops tagged thinking', () {
      expect(
        parseEventTitle(
          '<think>hm</think>```json\n{"title": " Team  lunch "}\n```',
        ),
        'Team lunch',
      );
    });

    test('refuses anything that is not a title', () {
      expect(parseEventTitle('Here is a title: Dentist'), isNull);
      expect(parseEventTitle('<think>still thinking'), isNull);
      expect(parseEventTitle('{"title": ""}'), isNull);
      expect(parseEventTitle('{"title": "<title>"}'), isNull);
      expect(parseEventTitle('{"title": "${'a' * 61}"}'), isNull);
      expect(parseEventTitle('{"title": 42}'), isNull);
    });
  });
}
