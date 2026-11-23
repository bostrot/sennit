import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/services/notifications/notification_service.dart';
import 'package:weft/services/notifications/reply_suggester.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import 'support/notification_fixtures.dart';

/// The chips for every engine that posts notifications, the headless one a
/// UnifiedPush poke boots included.
///
/// The bug this exists for: that engine never set `suggestReplies`, and on a
/// phone without Google services it posts nearly every notification — so the
/// chips the UI engine would have added were rare there whatever the model.
final DateTime _now = DateTime.utc(2026, 1, 15, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsStore settings;
  late List<Map<String, Object?>> asked;
  late Completer<void> answer;

  setUp(() {
    final db = WeftDatabase.openAt(':memory:');
    addTearDown(db.dispose);
    settings = SettingsStore(db)
      ..setString(WeftSettings.llmBaseUrl, 'http://localhost:4000/v1')
      ..setString(WeftSettings.llmModel, 'qwen3.8-flash-next-q2_0');
    asked = [];
    answer = Completer<void>()..complete();
  });

  http.Client server() => MockClient((request) async {
    asked.add(jsonDecode(request.body) as Map<String, Object?>);
    await answer.future;
    return http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': '{"replies": ["Ja, kauf sie!"]}'},
            'finish_reason': 'stop',
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  /// Configured the way `background_push.dart` configures it: settings and
  /// key from the stores, no calendar, no notes.
  ReplySuggester headless({bool pro = true, Set<String> service = const {}}) =>
      notificationReplySuggester(
        settings: () => settings,
        apiKey: () => 'sk-test',
        proUnlocked: () => pro,
        serviceChatIds: () => service,
        client: server(),
      );

  NotificationContent content() => NotificationContent.forMessage(
    message: _message(),
    chat: _chat,
    policy: NotificationPolicy(),
  );

  group('notificationReplySuggester', () {
    test('asks the configured model, without thinking', () async {
      final replies = await headless()(content(), [_message()]);

      expect(replies, ['Ja, kauf sie!']);
      expect(asked.single['model'], 'qwen3.8-flash-next-q2_0');
      expect(asked.single['reasoning_effort'], 'none');
    });

    test('asks the model set for suggestions when there is one', () async {
      settings.setString(
        WeftSettings.llmSuggestionModel,
        'qwen3.8-flash-next-q2_0-nothink',
      );

      await headless()(content(), [_message()]);

      expect(asked.single['model'], 'qwen3.8-flash-next-q2_0-nothink');
    });

    test(
      'asks nothing with the setting off, without Pro, or for a bot',
      () async {
        settings.setBool(WeftSettings.notifySmartReplies, value: false);
        expect(await headless()(content(), [_message()]), isEmpty);

        settings.setBool(WeftSettings.notifySmartReplies, value: true);
        expect(await headless(pro: false)(content(), [_message()]), isEmpty);
        expect(
          await headless(service: {_chat.id})(content(), [_message()]),
          isEmpty,
        );

        expect(asked, isEmpty);
      },
    );

    test('asks nothing without an endpoint', () async {
      settings.setString(WeftSettings.llmBaseUrl, '');

      expect(await headless()(content(), [_message()]), isEmpty);
      expect(asked, isEmpty);
    });
  });

  group('a headless engine', () {
    late FakeNotificationSession session;
    late MatrixNotificationPipeline pipeline;
    late RecordingNotificationSink sink;
    late WeftNotificationService service;

    setUp(() {
      sink = RecordingNotificationSink();
      session = FakeNotificationSession();
      pipeline = MatrixNotificationPipeline(
        session: session,
        chatForRoom: (r) => _chat.roomIds.contains(r) ? _chat : null,
        policy: NotificationPolicy.new,
        now: () => _now,
      );
      service = WeftNotificationService(
        sink: sink,
        pipeline: pipeline,
        chatForRoom: (r) => _chat.roomIds.contains(r) ? _chat : null,
      )..suggestReplies = headless();
    });

    tearDown(() async {
      await service.dispose();
      await pipeline.dispose();
      await session.close();
    });

    test('posts at once and is kept alive until the chips are on', () async {
      // A model slower than the push handler's own three-second beat.
      answer = Completer<void>();
      service.suggestReplies = headless();
      await service.start();
      await pipeline.handleMessage(_message());
      await pumpEventQueue();

      expect(sink.shown, hasLength(1), reason: 'posted without waiting');
      var settled = false;
      unawaited(service.chipsSettled().then((_) => settled = true));
      await pumpEventQueue();
      expect(settled, isFalse, reason: 'the chips are still being written');

      answer.complete();
      await pumpEventQueue();

      expect(settled, isTrue);
      expect(sink.shown, hasLength(2));
      expect(sink.shown.last.payload.suggestions, ['Ja, kauf sie!']);
      expect(sink.shown.last.details.android!.onlyAlertOnce, isTrue);
    });

    test('settles at once when nothing was asked', () async {
      settings.setBool(WeftSettings.notifySmartReplies, value: false);
      await service.start();
      await pipeline.handleMessage(_message());

      await service.chipsSettled().timeout(const Duration(seconds: 1));

      expect(sink.shown, hasLength(1));
    });
  });
}

final Chat _chat = Chat(
  id: '!anna:example.org',
  title: 'Anna',
  sources: const [
    ChatSource(roomId: '!anna:example.org', network: ChatNetwork.matrix),
  ],
);

WeftMessage _message() => WeftMessage(
  eventId: r'$anna_1',
  roomId: '!anna:example.org',
  network: ChatNetwork.matrix,
  senderId: '@anna:example.org',
  senderName: 'Anna',
  timestamp: _now,
  kind: MessageKind.text,
  isOwn: false,
  body: 'Soll ich drei Tickets kaufen?',
);
