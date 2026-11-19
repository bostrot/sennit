import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/services/notifications/background_actions.dart';
import 'package:weft/services/notifications/notification_actions.dart';
import 'package:weft/services/notifications/notification_channels.dart';
import 'package:weft/services/notifications/notification_presentation.dart';
import 'package:weft/services/notifications/notification_service.dart';
import 'package:weft/services/siri/siri_messaging.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

/// Android Auto and CarPlay: the parts of both that can be held without a car.
///
/// Android Auto reads notifications and answers through two headless actions;
/// CarPlay reads through Siri. What is pinned here is everything on Sennit's
/// side of those two seams — the manifest entries the head unit looks for,
/// the relay that gets a headless action to a live Matrix client, the action
/// handler that sends the reply and the receipt, and what Siri is given to
/// read and asked to send.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android Auto manifest', () {
    late String manifest;

    setUpAll(() {
      manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
    });

    test('declares Sennit a notification app for the car', () {
      expect(manifest, contains('com.google.android.gms.car.application'));
      expect(manifest, contains('@xml/automotive_app_desc'));
      final descriptor = File(
        'android/app/src/main/res/xml/automotive_app_desc.xml',
      ).readAsStringSync();
      expect(descriptor, contains('<uses name="notification"/>'));
    });

    test('has the receiver headless actions are delivered to', () {
      // The plugin does not declare it; without it Reply and Mark read from
      // the car are broadcasts to nobody.
      expect(
        manifest,
        contains(
          'com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver',
        ),
      );
    });
  });

  group('the headless action relay', () {
    const name = 'weft.test.notification_actions';
    NotificationActionServer? server;

    tearDown(() {
      server?.close();
      server = null;
      IsolateNameServer.removePortNameMapping(name);
    });

    test('with no live client, the background isolate does the work', () async {
      final result = await forwardNotificationAction(
        _activation(WeftNotificationActions.markRead),
        name: name,
      );
      expect(result, isNull);
    });

    test('a reply from the car runs on the live client', () async {
      final received = <NotificationActivation>[];
      server = NotificationActionServer.serve((activation) async {
        received.add(activation);
        return NotificationActionResult.replied;
      }, name: name);

      final result = await forwardNotificationAction(
        _activation(WeftNotificationActions.reply, input: 'on my way'),
        name: name,
      );

      expect(result, NotificationActionResult.replied);
      expect(received.single.actionId, WeftNotificationActions.reply);
      expect(received.single.input, 'on my way');
      expect(received.single.payload.chatId, 'merged:contact_1');
      expect(received.single.payload.roomId, '!wa:example.org');
    });

    test('a client that died is not waited on forever', () async {
      // A registration left behind by an isolate that has gone: the lookup
      // still finds a port, and nobody answers on it.
      final dead = ReceivePort()..close();
      IsolateNameServer.registerPortWithName(dead.sendPort, name);

      final result = await forwardNotificationAction(
        _activation(WeftNotificationActions.markRead),
        name: name,
        acceptWithin: const Duration(milliseconds: 100),
      );
      expect(result, isNull);
    });

    test('a slow send is not retried by a second client', () async {
      server = NotificationActionServer.serve(
        (_) => Future.delayed(
          const Duration(seconds: 1),
          () => NotificationActionResult.replied,
        ),
        name: name,
      );

      final result = await forwardNotificationAction(
        _activation(WeftNotificationActions.reply, input: 'hi'),
        name: name,
        finishWithin: const Duration(milliseconds: 100),
      );
      // Failed, not null: null would make the caller boot a client and send
      // the reply a second time.
      expect(result, NotificationActionResult.failed);
    });

    test('an activation crosses the boundary whole', () {
      final activation = _activation(
        WeftNotificationActions.reply,
        input: 'yes',
      );
      final back = decodeActivation(encodeActivation(activation))!;

      expect(back.actionId, activation.actionId);
      expect(back.input, activation.input);
      expect(back.payload, activation.payload);
    });
  });

  group('the headless actions themselves', () {
    late _Repository repository;
    late List<String> dismissed;
    late NotificationActionHandler handler;

    setUp(() {
      repository = _Repository();
      dismissed = [];
      handler = NotificationActionHandler(
        repository: repository,
        muteChat: (_, {DateTime? until}) {},
        dismiss: (chatId) async => dismissed.add(chatId),
      );
    });

    test('reply sends, sends the read receipt, and clears the row', () async {
      final result = await handler.handle(
        _activation(WeftNotificationActions.reply, input: ' on my way '),
      );

      expect(result, NotificationActionResult.replied);
      expect(repository.sent, [('merged:contact_1', 'on my way')]);
      expect(repository.markedRead, ['merged:contact_1']);
      expect(dismissed, ['merged:contact_1']);
    });

    test('mark read sends the receipt and clears the row', () async {
      final result = await handler.handle(
        _activation(WeftNotificationActions.markRead),
      );

      expect(result, NotificationActionResult.markedRead);
      expect(repository.sent, isEmpty);
      expect(repository.markedRead, ['merged:contact_1']);
      expect(dismissed, ['merged:contact_1']);
    });

    test('a background engine response maps to the same activation', () {
      final payload = NotificationPayload.forContent(_content()).encode();
      final activation = LocalNotificationSink.activationFor(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: WeftNotificationActions.reply,
          input: 'ok',
          payload: payload,
        ),
      )!;

      expect(activation.isTap, isFalse);
      expect(activation.input, 'ok');
      expect(activation.payload.chatId, 'merged:contact_1');
    });
  });

  group('Siri', () {
    final policy = NotificationPolicy();

    test('reads the latest unread message per conversation, newest first', () {
      final rows = siriUnreadMessages(
        [
          _chat('a', 'Anna', unread: 2, at: 10, body: 'see you'),
          _chat('b', 'Ben', unread: 0, at: 20, body: 'read already'),
          _chat('c', 'Climbing', unread: 1, at: 30, body: 'rope?', group: true),
          _chat('d', 'Dora', unread: 1, at: 40, body: 'mine', own: true),
          _chat('e', 'Eve', unread: 1, at: 50, body: 'muted', muted: true),
        ],
        policy,
        WeftNotifyStrings.english,
      );

      expect(rows.map((r) => r['chatId']), ['c', 'a']);
      expect(rows.first['isGroup'], isTrue);
      expect(rows.first['text'], 'rope?');
      expect(rows.last['senderName'], 'Anna');
      expect(rows.last['unreadCount'], 2);
    });

    test('with previews off, Siri says who wrote and nothing more', () {
      final rows = siriUnreadMessages(
        [_chat('a', 'Anna', unread: 1, at: 10, body: 'the door code is 4711')],
        policy.copyWith(showPreviews: false),
        WeftNotifyStrings.english,
      );

      expect(rows.single['text'], WeftNotifyStrings.english.hiddenPreview);
      expect(rows.single.values, isNot(contains('the door code is 4711')));
    });

    test('a spoken name finds the conversation, exact match first', () {
      final matches = siriRecipientMatches([
        _chat('1', 'Annabel Lee'),
        _chat('2', 'Anna'),
        _chat('3', 'Hanna'),
        _chat('4', 'Anna (old)', archived: true),
        _chat('5', 'Ben'),
      ], 'anna');

      expect(matches.map((m) => m['chatId']), ['2', '1', '3']);
      expect(siriRecipientMatches([_chat('1', 'Anna')], '  '), isEmpty);
    });

    test('a dictated reply is sent and the chat read', () async {
      final repository = _Repository();
      final siri = SiriMessaging(
        repository: repository,
        chats: () => const [],
        policy: () => policy,
        words: () => WeftNotifyStrings.english,
      );

      final sent = await siri.handle(
        const MethodCall('send', {'chatId': 'merged:anna', 'text': ' hi '}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sent, isTrue);
      expect(repository.sent, [('merged:anna', 'hi')]);
      expect(repository.markedRead, ['merged:anna']);
    });

    test('an empty dictation sends nothing', () async {
      final repository = _Repository();
      final siri = SiriMessaging(
        repository: repository,
        chats: () => const [],
        policy: () => policy,
        words: () => WeftNotifyStrings.english,
      );

      expect(
        await siri.handle(
          const MethodCall('send', {'chatId': 'a', 'text': '  '}),
        ),
        isFalse,
      );
      expect(repository.sent, isEmpty);
    });

    test('"mark as read" sends a receipt for every conversation', () async {
      final repository = _Repository();
      final siri = SiriMessaging(
        repository: repository,
        chats: () => const [],
        policy: () => policy,
        words: () => WeftNotifyStrings.english,
      );

      await siri.handle(
        const MethodCall('markRead', {
          'chatIds': ['a', 'b'],
        }),
      );

      expect(repository.markedRead, ['a', 'b']);
      expect(repository.sent, isEmpty);
    });
  });
}

NotificationContent _content() => NotificationContent(
  eventId: r'$event_1',
  roomId: '!wa:example.org',
  groupKey: 'merged:contact_1',
  title: 'Grace',
  body: 'hello',
  senderName: 'Grace (WhatsApp)',
  timestamp: DateTime.utc(2026, 1, 15, 21),
  network: ChatNetwork.whatsapp,
  deepLink: notificationLinkFor('merged:contact_1'),
);

NotificationActivation _activation(String actionId, {String? input}) =>
    NotificationActivation(
      payload: NotificationPayload.forContent(_content()),
      actionId: actionId,
      input: input,
    );

Chat _chat(
  String id,
  String title, {
  int unread = 0,
  int at = 0,
  String body = '',
  bool group = false,
  bool own = false,
  bool muted = false,
  bool archived = false,
}) => Chat(
  id: id,
  title: title,
  sources: [
    ChatSource(roomId: '!$id:example.org', network: ChatNetwork.matrix),
  ],
  unreadCount: unread,
  isGroup: group,
  muted: muted,
  archived: archived,
  lastMessage: WeftMessage(
    eventId: '\$$id',
    roomId: '!$id:example.org',
    network: ChatNetwork.matrix,
    senderId: '@$id:example.org',
    senderName: group ? 'Someone' : title,
    timestamp: DateTime.utc(2026, 1, 15, 21, at),
    kind: MessageKind.text,
    isOwn: own,
    body: body,
  ),
);

class _Repository implements ChatRepository {
  final List<(String, String)> sent = [];
  final List<String> markedRead = [];

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) async =>
      sent.add((chatId, body));

  @override
  Future<void> markRead(String chatId) async => markedRead.add(chatId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
