import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/notifications/notification_presentation.dart';
import 'package:weft/services/notifications/notification_service.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';

import 'support/notification_fixtures.dart';

/// The reply chips no longer hold the notification up: it is posted at once
/// and posted again, quietly, when they come.
///
/// The bug this exists for: a self-hosted thinking model took five to twelve
/// seconds for the chips, the notification waited ten at most, and so the
/// chips were on it about half the time — and the notification itself was
/// late by that long every time.
final DateTime _now = DateTime.utc(2026, 1, 15, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingNotificationSink sink;
  late FakeNotificationSession session;
  late MatrixNotificationPipeline pipeline;
  late WeftNotificationService service;

  setUp(() {
    sink = RecordingNotificationSink();
    session = FakeNotificationSession();
    pipeline = MatrixNotificationPipeline(
      session: session,
      chatForRoom: _chatForRoom,
      policy: NotificationPolicy.new,
      now: () => _now,
    );
    service = WeftNotificationService(
      sink: sink,
      pipeline: pipeline,
      chatForRoom: _chatForRoom,
    );
  });

  tearDown(() async {
    await service.dispose();
    await pipeline.dispose();
    await session.close();
  });

  Future<void> deliver(WeftMessage message) async {
    await pipeline.handleMessage(message);
    await pumpEventQueue();
  }

  List<String> chipsOf(NotificationPresentation p) => p.payload.suggestions;

  test('the notification is posted before the chips are written', () async {
    final chips = Completer<List<String>>();
    service.suggestReplies = (content, thread) => chips.future;
    await service.start();

    await deliver(_message());

    expect(sink.shown, hasLength(1), reason: 'posted without waiting');
    expect(chipsOf(sink.shown.single), isEmpty);
    expect(sink.shown.single.details.android!.onlyAlertOnce, isFalse);

    chips.complete(const ['On my way', 'Ten minutes']);
    await pumpEventQueue();

    expect(sink.shown, hasLength(2));
    final update = sink.shown.last;
    expect(update.id, sink.shown.first.id, reason: 'the same row, updated');
    expect(chipsOf(update), ['On my way', 'Ten minutes']);
    expect(update.details.android!.actions!.first.inputs.single.choices, [
      'On my way',
      'Ten minutes',
    ]);
    expect(
      update.details.android!.onlyAlertOnce,
      isTrue,
      reason: 'one message buzzes once, chips or not',
    );
    expect(update.body, 'hello');
    expect(service.smartReplyStats[SmartReplyOutcome.requested], 1);
    expect(service.smartReplyStats[SmartReplyOutcome.inTime], 1);
  });

  test('a slow model does not hold up the next message', () async {
    final first = Completer<List<String>>();
    var calls = 0;
    service.suggestReplies = (content, thread) {
      calls++;
      return calls == 1 ? first.future : Future.value(const ['Sure']);
    };
    await service.start();

    await deliver(_message(eventId: r'$e1', body: 'dinner?'));
    await deliver(_message(eventId: r'$e2', body: 'at eight?'));

    // Both posted, and the second one's chips already on it.
    final bodies = sink.shown.map((p) => p.body).toList();
    expect(bodies, ['dinner?', 'at eight?', 'at eight?']);
    expect(chipsOf(sink.shown.last), ['Sure']);

    // The first message's chips come after the row moved on: they answer a
    // question the notification no longer ends with.
    first.complete(const ['Yes!']);
    await pumpEventQueue();

    expect(sink.shown, hasLength(3), reason: 'stale chips are dropped');
    expect(service.smartReplyStats[SmartReplyOutcome.late], 1);
    expect(service.smartReplyStats[SmartReplyOutcome.inTime], 1);
  });

  test('chips for a conversation that was read are dropped', () async {
    final chips = Completer<List<String>>();
    service.suggestReplies = (content, thread) => chips.future;
    await service.start();
    await deliver(_message());

    await service.dismissChat('merged:contact_1');
    chips.complete(const ['On my way']);
    await pumpEventQueue();

    expect(sink.shown, hasLength(1), reason: 'a read row is not put back');
    expect(service.smartReplyStats[SmartReplyOutcome.late], 1);
  });

  test('chips that take too long are counted late, not posted', () async {
    service
      ..suggestionCap = const Duration(milliseconds: 20)
      ..suggestReplies = (content, thread) => Completer<List<String>>().future;
    await service.start();
    await deliver(_message());
    expect(sink.shown, hasLength(1));

    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();

    expect(sink.shown, hasLength(1));
    expect(service.smartReplyStats[SmartReplyOutcome.late], 1);
  });

  test('the model timing out is counted late as well', () async {
    service.suggestReplies = (content, thread) =>
        Future.error(TimeoutException('the model'));
    await service.start();
    await deliver(_message());

    expect(sink.shown, hasLength(1));
    expect(service.smartReplyStats[SmartReplyOutcome.late], 1);
    expect(service.smartReplyStats[SmartReplyOutcome.failed], 0);
  });

  test(
    'an error or no chips is counted failed, and nothing re-posted',
    () async {
      var calls = 0;
      service.suggestReplies = (content, thread) async {
        calls++;
        if (calls == 1) throw StateError('500');
        return const [];
      };
      await service.start();
      await deliver(_message(eventId: r'$e1'));
      await deliver(_message(eventId: r'$e2'));

      expect(sink.shown, hasLength(2));
      expect(service.smartReplyStats[SmartReplyOutcome.failed], 2);
    },
  );

  test('the same message posted again reuses its chips', () async {
    var calls = 0;
    service.suggestReplies = (content, thread) async {
      calls++;
      return const ['On my way'];
    };
    await service.start();
    await deliver(_message());
    expect(chipsOf(sink.shown.last), ['On my way']);

    // Read on the laptop, then the same event decided once more — a restart
    // of the pipeline's dedupe, a push replayed after a crash.
    await service.dismissChat('merged:contact_1');
    final shownBefore = sink.shown.length;
    service.postForTest(
      MatrixNotification(
        message: _message(),
        content: NotificationContent.forMessage(
          message: _message(),
          chat: _mergedChat,
          policy: NotificationPolicy(),
        ),
        decision: const NotifyDecision(),
      ),
    );
    await pumpEventQueue();

    expect(calls, 1, reason: 'the model is not asked twice for one message');
    expect(sink.shown.length, shownBefore + 1);
    expect(chipsOf(sink.shown.last), ['On my way']);
  });
}

final Chat _mergedChat = Chat(
  id: 'merged:contact_1',
  title: 'Grace',
  contactId: 'contact_1',
  sources: const [
    ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
  ],
);

Chat? _chatForRoom(String roomId) =>
    _mergedChat.roomIds.contains(roomId) ? _mergedChat : null;

WeftMessage _message({String eventId = r'$event_1', String body = 'hello'}) {
  return WeftMessage(
    eventId: eventId,
    roomId: '!wa:example.org',
    network: ChatNetwork.whatsapp,
    senderId: '@whatsapp_grace:example.org',
    senderName: 'Grace',
    timestamp: _now,
    kind: MessageKind.text,
    isOwn: false,
    body: body,
  );
}
