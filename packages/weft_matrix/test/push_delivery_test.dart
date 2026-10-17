import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';

void main() {
  final now = DateTime.utc(2026, 8, 17, 12);

  group('MatrixPushPayload', () {
    test('reads the gateway envelope', () {
      final payload = MatrixPushPayload.fromJson({
        'notification': {
          'room_id': '!wa:example.org',
          'event_id': r'$evt1',
          'counts': {'unread': 3},
          'devices': [
            {'pushkey': 'fcm-token-1'},
          ],
        },
      });

      expect(payload!.roomId, '!wa:example.org');
      expect(payload.eventId, r'$evt1');
      expect(payload.unreadCount, 3);
      expect(payload.deviceIds, ['fcm-token-1']);
      expect(payload.isClearing, isFalse);
    });

    test('reads a flattened FCM data map, where everything is a string', () {
      // An FCM data message can only carry strings, so `3` arrives as `"3"`.
      final payload = MatrixPushPayload.fromJson({
        'room_id': '!wa:example.org',
        'event_id': r'$evt1',
        'unread': '3',
        'prio': 'high',
      });

      expect(payload!.roomId, '!wa:example.org');
      expect(payload.unreadCount, 3);
    });

    test('a poke with no event is a dismissal, not a malformed message', () {
      final payload = MatrixPushPayload.fromJson({
        'room_id': '!wa:example.org',
        'counts': {'unread': 0},
      });

      expect(payload, isNotNull);
      expect(payload!.isClearing, isTrue);
      expect(payload.unreadCount, 0);
    });

    test('returns null for a payload with nothing Matrix-shaped in it', () {
      expect(MatrixPushPayload.fromJson({'aps': <String, Object?>{}}), isNull);
      expect(MatrixPushPayload.fromJson(<String, Object?>{}), isNull);
    });

    test('empty strings read as absent, not as an id', () {
      final payload = MatrixPushPayload.fromJson({
        'room_id': '!wa:example.org',
        'event_id': '',
        'unread': 'not a number',
      });

      expect(payload!.eventId, isNull);
      expect(payload.isClearing, isTrue);
      expect(payload.unreadCount, isNull);
    });
  });

  group('handlePush', () {
    test('fetches the event, decides, and renders it', () async {
      final session = _FakeSession(messages: {r'$evt1': _message()});
      final pipeline = _pipelineFor(session, now: now);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);

      final decision = await pipeline.handlePush({
        'room_id': '!wa:example.org',
        'event_id': r'$evt1',
      });
      await pumpEventQueue();

      expect(decision, const NotifyDecision());
      expect(posted, hasLength(1));
      expect(posted.single.content.body, 'are you around?');
      expect(posted.single.isSilent, isFalse);
      await pipeline.dispose();
    });

    test('groups both legs of a merged chat under one key', () async {
      // The reason `chatForRoom` is injected rather than derived: a WhatsApp
      // message and a Signal message from one contact are one thread.
      final session = _FakeSession(
        messages: {
          r'$wa': _message(),
          r'$sig': _message(
            eventId: r'$sig',
            roomId: '!sig:example.org',
            network: ChatNetwork.signal,
          ),
        },
      );
      final pipeline = _pipelineFor(session, now: now, merged: true);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);

      await pipeline.handlePush({
        'room_id': '!wa:example.org',
        'event_id': r'$wa',
      });
      await pipeline.handlePush({
        'room_id': '!sig:example.org',
        'event_id': r'$sig',
      });
      await pumpEventQueue();

      expect(posted, hasLength(2));
      expect(posted.map((n) => n.content.groupKey).toSet(), {
        'merged:contact_1',
      });
      expect(posted.map((n) => n.content.deepLink).toSet(), {
        'weft://chat/merged%3Acontact_1',
      });
      // The room ids differ, because an action has to land somewhere real.
      expect(posted.map((n) => n.content.roomId), [
        '!wa:example.org',
        '!sig:example.org',
      ]);
      await pipeline.dispose();
    });

    test('a clearing push reaches no verdict', () async {
      final pipeline = _pipelineFor(_FakeSession(), now: now);

      expect(
        await pipeline.handlePush({
          'room_id': '!wa:example.org',
          'counts': {'unread': 0},
        }),
        isNull,
      );
      await pipeline.dispose();
    });

    test('an event that will not resolve reaches no verdict', () async {
      // Unsynced room, redacted away, or undecryptable. None of those is a
      // suppression: the question could not be asked.
      final pipeline = _pipelineFor(_FakeSession(), now: now);

      expect(
        await pipeline.handlePush({
          'room_id': '!wa:example.org',
          'event_id': r'$missing',
        }),
        isNull,
      );
      await pipeline.dispose();
    });

    test(
      'a room the inbox has not folded into a chat yet is skipped',
      () async {
        final session = _FakeSession(messages: {r'$evt1': _message()});
        final pipeline = MatrixNotificationPipeline(
          session: session,
          chatForRoom: (_) => null,
          policy: NotificationPolicy.new,
          now: () => now,
        );

        expect(
          await pipeline.handlePush({
            'room_id': '!wa:example.org',
            'event_id': r'$evt1',
          }),
          isNull,
        );
        await pipeline.dispose();
      },
    );

    test('does not fetch an event the sync path already decided', () async {
      final session = _FakeSession(messages: {r'$evt1': _message()});
      final pipeline = _pipelineFor(session, now: now);

      await pipeline.handleMessage(_message());
      final decision = await pipeline.handlePush({
        'room_id': '!wa:example.org',
        'event_id': r'$evt1',
      });

      expect(
        decision,
        const NotificationDecision.suppress(NotificationSuppression.duplicate),
      );
      // A round trip and a decrypt saved, which on a woken phone is the whole
      // cost of the push.
      expect(session.fetches, isEmpty);
      await pipeline.dispose();
    });
  });

  group('the two paths agree', () {
    test('one message arriving twice notifies once', () async {
      final session = _FakeSession(messages: {r'$evt1': _message()});
      final pipeline = _pipelineFor(session, now: now);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);
      pipeline.start();

      // Push first, then the same event down sync a second later.
      await pipeline.handlePush({
        'room_id': '!wa:example.org',
        'event_id': r'$evt1',
      });
      session.emit(_message());
      await pumpEventQueue();

      expect(posted, hasLength(1));
      await pipeline.dispose();
    });

    test('the foreground path evaluates sync messages', () async {
      final session = _FakeSession();
      final pipeline = _pipelineFor(session, now: now);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);
      pipeline.start();

      session.emit(_message());
      await pumpEventQueue();

      expect(posted, hasLength(1));
      expect(posted.single.content.groupKey, '!wa:example.org');
      await pipeline.dispose();
    });

    test('start is idempotent, so one message is not handled twice', () async {
      final session = _FakeSession();
      final pipeline = _pipelineFor(session, now: now);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);
      pipeline
        ..start()
        ..start();

      session.emit(_message());
      await pumpEventQueue();

      expect(posted, hasLength(1));
      await pipeline.dispose();
    });
  });

  group('the policy is honoured on both paths', () {
    test('a muted chat is suppressed and nothing is posted', () async {
      final session = _FakeSession();
      final posted = <MatrixNotification>[];
      final pipeline = MatrixNotificationPipeline(
        session: session,
        chatForRoom: (_) => _chat(),
        policy: () => NotificationPolicy().muteChat('!wa:example.org'),
        now: () => now,
      );
      pipeline.notifications.listen(posted.add);

      final decision = await pipeline.handleMessage(_message());
      await pumpEventQueue();

      expect(decision?.suppression, NotificationSuppression.chatMuted);
      expect(posted, isEmpty);
      await pipeline.dispose();
    });

    test('the policy is read per message, not captured', () async {
      // A mute applied from the notification shade has to affect the next
      // message, not the next launch.
      var policy = NotificationPolicy();
      final pipeline = MatrixNotificationPipeline(
        session: _FakeSession(),
        chatForRoom: (_) => _chat(),
        policy: () => policy,
        now: () => now,
      );

      expect((await pipeline.handleMessage(_message()))!.delivers, isTrue);
      policy = policy.muteChat('!wa:example.org');
      expect(
        (await pipeline.handleMessage(_message(eventId: r'$evt2')))!.delivers,
        isFalse,
      );
      await pipeline.dispose();
    });

    test('a read receipt from another device suppresses the push', () async {
      // The half of "read elsewhere" the app could not do before: the receipt
      // is account-wide, so reading on a laptop stops the phone buzzing.
      final session = _FakeSession(
        readMarkers: {'!wa:example.org': now.add(const Duration(minutes: 1))},
      );
      final pipeline = _pipelineFor(session, now: now);

      final decision = await pipeline.handleMessage(_message());

      expect(decision?.suppression, NotificationSuppression.alreadyRead);
      await pipeline.dispose();
    });

    test('a message in the chat on screen is not announced', () async {
      final session = _FakeSession();
      final asked = <String>[];
      final posted = <MatrixNotification>[];
      final pipeline = MatrixNotificationPipeline(
        session: session,
        chatForRoom: (_) => _mergedChat(),
        policy: NotificationPolicy.new,
        // Asked about the *chat*: a merged contact is open as one
        // conversation, whichever leg the message came in on.
        isChatOpen: (chatId) {
          asked.add(chatId);
          return chatId == 'merged:contact_1';
        },
        now: () => now,
      );
      pipeline.notifications.listen(posted.add);

      final decision = await pipeline.handleMessage(
        _message(roomId: '!sig:example.org', network: ChatNetwork.signal),
      );
      await pumpEventQueue();

      expect(decision?.suppression, NotificationSuppression.chatOpen);
      expect(asked, ['merged:contact_1']);
      expect(posted, isEmpty);
      await pipeline.dispose();
    });

    test('a chat that is not on screen still notifies', () async {
      final pipeline = MatrixNotificationPipeline(
        session: _FakeSession(),
        chatForRoom: (_) => _chat(),
        policy: NotificationPolicy.new,
        isChatOpen: (chatId) => chatId == 'some-other-chat',
        now: () => now,
      );

      expect((await pipeline.handleMessage(_message()))!.delivers, isTrue);
      await pipeline.dispose();
    });

    test('the test notification ignores what is on screen', () async {
      final pipeline = MatrixNotificationPipeline(
        session: _FakeSession(),
        chatForRoom: (_) => _chat(),
        policy: NotificationPolicy.new,
        isChatOpen: (_) => true,
        now: () => now,
      );

      final decision = await pipeline.handleSynthetic(
        message: _message(),
        chat: _chat(),
      );

      expect(decision.delivers, isTrue);
      await pipeline.dispose();
    });

    test('quiet hours can deliver silently', () async {
      final pipeline = MatrixNotificationPipeline(
        session: _FakeSession(),
        chatForRoom: (_) => _chat(),
        policy: () => NotificationPolicy(
          quietHours: const QuietHours(
            startMinute: 0,
            endMinute: 1439,
            deliverSilently: true,
          ),
        ),
        now: () => now,
      );
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);

      await pipeline.handleMessage(_message());
      await pumpEventQueue();

      expect(posted.single.isSilent, isTrue);
      await pipeline.dispose();
    });

    test('a mention is carried through to the rendered notification', () async {
      final pipeline = _pipelineFor(_FakeSession(), now: now);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);

      await pipeline.handleMessage(_message(body: 'ping @me:example.org'));
      await pumpEventQueue();

      expect(posted.single.content.isMention, isTrue);
      expect(posted.single.decision.mentioned, isTrue);
      await pipeline.dispose();
    });

    test('a bridged display name counts as a mention', () async {
      final session = _FakeSession(displayNames: {'Sam Weft'});
      final pipeline = _pipelineFor(session, now: now);

      final decision = await pipeline.handleMessage(
        _message(body: 'sam weft, are you there?'),
      );

      expect(decision!.mentioned, isTrue);
      await pipeline.dispose();
    });

    test('the user\'s own message never posts', () async {
      final pipeline = _pipelineFor(_FakeSession(), now: now);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);

      final decision = await pipeline.handleMessage(
        _message(senderId: '@me:example.org', isOwn: true),
      );
      await pumpEventQueue();

      expect(decision?.suppression, NotificationSuppression.ownMessage);
      expect(posted, isEmpty);
      await pipeline.dispose();
    });
  });

  group('handleSynthetic', () {
    // The settings screen's "send test notification". A message no homeserver
    // ever saw, attributed to a chat `chatForRoom` cannot resolve, run through
    // the same evaluate-render-emit steps a real one takes.
    final message = _message(
      eventId: r'$weft-test-1',
      roomId: '!notification-test:weft.invalid',
      network: ChatNetwork.matrix,
      senderId: '@weft-test:weft.invalid',
      body: 'This is what a notification from Weft looks like.',
    );
    const chat = Chat(
      id: 'weft:notification-test',
      title: 'Notification test',
      sources: [
        ChatSource(
          roomId: '!notification-test:weft.invalid',
          network: ChatNetwork.matrix,
        ),
      ],
    );

    test('renders and emits under the caller\'s chat', () async {
      final pipeline = _pipelineFor(_FakeSession(), now: now);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);

      final decision = await pipeline.handleSynthetic(
        message: message,
        chat: chat,
      );
      await pumpEventQueue();

      expect(decision, const NotifyDecision());
      expect(posted, hasLength(1));
      // Not `_chat()`, which is what `chatForRoom` would have returned: a test
      // notification is its own conversation and must not land in someone's
      // thread.
      expect(posted.single.content.groupKey, 'weft:notification-test');
      expect(
        posted.single.content.body,
        'This is what a notification from Weft looks like.',
      );
      await pipeline.dispose();
    });

    test('notifies again when the button is pressed twice', () async {
      // The ledger is neither read nor written, so a second press is a second
      // notification rather than a `duplicate` suppression.
      final pipeline = _pipelineFor(_FakeSession(), now: now);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);

      expect(
        (await pipeline.handleSynthetic(message: message, chat: chat)).delivers,
        isTrue,
      );
      expect(
        (await pipeline.handleSynthetic(message: message, chat: chat)).delivers,
        isTrue,
      );
      await pumpEventQueue();

      expect(posted, hasLength(2));
      // And a real message with that id would still be decided on its merits,
      // because nothing was spent recording the test.
      expect(pipeline.dedupe.contains(r'$weft-test-1'), isFalse);
      await pipeline.dispose();
    });

    test('obeys the policy, and says which rule stopped it', () async {
      // The whole point of the button returning its decision: "quiet hours" is
      // an answer, silence is not.
      final pipeline = _pipelineFor(
        _FakeSession(),
        now: now,
        policy: NotificationPolicy(mentionsOnly: true),
      );
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);

      final decision = await pipeline.handleSynthetic(
        message: message,
        chat: chat,
      );
      await pumpEventQueue();

      expect(decision.suppression, NotificationSuppression.mentionsOnly);
      expect(posted, isEmpty);
      await pipeline.dispose();
    });
  });

  test('a dismissed notification may notify again', () async {
    final pipeline = _pipelineFor(_FakeSession(), now: now);

    expect((await pipeline.handleMessage(_message()))!.delivers, isTrue);
    pipeline.dedupe.forget(r'$evt1');
    expect((await pipeline.handleMessage(_message()))!.delivers, isTrue);
    await pipeline.dispose();
  });

  _settleTests();
}

/// What a catch-up sync does: announces the message, applies the receipt that
/// came down with it, and only then says the sync is done.
void _settleTests() {
  group('releaseWhenSettled', () {
    test('holds a message until the sync that carried it is applied', () async {
      final source = StreamController<String>();
      final settled = StreamController<void>.broadcast();
      final seen = <String>[];
      final sub = releaseWhenSettled(
        source.stream,
        settled.stream,
      ).listen(seen.add);

      source.add('a');
      source.add('b');
      await pumpEventQueue();
      expect(seen, isEmpty);

      settled.add(null);
      await pumpEventQueue();
      expect(seen, ['a', 'b']);

      await sub.cancel();
      await source.close();
      await settled.close();
    });

    test('a receipt in the same sync is seen before the decision', () async {
      final now = DateTime.utc(2026, 8, 17, 12);
      final timeline = StreamController<WeftMessage>();
      final synced = StreamController<void>.broadcast();
      final readMarkers = <String, DateTime>{};
      final session = _FakeSession(
        readMarkers: readMarkers,
        incoming: releaseWhenSettled(timeline.stream, synced.stream),
      );
      final pipeline = _pipelineFor(session, now: now);
      final posted = <MatrixNotification>[];
      pipeline.notifications.listen(posted.add);
      pipeline.start();

      // The order the SDK applies one response in.
      timeline.add(_message());
      await pumpEventQueue();
      readMarkers['!wa:example.org'] = now;
      synced.add(null);
      await pumpEventQueue();

      expect(posted, isEmpty);
      expect(pipeline.dedupe.contains(r'$evt1'), isTrue);

      await pipeline.dispose();
      await timeline.close();
      await synced.close();
    });

    test(
      'a sync that never settles delays a message, never loses it',
      () async {
        final source = StreamController<String>();
        final seen = <String>[];
        final sub = releaseWhenSettled(
          source.stream,
          const Stream<void>.empty(),
          limit: const Duration(milliseconds: 20),
        ).listen(seen.add);

        source.add('a');
        await pumpEventQueue();
        expect(seen, isEmpty);

        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(seen, ['a']);

        await sub.cancel();
        await source.close();
      },
    );

    test('whatever is held goes out when the source closes', () async {
      final source = StreamController<String>();
      final seen = <String>[];
      final done = Completer<void>();
      releaseWhenSettled(
        source.stream,
        const Stream<void>.empty(),
      ).listen(seen.add, onDone: done.complete);

      source.add('a');
      await source.close();
      await done.future;

      expect(seen, ['a']);
    });
  });

  group('latestReadAt', () {
    final earlier = DateTime.utc(2026, 8, 17, 11);
    final later = DateTime.utc(2026, 8, 17, 12);

    test('a receipt filed under the main thread counts', () {
      // Element files a read of the ordinary timeline there, and nowhere else.
      expect(latestReadAt(null, later), later);
      expect(latestReadAt(earlier, null), earlier);
    });

    test('the newer of the two wins, whichever timeline it is in', () {
      expect(latestReadAt(earlier, later), later);
      expect(latestReadAt(later, earlier), later);
    });

    test('no receipt at all is still "no idea"', () {
      expect(latestReadAt(null, null), isNull);
    });
  });
}

MatrixNotificationPipeline _pipelineFor(
  _FakeSession session, {
  required DateTime now,
  bool merged = false,
  NotificationPolicy? policy,
}) => MatrixNotificationPipeline(
  session: session,
  chatForRoom: (_) => merged ? _mergedChat() : _chat(),
  policy: () => policy ?? NotificationPolicy(),
  now: () => now,
);

WeftMessage _message({
  String eventId = r'$evt1',
  String roomId = '!wa:example.org',
  ChatNetwork network = ChatNetwork.whatsapp,
  String senderId = '@whatsapp_4915:example.org',
  String body = 'are you around?',
  bool isOwn = false,
}) => WeftMessage(
  eventId: eventId,
  roomId: roomId,
  network: network,
  senderId: senderId,
  senderName: 'Sam',
  timestamp: DateTime.utc(2026, 8, 17, 11, 59),
  kind: MessageKind.text,
  isOwn: isOwn,
  body: body,
);

Chat _chat() => const Chat(
  id: '!wa:example.org',
  title: 'Sam',
  sources: [
    ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
  ],
);

Chat _mergedChat() => const Chat(
  id: 'merged:contact_1',
  title: 'Sam',
  contactId: 'contact_1',
  sources: [
    ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
    ChatSource(roomId: '!sig:example.org', network: ChatNetwork.signal),
  ],
);

class _FakeSession implements MatrixNotificationSession {
  _FakeSession({
    Map<String, WeftMessage> messages = const {},
    this.readMarkers = const {},
    Set<String>? displayNames,
    Stream<WeftMessage>? incoming,
  }) : _messages = messages,
       _incoming = incoming,
       ownDisplayNames = displayNames ?? const {'Me'};

  final Map<String, WeftMessage> _messages;
  final Map<String, DateTime> readMarkers;
  final _controller = StreamController<WeftMessage>.broadcast();

  /// Stands in for the sync stream when a test is about *when* it delivers.
  final Stream<WeftMessage>? _incoming;

  /// Event ids actually fetched, so "the push path did not go to the server"
  /// is assertable.
  final List<String> fetches = [];

  void emit(WeftMessage message) => _controller.add(message);

  @override
  Set<String> get ownUserIds => const {'@me:example.org'};

  @override
  final Set<String> ownDisplayNames;

  @override
  Stream<WeftMessage> get incomingMessages => _incoming ?? _controller.stream;

  @override
  Future<WeftMessage?> messageFor({
    required String roomId,
    required String eventId,
  }) async {
    fetches.add(eventId);
    return _messages[eventId];
  }

  @override
  DateTime? lastReadAt(String roomId) => readMarkers[roomId];
}
