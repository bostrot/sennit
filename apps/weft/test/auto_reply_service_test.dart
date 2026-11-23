import 'package:flutter_test/flutter_test.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/services/ai/auto_reply_service.dart';
import 'package:weft/services/ai/auto_reply_writer.dart';
import 'package:weft/services/ai/conversation_context.dart';
import 'package:weft/services/ai/person_memory.dart' show AiMemory;

import 'support/auto_reply_fakes.dart';

/// What the service adds on top of the rule engine.
///
/// The decisions are `weft_autoreply`'s and are exhaustively tested there. What
/// is here is the orchestration: that a burst of messages produces one reply
/// rather than three, that the model's failures are survivable and visible,
/// that the conversation slice sent off the device is bounded, and that the
/// ledger it keeps is what makes the cap hold across messages.
void main() {
  const room = '!room:example.org';

  Chat chat({ChatRequestState? request}) => Chat(
    id: room,
    title: 'Grace',
    unreadCount: 2,
    request: request,
    sources: const [ChatSource(roomId: room, network: ChatNetwork.whatsapp)],
  );

  WeftMessage msg({String body = 'are you around?', String id = r'$in'}) =>
      WeftMessage(
        eventId: id,
        roomId: room,
        network: ChatNetwork.whatsapp,
        senderId: '@whatsapp_grace:example.org',
        senderName: 'Grace',
        timestamp: DateTime.utc(2026, 1, 15, 10),
        kind: MessageKind.text,
        isOwn: false,
        body: body,
      );

  const away = AutoReplyRule(
    id: 'away',
    name: 'Away',
    prompt: 'Say I am away until Monday.',
    enabled: true,
  );

  group('the happy path', () {
    test('a matching rule sends the words the model wrote', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        composer: FakeComposer(
          reply: 'Away until Monday — I will read it then.',
        ),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.transport.sent.single.chatId, room);
      expect(
        h.transport.sent.single.body,
        'Away until Monday — I will read it then.',
      );
    });

    test("the user's prompt reaches the model verbatim", () async {
      // Not templated, not sanitised, not wrapped in advice. A client that
      // quietly edited it would be answering for something nobody wrote.
      final h = buildAutoReplyService(chat: chat(), rules: const [away]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.composer.calls.single.instruction, away.prompt);
    });

    test('the attempt is recorded with what was said', () async {
      final h = buildAutoReplyService(chat: chat(), rules: const [away]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.attempts.single.succeeded, isTrue);
      expect(h.attempts.single.ruleName, 'Away');
      expect(h.attempts.single.chatTitle, 'Grace');
      expect(h.attempts.single.text, isNotNull);
    });

    test('messages arriving through the stream are handled', () async {
      final h = buildAutoReplyService(chat: chat(), rules: const [away]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);
      h.service.start();

      h.incoming.add(msg());
      await Future<void>.delayed(Duration.zero);

      expect(h.transport.sent, hasLength(1));
    });

    test(
      'start is idempotent, so a reconnection does not double every reply',
      () async {
        final h = buildAutoReplyService(chat: chat(), rules: const [away]);
        addTearDown(h.incoming.close);
        addTearDown(h.service.dispose);
        h.service
          ..start()
          ..start();

        h.incoming.add(msg());
        await Future<void>.delayed(Duration.zero);

        expect(h.transport.sent, hasLength(1));
      },
    );
  });

  group('the conversation context', () {
    test('is bounded at the shared AI constant', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        // No cooldown between the messages below, so every one of them is
        // decided rather than being held back before it reaches the buffer.
        ledger: AutoReplyLedger(),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      for (var i = 0; i < kAiContextMessages * 3; i++) {
        await h.service.handleMessage(msg(id: '\$in-$i', body: 'line $i'));
      }

      // The quantity that leaves the device per reply is a privacy number, not
      // a tuning one, and this is the assertion that keeps it one. Equal, not
      // merely under: a buffer that silently stopped at the newest message
      // would satisfy an upper bound and is the bug this feature had.
      final transcript = h.service.transcriptFor(room);
      expect(transcript, hasLength(kAiContextMessages));
      // And it is the *newest* window, oldest first — equal to the bound
      // rather than merely under it, because a buffer that silently kept only
      // the newest message would satisfy an upper bound and is the bug this
      // whole constant exists to stop.
      expect(transcript, contains('Grace: line ${kAiContextMessages * 3 - 1}'));
      expect(transcript, isNot(contains('Grace: line 0')));
    });

    test('names the speakers, so the model can tell the sides apart', () async {
      final h = buildAutoReplyService(chat: chat(), rules: const [away]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg(body: 'are you around?'));

      expect(h.composer.calls.single.transcript, ['Grace: are you around?']);
    });

    test("what was sent on the user's behalf joins the context", () async {
      // So a second message is answered in the light of what the model already
      // said, rather than repeating it.
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        composer: FakeComposer(reply: 'Away until Monday.'),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg(id: r'$one'));

      expect(h.service.transcriptFor(room), [
        'Grace: are you around?',
        'You: Away until Monday.',
      ]);
    });
  });

  group('one reply at a time', () {
    test('a burst of three messages produces one reply', () async {
      // A model takes seconds and a paragraph split across three bubbles
      // arrives in one. Without the in-flight guard each would start its own
      // completion, and all three would pass the ledger because none of the
      // replies had landed yet.
      final h = buildAutoReplyService(chat: chat(), rules: const [away]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await Future.wait([
        h.service.handleMessage(msg(id: r'$a')),
        h.service.handleMessage(msg(id: r'$b')),
        h.service.handleMessage(msg(id: r'$c')),
      ]);

      expect(h.transport.sent, hasLength(1));
    });
  });

  group('the ledger holds the cap across messages', () {
    test('a fourth message in the hour is refused, and says why', () async {
      // A zero cooldown, so the only thing that can stop the fourth message is
      // the cap — which is exactly what makes a zero cooldown safe to offer.
      final h = buildAutoReplyService(
        chat: chat(),
        rules: [away.copyWith(cooldown: Duration.zero)],
        now: DateTime.utc(2026, 1, 15, 10),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      for (var i = 0; i < kAutoReplyMaxPerConversation + 1; i++) {
        await h.service.handleMessage(msg(id: '\$in-$i'));
      }

      expect(h.transport.sent, hasLength(kAutoReplyMaxPerConversation));
      // The fake appends in call order; the log notifier is what reverses it
      // for the screen.
      expect(h.attempts.last.refusal, AutoReplyRefusal.conversationCap);
    });
  });

  group('failure is survivable and visible', () {
    test(
      'a model that cannot be reached sends nothing and does not throw',
      () async {
        final h = buildAutoReplyService(
          chat: chat(),
          rules: const [away],
          composer: FakeComposer(failWith: AutoReplyOutcome.unreachable),
        );
        addTearDown(h.incoming.close);
        addTearDown(h.service.dispose);

        await h.service.handleMessage(msg());

        expect(h.transport.sent, isEmpty);
        expect(h.attempts.single.outcome, AutoReplyOutcome.unreachable);
      },
    );

    test(
      'a model that chose not to reply sends nothing, and says so',
      () async {
        final h = buildAutoReplyService(
          chat: chat(),
          rules: const [away],
          composer: FakeComposer(failWith: AutoReplyOutcome.declined),
        );
        addTearDown(h.incoming.close);
        addTearDown(h.service.dispose);

        await h.service.handleMessage(msg());

        expect(h.transport.sent, isEmpty);
        expect(h.attempts.single.outcome, AutoReplyOutcome.declined);
        expect(h.attempts.single.succeeded, isFalse);
      },
    );

    test('a timeout is not retried on its own', () async {
      // A model that timed out once will time out again while the same message
      // is the newest one, and a retry loop against someone else's Ollama is a
      // way to make a phone hot. The user's Retry is the way back.
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        composer: FakeComposer(failWith: AutoReplyOutcome.timedOut),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.composer.calls, hasLength(1));
    });

    test(
      'a failure spends no ledger entry, so a later message may reply',
      () async {
        final h = buildAutoReplyService(
          chat: chat(),
          rules: const [away],
          composer: FakeComposer(failWith: AutoReplyOutcome.refused),
        );
        addTearDown(h.incoming.close);
        addTearDown(h.service.dispose);

        for (var i = 0; i < kAutoReplyMaxPerConversation + 2; i++) {
          await h.service.handleMessage(msg(id: '\$in-$i'));
        }

        expect(
          h.attempts.every((a) => a.outcome == AutoReplyOutcome.refused),
          isTrue,
          reason: 'a model that never answers must not fill the hourly quota',
        );
      },
    );

    test('a transport that refuses is reported, not thrown', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        transport: FakeAutoReplyTransport(
          failWith: StateError('the room is gone'),
        ),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.attempts.single.outcome, AutoReplyOutcome.sendFailed);
    });

    test('no endpoint means no call and a reported reason', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        endpoint: null,
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.composer.calls, isEmpty);
      expect(h.attempts.single.outcome, AutoReplyOutcome.notConfigured);
    });
  });

  group('what is not reported', () {
    test('an ordinary message with no rule leaves no log line', () async {
      // True of almost every message that arrives. A log full of them would
      // bury the one entry that matters.
      final h = buildAutoReplyService(chat: chat(), rules: const []);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.attempts, isEmpty);
    });

    test('a stranger request leaves no log line either', () async {
      // And, more importantly, no reply: the refusal is the engine's and this
      // asserts the service honours it.
      final h = buildAutoReplyService(
        chat: chat(request: ChatRequestState.pending),
        rules: const [away],
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.transport.sent, isEmpty);
      expect(h.attempts, isEmpty);
    });

    test('a room the inbox has not folded yet is left alone', () async {
      final h = buildAutoReplyService(chat: chat(), rules: const [away]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(
        WeftMessage(
          eventId: r'$elsewhere',
          roomId: '!unknown:example.org',
          network: ChatNetwork.matrix,
          senderId: '@someone:example.org',
          senderName: 'Someone',
          timestamp: DateTime.utc(2026, 1, 15, 10),
          kind: MessageKind.text,
          isOwn: false,
          body: 'hello?',
        ),
      );

      expect(h.transport.sent, isEmpty);
      expect(h.attempts, isEmpty);
    });
  });

  group('the dry run', () {
    test('writes a reply and sends nothing', () async {
      final h = buildAutoReplyService(chat: chat(), rules: const [away]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      final draft = await h.service.preview(away, chat());

      expect(draft.text, isNotNull);
      expect(h.transport.sent, isEmpty);
    });

    test('ignores the schedule, which is the point of it', () async {
      // Tuning a night-time rule happens in the afternoon. A preview that
      // obeyed the window would answer "not now" to the one question the
      // button is for.
      final nightly = away.copyWith(
        window: const ReplyWindow(startMinute: 22 * 60, endMinute: 7 * 60),
      );
      final h = buildAutoReplyService(
        chat: chat(),
        rules: [nightly],
        now: DateTime.utc(2026, 1, 15, 14),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      final draft = await h.service.preview(nightly, chat());

      expect(draft.text, isNotNull);
    });

    test('reports the same failures the real path does', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        endpoint: null,
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      final draft = await h.service.preview(away, chat());

      expect(draft.outcome, AutoReplyOutcome.notConfigured);
      expect(draft.text, isNull);
    });
  });

  group('a reply outside the format is asked for again', () {
    test('once, and the second answer is sent', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        composer: FakeComposer(script: const [AutoReplyOutcome.refused, null]),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.composer.calls, hasLength(1 + kAutoReplyFormatRetries));
      expect(h.transport.sent.single.body, 'I am away until Monday.');
      expect(h.attempts.single.outcome, AutoReplyOutcome.sent);
    });

    test('and no more than once, then it is reported', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        composer: FakeComposer(failWith: AutoReplyOutcome.refused),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.composer.calls, hasLength(1 + kAutoReplyFormatRetries));
      expect(h.transport.sent, isEmpty);
      expect(h.attempts.single.outcome, AutoReplyOutcome.refused);
    });

    test(
      'a decline is an answer, not a miss, and is not asked again',
      () async {
        final h = buildAutoReplyService(
          chat: chat(),
          rules: const [away],
          composer: FakeComposer(failWith: AutoReplyOutcome.declined),
        );
        addTearDown(h.incoming.close);
        addTearDown(h.service.dispose);

        await h.service.handleMessage(msg());

        expect(h.composer.calls, hasLength(1));
      },
    );
  });

  group("the user's retry", () {
    test('answers the newest message once the model is back', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        composer: FakeComposer(script: const [AutoReplyOutcome.timedOut]),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg(body: 'are you coming tonight?'));
      expect(h.transport.sent, isEmpty);

      final tried = await h.service.retry(room);

      expect(tried, isTrue);
      expect(h.transport.sent.single.body, 'I am away until Monday.');
      expect(
        h.composer.calls.last.transcript.last,
        contains('are you coming tonight?'),
      );
      expect(h.attempts.map((a) => a.outcome), [
        AutoReplyOutcome.timedOut,
        AutoReplyOutcome.sent,
      ]);
    });

    test('does not add the message to the context a second time', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        composer: FakeComposer(script: const [AutoReplyOutcome.unreachable]),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());
      await h.service.retry(room);

      expect(h.composer.calls.last.transcript, hasLength(1));
    });

    test('has nothing to do once a reply went out', () async {
      final h = buildAutoReplyService(chat: chat(), rules: const [away]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());
      final tried = await h.service.retry(room);

      expect(tried, isFalse);
      expect(h.transport.sent, hasLength(1));
    });

    test('has nothing to do for a conversation it never saw', () async {
      final h = buildAutoReplyService(chat: chat(), rules: const [away]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      expect(await h.service.retry(room), isFalse);
      expect(h.composer.calls, isEmpty);
      expect(h.attempts, isEmpty);
    });

    test('still obeys the rules, and says why when they refuse', () async {
      // The rule was switched off after the failure. A tap must not send what
      // the rules would not, and must not look like it did nothing either.
      var rules = const [away];
      final composer = FakeComposer(script: const [AutoReplyOutcome.timedOut]);
      final attempts = <AutoReplyAttempt>[];
      final transport = FakeAutoReplyTransport();
      final service = AutoReplyService(
        incoming: const Stream.empty(),
        transport: transport,
        chatForRoom: (_) => chat(),
        rules: () => rules,
        labelsOf: (_) => const {},
        isServiceChat: (_) => false,
        isBroadcast: (_) => false,
        ownUserIds: () => const {'@ada:example.org'},
        endpoint: () => const AutoReplyEndpoint(
          baseUrl: 'http://localhost:11434/v1',
          model: 'llama3',
        ),
        onAttempt: attempts.add,
        composer: composer.call,
      );
      addTearDown(service.dispose);

      await service.handleMessage(msg());
      rules = [away.copyWith(enabled: false)];
      final tried = await service.retry(room);

      expect(tried, isTrue);
      expect(transport.sent, isEmpty);
      expect(composer.calls, hasLength(1));
      expect(attempts.last.refusal, isNotNull);
      expect(attempts.last.outcome, isNull);
    });
  });

  group('which attempts offer a retry', () {
    AutoReplyAttempt attempt({
      AutoReplyOutcome? outcome,
      AutoReplyRefusal? refusal,
    }) => AutoReplyAttempt(
      chatId: room,
      chatTitle: 'Grace',
      at: DateTime.utc(2026, 1, 15, 10),
      outcome: outcome,
      refusal: refusal,
    );

    test('the failures another go can fix', () {
      for (final outcome in [
        AutoReplyOutcome.refused,
        AutoReplyOutcome.unreachable,
        AutoReplyOutcome.timedOut,
        AutoReplyOutcome.sendFailed,
      ]) {
        expect(attempt(outcome: outcome).canRetry, isTrue, reason: '$outcome');
      }
    });

    test('not a success, a decline, a missing model or a refusal', () {
      for (final outcome in [
        AutoReplyOutcome.sent,
        AutoReplyOutcome.declined,
        AutoReplyOutcome.notConfigured,
      ]) {
        expect(attempt(outcome: outcome).canRetry, isFalse, reason: '$outcome');
      }
      expect(
        attempt(refusal: AutoReplyRefusal.conversationCap).canRetry,
        isFalse,
      );
    });
  });

  group('personal memory', () {
    test('what is noted reaches the model, asked about this chat', () async {
      Chat? askedFor;
      List<WeftMessage>? recent;
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        memory: (chat, messages) {
          askedFor = chat;
          recent = messages;
          return const AiMemory(people: [(name: 'Grace', note: 'Formal: Sie')]);
        },
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(askedFor?.id, room);
      expect(recent?.single.body, 'are you around?');
      expect(h.composer.memories.single?.people.single.note, 'Formal: Sie');
    });

    test('a switched-off memory sends nothing', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        memory: (_, _) => null,
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.composer.memories.single, isNull);
      expect(h.transport.sent, hasLength(1));
    });
  });

  group('the calendar', () {
    test('the calendar section reaches the model', () async {
      List<String>? asked;
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        calendar: (transcript) async {
          asked = transcript;
          return '- Fri 2026-01-16 09:00–10:00';
        },
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg(body: 'free on Friday?'));

      expect(asked, ['Grace: free on Friday?']);
      expect(h.composer.calendars.single, '- Fri 2026-01-16 09:00–10:00');
      expect(h.transport.sent, hasLength(1));
    });

    test('a calendar that fails does not stop the reply', () async {
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        calendar: (_) async => throw StateError('calendar server down'),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(h.composer.calendars.single, isNull);
      expect(h.transport.sent, hasLength(1));
    });

    test('a format retry asks the same calendar question once', () async {
      var lookups = 0;
      final h = buildAutoReplyService(
        chat: chat(),
        rules: const [away],
        composer: FakeComposer(script: const [AutoReplyOutcome.refused, null]),
        calendar: (_) async {
          lookups++;
          return 'busy';
        },
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await h.service.handleMessage(msg());

      expect(lookups, 1);
      expect(h.composer.calendars, ['busy', 'busy']);
    });
  });
}
