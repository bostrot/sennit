import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/app/intents.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/services/ai/conversation_context.dart';
import 'package:weft/services/notifications/notification_actions.dart';
import 'package:weft/services/notifications/notification_channels.dart';
import 'package:weft/services/notifications/notification_presentation.dart';
import 'package:weft/services/notifications/notification_service.dart';
import 'package:weft/services/notifications/push_registration.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';

import 'support/notification_fixtures.dart';

/// A fixed instant, so nothing here depends on when the suite runs.
final DateTime _now = DateTime.utc(2026, 1, 15, 21);

void main() {
  // Needed by the groups that stand a fake platform behind the real plugin;
  // harmless to the rest, which never send a platform message.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stableNotificationId', () {
    test('is a function of the key, not of call order', () {
      expect(stableNotificationId(r'$abc'), stableNotificationId(r'$abc'));
      expect(
        stableNotificationId(r'$abc'),
        isNot(stableNotificationId(r'$abd')),
      );
    });

    test('is always a positive 31-bit int', () {
      // Windows rejects a negative id outright and some launchers read 0 as
      // "no id"; both are silent failures on a device and cheap to pin here.
      for (final key in [
        '',
        r'$event',
        '!room:example.org',
        'merged:contact_17300000000_0',
        'x' * 4096,
      ]) {
        final id = stableNotificationId(key);
        expect(id, greaterThan(0), reason: key);
        expect(id, lessThanOrEqualTo(0x7fffffff), reason: key);
      }
    });
  });

  group('NotificationPayload', () {
    test('round-trips every field', () {
      final payload = NotificationPayload.forContent(_content());
      final decoded = NotificationPayload.decode(payload.encode());

      expect(decoded, payload);
      expect(decoded!.chatId, 'merged:contact_1');
      expect(decoded.roomId, '!wa:example.org');
      expect(decoded.network, ChatNetwork.whatsapp);
    });

    test('a bare link decodes rather than failing', () {
      // What a notification posted by the iOS service extension — or by an
      // older build — carries. It must still open the right conversation.
      final decoded = NotificationPayload.decode('weft://chat/!abc%3Ax.org');

      expect(decoded, isNotNull);
      expect(decoded!.link, 'weft://chat/!abc%3Ax.org');
      expect(decoded.eventId, isEmpty);
    });

    test('nothing at all, and malformed JSON, decode to null', () {
      expect(NotificationPayload.decode(null), isNull);
      expect(NotificationPayload.decode('  '), isNull);
      expect(NotificationPayload.decode('{not json'), isNull);
      expect(NotificationPayload.decode('{"chatId":"x"}'), isNull);
    });

    test('the link survives a chat id full of reserved characters', () {
      // Including a literal `%` and a non-ASCII character, which used to throw
      // `ArgumentError` out of `WeftLink.parse` — it decoded an already-decoded
      // path segment. The test-suite task wrote that up; the double decode is
      // gone, so the whole range a room or merged id can carry round-trips.
      for (final chatId in [
        '!weird +/:example.org',
        '!100%:example.org',
        'merged:contact_1',
        r'!a%2Fb:example.org',
        '!grüße:example.org',
      ]) {
        final payload = NotificationPayload.forContent(
          _content(groupKey: chatId),
        );
        final link = WeftLink.parse(
          NotificationPayload.decode(payload.encode())!.link,
        );

        expect(link, isA<OpenChatLink>(), reason: chatId);
        expect((link! as OpenChatLink).chatId, chatId, reason: chatId);
      }
    });
  });

  group('NotificationPresentation.forMessage', () {
    test('posts to the channel of the network the message arrived on', () {
      final android = NotificationPresentation.forMessage(
        content: _content(network: ChatNetwork.signal),
      ).details.android!;

      expect(android.channelId, 'weft.messages.signal');
      expect(android.channelId, messageChannelFor(ChatNetwork.signal).id);
    });

    test(
      'groups on the merged chat id, and iOS threads on the same string',
      () {
        final whatsapp = NotificationPresentation.forMessage(
          content: _content(eventId: r'$1', roomId: '!wa:example.org'),
        );
        final signal = NotificationPresentation.forMessage(
          content: _content(
            eventId: r'$2',
            roomId: '!sg:example.org',
            network: ChatNetwork.signal,
          ),
        );

        // The one assertion this whole layer exists for: two legs of one merged
        // contact are one notification thread on both platforms.
        expect(whatsapp.groupKey, signal.groupKey);
        expect(whatsapp.details.android!.groupKey, 'merged:contact_1');
        expect(
          whatsapp.details.iOS!.threadIdentifier,
          whatsapp.details.android!.groupKey,
        );
        expect(
          signal.details.iOS!.threadIdentifier,
          whatsapp.details.iOS!.threadIdentifier,
        );
        // …and *one* notification: same conversation, same id, so the
        // second replaces the first instead of standing beside it.
        expect(whatsapp.id, signal.id);
      },
    );

    test('two genuinely different chats do not share a group', () {
      final a = NotificationPresentation.forMessage(
        content: _content(groupKey: '!a:example.org'),
      );
      final b = NotificationPresentation.forMessage(
        content: _content(groupKey: '!b:example.org'),
      );

      expect(a.groupKey, isNot(b.groupKey));
      expect(a.details.android!.groupKey, isNot(b.details.android!.groupKey));
    });

    test('renders the thread as MessagingStyle, oldest first', () {
      final first = _content(eventId: r'$1', body: 'one');
      final second = _content(eventId: r'$2', body: 'two');

      final style =
          NotificationPresentation.forMessage(
                content: second,
                conversation: [first, second],
              ).details.android!.styleInformation!
              as MessagingStyleInformation;

      // No conversation title for a DM: the sender line already names the
      // person, and Android would otherwise print the name twice — once as
      // the header and once with the network appended.
      expect(style.conversationTitle, isNull);
      expect(style.messages!.map((m) => m.text), ['one', 'two']);
      expect(style.messages!.first.person!.name, 'Grace (WhatsApp)');
      expect(style.groupConversation, isFalse);
    });

    test('a mention outranks an ordinary message on every platform', () {
      final plain = NotificationPresentation.forMessage(content: _content());
      final mention = NotificationPresentation.forMessage(
        content: _content(isMention: true),
      );

      expect(plain.details.android!.importance, Importance.high);
      expect(mention.details.android!.importance, Importance.max);
      expect(
        mention.details.iOS!.interruptionLevel,
        InterruptionLevel.timeSensitive,
      );
    });

    test('a silent decision posts without sound rather than not posting', () {
      final silent = NotificationPresentation.forMessage(
        content: _content(),
        silent: true,
      );

      expect(silent.details.android!.silent, isTrue);
      expect(silent.details.iOS!.presentSound, isFalse);
      expect(silent.details.linux!.suppressSound, isTrue);
      // Still a notification: quiet hours with `deliverSilently` means it is
      // waiting in the shade in the morning.
      expect(silent.body, isNotEmpty);
    });

    test('avatars reach every surface that can draw one', () {
      final presentation = NotificationPresentation.forMessage(
        content: _content(),
        avatarPaths: {r'$event_1': '/tmp/grace.png'},
      );

      expect(
        (presentation.details.android!.largeIcon! as FilePathAndroidBitmap)
            .data,
        '/tmp/grace.png',
      );
      expect(presentation.details.linux!.icon, isA<FilePathLinuxIcon>());
      expect(presentation.details.windows!.images, hasLength(1));
    });

    test('names a conversation shortcut so the notification can bubble', () {
      final android = NotificationPresentation.forMessage(
        content: _content(),
      ).details.android!;

      expect(android.shortcutId, chatShortcutId('merged:contact_1'));
      // Sanitised: the raw id goes into launcher-owned XML.
      expect(chatShortcutId('!room:example.org'), 'chat__room_example.org');
    });
  });

  group('NotificationPresentation.forSummary', () {
    test('is a group summary with the inbox lines under it', () {
      final contents = [
        for (var i = 0; i < 3; i++) _content(eventId: '\$e$i', body: 'line $i'),
      ];
      final presentation = NotificationPresentation.forSummary(
        summarise(contents)!,
      );
      final android = presentation.details.android!;
      final style = android.styleInformation! as InboxStyleInformation;

      expect(presentation.body, '3 new messages');
      expect(android.setAsGroupSummary, isTrue);
      expect(android.groupKey, 'merged:contact_1');
      // The children already made the noise; the summary must not repeat it.
      expect(android.groupAlertBehavior, GroupAlertBehavior.children);
      expect(style.lines, hasLength(3));
      expect(style.summaryText, isNull);
    });

    test('counts what it could not list', () {
      final contents = [
        for (var i = 0; i < 9; i++) _content(eventId: '\$e$i', body: 'line $i'),
      ];
      final presentation = NotificationPresentation.forSummary(
        summarise(contents)!,
      );
      final style =
          presentation.details.android!.styleInformation!
              as InboxStyleInformation;

      expect(style.lines, hasLength(kMaxSummaryLines));
      expect(style.summaryText, '+4 more');
    });

    test('is Android-only — iOS stacks by thread and would double up', () {
      final presentation = NotificationPresentation.forSummary(
        summarise([_content(), _content(eventId: r'$2')])!,
      );

      expect(presentation.details.iOS, isNull);
      expect(presentation.details.macOS, isNull);
      // A distinct id from any of its children, or posting it would replace one.
      expect(presentation.id, isNot(stableNotificationId(r'$event_1')));
    });
  });

  group('WeftNotificationService', () {
    late RecordingNotificationSink sink;
    late FakeNotificationSession session;
    late MatrixNotificationPipeline pipeline;
    late WeftNotificationService service;

    /// Read per message by the pipeline, so a test can change it after start.
    late NotificationPolicy policy;

    setUp(() {
      sink = RecordingNotificationSink();
      session = FakeNotificationSession();
      policy = NotificationPolicy();
      pipeline = MatrixNotificationPipeline(
        session: session,
        chatForRoom: _chatForRoom,
        policy: () => policy,
        now: () => _now,
      );
      service = WeftNotificationService(
        sink: sink,
        pipeline: pipeline,
        chatForRoom: _chatForRoom,
      );
    });

    /// A message decided *and* delivered.
    ///
    /// The pipeline publishes on a broadcast stream, so `handleMessage`
    /// returning is not the notification having been posted — the same gap the
    /// service's own post queue exists to make orderly.
    Future<void> deliver(WeftMessage message) async {
      await pipeline.handleMessage(message);
      await pumpEventQueue();
    }

    tearDown(() async {
      await service.dispose();
      await pipeline.dispose();
      await session.close();
    });

    test('a message decided on is a notification posted', () async {
      await service.start();
      await deliver(_message());

      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.title, 'Grace');
      expect(sink.shown.single.body, 'hello');
      expect(sink.shown.single.groupKey, 'merged:contact_1');
      // The shortcut has to exist before the notification that names it.
      expect(sink.shortcuts.single.id, chatShortcutId('merged:contact_1'));
    });

    test('a suppressed message posts nothing at all', () async {
      await service.start();
      await deliver(_message(isOwn: true));

      expect(sink.shown, isEmpty);
      expect(sink.shortcuts, isEmpty);
    });

    test('two legs of a merged contact are one thread and one link', () async {
      await service.start();
      await deliver(_message(eventId: r'$wa', roomId: '!wa:example.org'));
      await deliver(
        _message(
          eventId: r'$sg',
          roomId: '!sg:example.org',
          network: ChatNetwork.signal,
        ),
      );

      final messages = sink.shown
          .where((p) => p.details.android!.setAsGroupSummary != true)
          .toList();
      expect(messages.map((p) => p.groupKey).toSet(), {'merged:contact_1'});
      expect(messages.map((p) => p.payload.link).toSet(), hasLength(1));
      // The room ids stay distinct, because an action has to land somewhere real.
      expect(messages.map((p) => p.payload.roomId).toSet(), {
        '!wa:example.org',
        '!sg:example.org',
      });
    });

    test('the second message replaces the first, thread and all', () async {
      await service.start();
      await deliver(_message(eventId: r'$1', body: 'one'));
      await deliver(_message(eventId: r'$2', body: 'two'));

      // Two posts, one id: the platform swaps the row in place, so the shade
      // holds a single conversation whose thread has grown to two lines.
      expect(sink.shown, hasLength(2));
      expect(sink.shown.first.id, sink.shown.last.id);
      final style =
          sink.shown.last.details.android!.styleInformation!
              as MessagingStyleInformation;
      expect(style.messages!.map((m) => m.text), ['one', 'two']);
      // And no summary row: the conversation *is* one notification now.
      expect(
        sink.shown.every((p) => p.details.android!.setAsGroupSummary != true),
        isTrue,
      );
    });

    test('a backfill keeps the shade bounded', () async {
      await service.start();
      for (var i = 0; i < 9; i++) {
        await deliver(_message(eventId: '\$e$i', body: 'm$i'));
      }

      // Remembered in full…
      expect(service.postedFor('merged:contact_1'), hasLength(9));
      // …while the one row shows only the newest window of the thread, and
      // nothing needed cancelling because nothing else was ever posted.
      final style =
          sink.shown.last.details.android!.styleInformation!
              as MessagingStyleInformation;
      expect(style.messages, hasLength(kMaxNotificationsPerChat));
      expect(style.messages!.last.text, 'm8');
      expect(sink.cancelled, isEmpty);
    });

    test('an event arriving by push and by sync notifies once', () async {
      await service.start();
      session.messages[r'$e1'] = _message(eventId: r'$e1');

      await service.handlePush({
        'room_id': '!wa:example.org',
        'event_id': r'$e1',
      });
      await pumpEventQueue();
      await deliver(_message(eventId: r'$e1'));

      expect(sink.shown, hasLength(1));
    });

    test('a clearing push dismisses instead of posting', () async {
      await service.start();
      await deliver(_message(eventId: r'$e1'));
      sink.cancelled.clear();

      // No event id: the homeserver saying the unread count dropped, which
      // means the user read the room on another device.
      await service.handlePush({
        'room_id': '!wa:example.org',
        'counts': {'unread': 0},
      });
      await pumpEventQueue();

      expect(sink.shown, hasLength(1), reason: 'nothing new was posted');
      expect(service.postedFor('merged:contact_1'), isEmpty);
      expect(
        sink.cancelled.map((c) => c.id),
        contains(stableNotificationId(r'$e1')),
      );
    });

    test('reading one leg clears the whole merged conversation', () async {
      await service.start();
      await deliver(_message(eventId: r'$wa', roomId: '!wa:example.org'));
      await deliver(
        _message(
          eventId: r'$sg',
          roomId: '!sg:example.org',
          network: ChatNetwork.signal,
        ),
      );
      sink.cancelled.clear();

      await service.dismissRoom('!sg:example.org');

      expect(service.postedFor('merged:contact_1'), isEmpty);
      expect(
        sink.cancelled.map((c) => c.id),
        containsAll([
          stableNotificationId(r'$wa'),
          stableNotificationId(r'$sg'),
        ]),
      );
    });

    test(
      'a tap hands the deep link to the router, not to a second one',
      () async {
        String? opened;
        service.onOpenLink = (link) => opened = link;
        await service.start();
        await deliver(_message());

        sink.activate(sink.shown.first);

        expect(opened, 'weft://chat/merged%3Acontact_1');
        final link = WeftLink.parse(opened!);
        expect((link! as OpenChatLink).chatId, 'merged:contact_1');
      },
    );

    test('a cold-start tap is replayed through the same route', () async {
      String? opened;
      sink.launch = NotificationActivation(
        payload: NotificationPayload.forContent(_content()),
      );
      service.onOpenLink = (link) => opened = link;

      await service.start();

      expect(opened, 'weft://chat/merged%3Acontact_1');
    });

    test(
      'an action goes to the action handler and never opens a chat',
      () async {
        String? opened;
        NotificationActivation? action;
        service.onOpenLink = (link) => opened = link;
        service.onAction = (a) => action = a;
        await service.start();
        await deliver(_message());

        sink.activate(
          sink.shown.first,
          actionId: WeftNotificationActions.reply,
          input: 'on my way',
        );

        expect(opened, isNull);
        expect(action!.actionId, WeftNotificationActions.reply);
        expect(action!.input, 'on my way');
        expect(action!.payload.roomId, '!wa:example.org');
      },
    );

    test('a test notification posts through the real path', () async {
      await service.start();
      final decision = await service.sendTestNotification(now: _now);
      await pumpEventQueue();

      expect(decision, const NotifyDecision());
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.groupKey, kTestNotificationChatId);
      expect(sink.shown.single.title, 'Notification test');
      // Same sink, same presentation, same payload as a real message: the
      // button proves the chain rather than a path of its own — including that
      // its link round-trips through the router every tap goes through.
      final link = WeftLink.parse(sink.shown.single.payload.link);
      expect((link! as OpenChatLink).chatId, kTestNotificationChatId);
    });

    test('a test notification never joins someone else\'s thread', () async {
      // `_chatForRoom` resolves *every* room to the merged contact, so a test
      // that took its chat from the room id would land in Grace's thread and
      // count a message she never sent into her summary.
      await service.start();
      await service.sendTestNotification(now: _now);
      await pumpEventQueue();

      expect(service.postedFor('merged:contact_1'), isEmpty);
      expect(service.postedFor(kTestNotificationChatId), hasLength(1));
    });

    test('two presses are two notifications, not a duplicate', () async {
      await service.start();
      await service.sendTestNotification(
        now: _now.add(const Duration(seconds: 1)),
      );
      await service.sendTestNotification(
        now: _now.add(const Duration(seconds: 2)),
      );
      await pumpEventQueue();

      // Both presses posted — the second replacing the first under the same
      // id, its thread two lines long, exactly as two real messages would.
      expect(service.postedFor(kTestNotificationChatId), hasLength(2));
      final style =
          sink.shown.last.details.android!.styleInformation!
              as MessagingStyleInformation;
      expect(style.messages, hasLength(2));
    });

    test('a suppressed test names the setting responsible', () async {
      // The answer the button exists to give: not silence, but "quiet hours".
      await service.start();
      policy = NotificationPolicy(enabled: false);
      final decision = await service.sendTestNotification(now: _now);
      await pumpEventQueue();

      expect(decision.suppression, NotificationSuppression.globallyDisabled);
      expect(sink.shown, isEmpty);
    });

    test('a tap on a Signal message opens the merged conversation', () async {
      // The sentence this whole phase is built around, asserted at the top of
      // the stack: what the user tapped was a Signal notification, and where
      // they land is the conversation — not `!sg:example.org`.
      String? opened;
      service.onOpenLink = (link) => opened = link;
      await service.start();
      await deliver(
        _message(
          eventId: r'$sg',
          roomId: '!sg:example.org',
          network: ChatNetwork.signal,
        ),
      );

      sink.activate(sink.shown.first);

      final link = WeftLink.parse(opened!)! as OpenChatLink;
      expect(link.chatId, 'merged:contact_1');
      expect(link.chatId, isNot('!sg:example.org'));
    });

    test('a cold-start action is an action, not a tap', () async {
      // The reply typed in the shade of a phone where Weft had been killed. It
      // arrives through the launch details rather than the callback, and
      // routing it to the link handler would open a chat and drop the message.
      String? opened;
      NotificationActivation? action;
      sink.launch = NotificationActivation(
        payload: NotificationPayload.forContent(_content()),
        actionId: WeftNotificationActions.reply,
        input: 'five minutes',
      );
      service.onOpenLink = (link) => opened = link;
      service.onAction = (a) => action = a;

      await service.start();

      expect(opened, isNull);
      expect(action!.input, 'five minutes');
    });

    test('starting twice does not notify twice', () async {
      // The session state stream re-emits `ready` on every reconnection, and a
      // second subscription on the pipeline is two notifications per message.
      await service.start();
      await service.start();
      await deliver(_message());

      expect(sink.shown, hasLength(1));
    });

    test('permission is the sink\'s to ask for', () async {
      expect(await service.requestPermission(), isTrue);
    });

    test('the three shapes a push really arrives in all post', () async {
      await service.start();
      // The gateway's own envelope, a flattened FCM data map where every value
      // is a string, and an APNs payload with the Matrix keys beside `aps`.
      final payloads = <Map<String, Object?>>[
        {
          'notification': {'room_id': '!wa:example.org', 'event_id': r'$p1'},
        },
        {'room_id': '!wa:example.org', 'event_id': r'$p2', 'unread': '3'},
        {
          'aps': {'mutable-content': 1},
          'room_id': '!wa:example.org',
          'event_id': r'$p3',
        },
      ];
      for (var i = 0; i < payloads.length; i++) {
        session.messages['\$p${i + 1}'] = _message(eventId: '\$p${i + 1}');
        await service.handlePush(payloads[i]);
        await pumpEventQueue();
      }

      expect(service.postedFor('merged:contact_1'), hasLength(3));
    });

    test('a clearing push for a room no chat claims still clears it', () async {
      // `dismissRoom` falls back to the group keys holding a notification from
      // that room. Without it a chat the inbox has since dropped keeps its
      // notification forever, because nothing else will ever name it.
      final orphan = WeftNotificationService(sink: sink, pipeline: pipeline);
      addTearDown(orphan.dispose);
      await orphan.start();
      await deliver(_message(eventId: r'$e1'));

      await orphan.dismissRoom('!wa:example.org');

      expect(orphan.postedFor('merged:contact_1'), isEmpty);
      expect(
        sink.cancelled.map((c) => c.id),
        contains(stableNotificationId(r'$e1')),
      );
    });

    test('quiet hours that deliver silently post silently', () async {
      // The only producer of the silent case, end to end: policy → decision →
      // the flag every backend reads. `_now` is 21:00 UTC, inside the window.
      policy = NotificationPolicy(
        quietHours: const QuietHours(
          startMinute: 20 * 60,
          endMinute: 7 * 60,
          offsetMinutes: 0,
          deliverSilently: true,
        ),
      );
      await service.start();
      await deliver(_message());

      final posted = sink.shown.single;
      expect(posted.details.android!.silent, isTrue);
      expect(posted.details.iOS!.presentSound, isFalse);
      expect(posted.body, 'hello', reason: 'silent is not suppressed');
    });

    test('the avatar is fetched once and drawn on every surface', () async {
      final requested = <String>[];
      final withAvatars = WeftNotificationService(
        sink: sink,
        pipeline: pipeline,
        chatForRoom: _chatForRoom,
        avatarLoader: (url) async {
          requested.add(url);
          return '/tmp/grace.png';
        },
      );
      addTearDown(withAvatars.dispose);
      await withAvatars.start();
      await deliver(_message(eventId: r'$1'));
      await deliver(_message(eventId: r'$2'));

      expect(requested, hasLength(2), reason: 'cached inside the loader');
      expect(requested.first, 'https://example.org/thumb/grace');
      // A file path, because every backend draws the icon itself.
      final message = sink.shown.firstWhere(
        (p) => p.details.android!.setAsGroupSummary != true,
      );
      expect(
        (message.details.android!.largeIcon! as FilePathAndroidBitmap).data,
        '/tmp/grace.png',
      );
      expect(sink.shortcuts.last.id, chatShortcutId('merged:contact_1'));
    });

    test(
      'an avatar that will not load costs a face, not a notification',
      () async {
        final withAvatars = WeftNotificationService(
          sink: sink,
          pipeline: pipeline,
          chatForRoom: _chatForRoom,
          avatarLoader: (url) async => null,
        );
        addTearDown(withAvatars.dispose);
        await withAvatars.start();
        await deliver(_message());

        expect(sink.shown, hasLength(1));
        expect(sink.shown.single.details.android!.largeIcon, isNull);
      },
    );

    test(
      'a weekend of unread messages is counted, not remembered forever',
      () async {
        await service.start();
        for (var i = 0; i < kMaxTrackedNotificationsPerChat + 20; i++) {
          await deliver(_message(eventId: '\$e$i', body: 'm$i'));
        }

        // The memory is bounded, and the one row shows only the newest
        // window of it.
        expect(
          service.postedFor('merged:contact_1'),
          hasLength(kMaxTrackedNotificationsPerChat),
        );
        final style =
            sink.shown.last.details.android!.styleInformation!
                as MessagingStyleInformation;
        expect(style.messages, hasLength(kMaxNotificationsPerChat));
      },
    );
  });

  group('the conversation the reply chips are suggested from', () {
    late RecordingNotificationSink sink;
    late FakeNotificationSession session;
    late MatrixNotificationPipeline pipeline;
    late WeftNotificationService service;

    /// Every thread the suggester was handed, in order.
    late List<List<WeftMessage>> asked;

    /// Read per message by the pipeline, so a test can change it after start.
    late NotificationPolicy policy;

    setUp(() {
      sink = RecordingNotificationSink();
      session = FakeNotificationSession();
      policy = NotificationPolicy();
      pipeline = MatrixNotificationPipeline(
        session: session,
        chatForRoom: _chatForRoom,
        policy: () => policy,
        now: () => _now,
      );
      service = WeftNotificationService(
        sink: sink,
        pipeline: pipeline,
        chatForRoom: _chatForRoom,
        // The real wiring: one stream feeds both the pipeline's decisions and
        // the conversation buffer, which is what lets a suppressed message be
        // in the buffer and not in the shade.
        conversations: session.incomingMessages,
      );
      asked = [];
      service.suggestReplies = (content, thread) async {
        asked.add(thread);
        return const ['On my way'];
      };
    });

    /// Published on the sync path, the way a real message arrives.
    ///
    /// Through the stream rather than `pipeline.handleMessage`, unlike the
    /// group above: the stream *is* the thing under test here.
    Future<void> deliver(WeftMessage message) async {
      session.deliver(message);
      await pumpEventQueue();
    }

    tearDown(() async {
      await service.dispose();
      await pipeline.dispose();
      await session.close();
    });

    test('is more than the one row in the shade can draw', () async {
      // The bug this exists for: the suggester used to be handed the window
      // the notification *draws*, which is five lines and a UI number. A model
      // answering "which one?" needs the message that said what the choices
      // were.
      await service.start();
      for (var i = 0; i < kMaxNotificationsPerChat + 4; i++) {
        await deliver(_message(eventId: '\$e$i', body: 'm$i'));
      }

      expect(
        asked.last,
        hasLength(kMaxNotificationsPerChat + 4),
        reason: 'the AI window is its own number, not the shade\'s',
      );
      expect(asked.last.map((c) => c.body).first, 'm0');
      expect(asked.last.map((c) => c.body).last, 'm8');
    });

    test('is bounded at the shared AI constant', () async {
      await service.start();
      for (var i = 0; i < kAiContextMessages * 2; i++) {
        await deliver(_message(eventId: '\$e$i', body: 'm$i'));
      }

      // The quantity that leaves the device is a privacy number, and this is
      // the assertion that keeps it one — the same one
      // `auto_reply_service_test.dart` makes about the other AI feature.
      expect(
        service.aiContextFor('merged:contact_1'),
        hasLength(kAiContextMessages),
      );
      expect(asked.last, hasLength(kAiContextMessages));
      expect(asked.last.last.body, 'm${kAiContextMessages * 2 - 1}');
    });

    test('survives the conversation being read', () async {
      // The common case, and the one that made the feature look like it only
      // ever saw the newest message: the user reads the chat — which clears
      // the shade and, with it, everything the suggester used to be given —
      // and one more message arrives.
      await service.start();
      await deliver(_message(eventId: r'$e1', body: 'pizza or ramen?'));
      await deliver(_message(eventId: r'$e2', body: 'I can book either'));

      await service.dismissChat('merged:contact_1');
      expect(service.postedFor('merged:contact_1'), isEmpty);

      await deliver(_message(eventId: r'$e3', body: 'well?'));

      expect(asked.last.map((c) => c.body), [
        'pizza or ramen?',
        'I can book either',
        'well?',
      ]);
    });

    test('is remembered even while nothing is asked of the model', () async {
      // The setting can be switched on between two messages, and the first
      // suggestion after that should have the conversation behind it rather
      // than starting from one line.
      service.suggestReplies = null;
      await service.start();
      await deliver(_message(eventId: r'$e1', body: 'pizza or ramen?'));
      await deliver(_message(eventId: r'$e2', body: 'I can book either'));

      service.suggestReplies = (content, thread) async {
        asked.add(thread);
        return const [];
      };
      await deliver(_message(eventId: r'$e3', body: 'well?'));

      expect(asked.single.map((c) => c.body), [
        'pizza or ramen?',
        'I can book either',
        'well?',
      ]);
    });

    test(
      'is dropped with the service, not kept for the next session',
      () async {
        await service.start();
        await deliver(_message(eventId: r'$e1', body: 'pizza or ramen?'));
        expect(service.aiContextFor('merged:contact_1'), hasLength(1));

        await service.dispose();

        expect(service.aiContextFor('merged:contact_1'), isEmpty);
      },
    );

    test(
      'a silent notification joins it without spending a completion',
      () async {
        // Quiet hours post silently and must not ask someone's local model for
        // chips nobody will see — but the message was still said, and the next
        // audible one is answered better for knowing it. `_now` is 21:00 UTC,
        // inside the window below.
        policy = NotificationPolicy(
          quietHours: const QuietHours(
            startMinute: 20 * 60,
            endMinute: 7 * 60,
            offsetMinutes: 0,
            deliverSilently: true,
          ),
        );
        await service.start();
        await deliver(_message(eventId: r'$e1', body: 'pizza or ramen?'));

        expect(asked, isEmpty, reason: 'nothing to suggest into a silent row');
        expect(service.aiContextFor('merged:contact_1'), hasLength(1));

        policy = NotificationPolicy();
        await deliver(_message(eventId: r'$e2', body: 'well?'));

        expect(asked.single.map((c) => c.body), ['pizza or ramen?', 'well?']);
      },
    );
  });

  group('push registration', () {
    test('a gateway URL comes from settings and must be a URL', () {
      expect(
        resolvePushGateway('https://push.example.org/_matrix/push/v1/notify'),
        Uri.parse('https://push.example.org/_matrix/push/v1/notify'),
      );
      // A half-typed URL degrades to "no push", not to a pusher the homeserver
      // accepts and can never deliver to.
      for (final bad in [null, '', '   ', 'push.example.org', 'not a url']) {
        expect(resolvePushGateway(bad), isNull, reason: '$bad');
      }
    });

    test('the pusher never asks the homeserver for a message body', () {
      final pusher = WeftPushRegistration.pusherFor(
        token: 'fcm-token',
        gatewayUrl: Uri.parse('https://push.example.org/notify'),
      );
      final data = pusher.toJson()['data']! as Map<String, Object?>;

      expect(data['format'], kEventIdOnlyFormat);
      expect(pusher.toJson()['append'], isFalse);
    });

    test('Android and iOS register as different apps', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final android = WeftPushRegistration.pusherFor(
        token: 't',
        gatewayUrl: Uri.parse('https://push.example.org/notify'),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final ios = WeftPushRegistration.pusherFor(
        token: 't',
        gatewayUrl: Uri.parse('https://push.example.org/notify'),
      );
      debugDefaultTargetPlatformOverride = null;

      expect(android.appId, kAndroidPushAppId);
      expect(ios.appId, kIosPushAppId);
      // The gateway routes on the app id; only iOS needs a payload that lets
      // the service extension run.
      expect(android.defaultPayload, isEmpty);
      expect((ios.defaultPayload['aps']! as Map)['mutable-content'], 1);
    });

    test('desktop is not a failure, it is a platform without push', () async {
      // The host this suite runs on is macOS or Linux, which is the point.
      final registration = WeftPushRegistration(
        registry: MatrixPusherRegistry(session: _UnusableApiSession()),
        keyStore: _MemoryPushKeyStore(),
        tokens: null,
        gatewayUrl: Uri.parse('https://push.example.org/notify'),
      );

      final outcome = await registration.ensureRegistered();

      expect(outcome.status, PushRegistrationStatus.unsupportedPlatform);
      expect(outcome.isRegistered, isFalse);
    });

    test('no gateway configured says so in a sentence', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final outcome = await WeftPushRegistration(
        registry: MatrixPusherRegistry(session: _UnusableApiSession()),
        keyStore: _MemoryPushKeyStore(),
        tokens: _FakePushTransport(null),
        gatewayUrl: null,
      ).ensureRegistered();

      expect(outcome.status, PushRegistrationStatus.notConfigured);
      expect(outcome.message, contains('push gateway'));
    });

    test('no token yet is a wait, not an error', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final outcome = await WeftPushRegistration(
        registry: MatrixPusherRegistry(session: _UnusableApiSession()),
        keyStore: _MemoryPushKeyStore(),
        tokens: _FakePushTransport(null),
        gatewayUrl: Uri.parse('https://push.example.org/notify'),
      ).ensureRegistered();

      expect(outcome.status, PushRegistrationStatus.noToken);
    });
  });

  group('notification channels', () {
    test('every network has its own channel, grouped under Messages', () {
      final channels = weftNotificationChannels();
      final messageChannels = channels
          .where((c) => c.id.startsWith(kMessageChannelPrefix))
          .toList();

      expect(messageChannels, hasLength(ChatNetwork.values.length));
      expect(messageChannels.map((c) => c.groupId).toSet(), {
        kMessagesChannelGroupId,
      });
      // Ids are unique, or two networks share one volume slider.
      expect(channels.map((c) => c.id).toSet(), hasLength(channels.length));
    });

    test('calls and background sync are separate from messages', () {
      final channels = {for (final c in weftNotificationChannels()) c.id: c};

      expect(channels[kCallsChannelId]!.importance, Importance.max);
      expect(channels[kBackgroundChannelId]!.importance, Importance.low);
      expect(channels[kBackgroundChannelId]!.showBadge, isFalse);
    });

    test('the iOS category carries the three actions a message has', () {
      final category = weftDarwinCategories().single;

      expect(category.identifier, kMessageCategoryId);
      expect(category.actions.map((a) => a.identifier), [
        WeftNotificationActions.reply,
        WeftNotificationActions.markRead,
        WeftNotificationActions.muteForAnHour,
      ]);
      // Reply is a text field, or it is not a reply. `buttonTitle` is only ever
      // set by `DarwinNotificationAction.text`, so it is the assertion the
      // package's exported surface allows.
      expect(category.actions.first.buttonTitle, 'Send');
      expect(category.actions.first.placeholder, 'Message');
    });

    test('Android carries the same three actions under the same ids', () {
      final android = weftAndroidMessageActions();

      // The ids are what the handler switches on, and iOS and Android must
      // agree on them or one platform's buttons quietly do nothing.
      expect(
        android.map((a) => a.id),
        weftDarwinCategories().single.actions.map((a) => a.identifier),
      );
      expect(android.map((a) => a.id), [
        WeftNotificationActions.reply,
        WeftNotificationActions.markRead,
        WeftNotificationActions.muteForAnHour,
      ]);
    });

    test('reply is the only Android action with an input field', () {
      final actions = {for (final a in weftAndroidMessageActions()) a.id: a};

      expect(actions[WeftNotificationActions.reply]!.inputs, hasLength(1));
      expect(
        actions[WeftNotificationActions.reply]!.inputs.single.label,
        'Message',
      );
      expect(
        actions[WeftNotificationActions.reply]!.semanticAction,
        SemanticAction.reply,
      );
      expect(actions[WeftNotificationActions.markRead]!.inputs, isEmpty);
      expect(actions[WeftNotificationActions.muteForAnHour]!.inputs, isEmpty);
    });

    test('every Android action is delivered to the main isolate', () {
      // The load-bearing flag on this whole layer. `showsUserInterface: false`
      // sends the action to a *background* isolate that has no Matrix client,
      // no vodozemac and no handle on the database — which is to say, to
      // nowhere the work can be done. See `weftAndroidMessageActions`.
      for (final action in weftAndroidMessageActions()) {
        expect(action.showsUserInterface, isTrue, reason: action.id);
        // Dismissal is the handler's, and only after the work succeeded.
        expect(action.cancelNotification, isFalse, reason: action.id);
        expect(action.allowGeneratedReplies, isFalse, reason: action.id);
      }
    });

    test('a posted message notification actually carries them', () {
      final android = NotificationPresentation.forMessage(
        content: _content(),
      ).details.android!;

      expect(
        android.actions?.map((a) => a.id),
        weftAndroidMessageActions().map((a) => a.id),
      );
    });
  });

  group('NotificationActionHandler', () {
    late _ActionRepository repository;
    late List<String> dismissed;
    late NotificationPolicy policy;
    late NotificationActionHandler handler;

    setUp(() {
      repository = _ActionRepository();
      dismissed = [];
      policy = NotificationPolicy();
      handler = NotificationActionHandler(
        repository: repository,
        muteChat: (chatId, {DateTime? until}) =>
            policy = policy.muteChat(chatId, until: until),
        dismiss: (chatId) async => dismissed.add(chatId),
      );
    });

    test('a reply sends on the chat, not on the room that buzzed', () async {
      final result = await handler.handle(
        _activation(WeftNotificationActions.reply, input: 'on my way'),
      );

      expect(result, NotificationActionResult.replied);
      expect(repository.sent, hasLength(1));
      // The merged chat id. Sending to `!wa:example.org` would put the reply in
      // one leg of a conversation the user answered as a whole.
      expect(repository.sent.single.chatId, 'merged:contact_1');
      expect(repository.sent.single.body, 'on my way');
      // No `via`: the repository resolves the chat's own send network, exactly
      // as the composer does. A merged contact set to Signal does not start
      // answering over WhatsApp because WhatsApp is what happened to buzz.
      expect(repository.sent.single.via, isNull);
    });

    test('replying marks the conversation read and clears it', () async {
      await handler.handle(
        _activation(WeftNotificationActions.reply, input: 'ok'),
      );

      expect(repository.markedRead, ['merged:contact_1']);
      expect(dismissed, ['merged:contact_1']);
    });

    test('an empty reply is a closed input field, not a message', () async {
      for (final input in [null, '', '   ', '\n']) {
        final result = await handler.handle(
          _activation(WeftNotificationActions.reply, input: input),
        );
        expect(result, NotificationActionResult.ignored, reason: '$input');
      }

      expect(repository.sent, isEmpty);
      expect(repository.markedRead, isEmpty);
      expect(dismissed, isEmpty, reason: 'nothing happened, so nothing clears');
    });

    test('a reply that will not send leaves the notification up', () async {
      repository.failSend = true;

      final result = await handler.handle(
        _activation(WeftNotificationActions.reply, input: 'on my way'),
      );

      expect(result, NotificationActionResult.failed);
      // The notification is the only remaining evidence that the message was
      // neither read nor answered. Clearing it would hide both.
      expect(dismissed, isEmpty);
      expect(repository.markedRead, isEmpty);
    });

    test('a reply survives a read marker that will not move', () async {
      repository.failMarkRead = true;

      final result = await handler.handle(
        _activation(WeftNotificationActions.reply, input: 'on my way'),
      );

      // The message went. Telling the user it failed because a receipt did not
      // land would be a lie about the only part they care about.
      expect(result, NotificationActionResult.replied);
      expect(dismissed, ['merged:contact_1']);
    });

    test('mark read moves the marker for the whole chat', () async {
      final result = await handler.handle(
        _activation(WeftNotificationActions.markRead),
      );

      expect(result, NotificationActionResult.markedRead);
      // The chat id, so `markRead` walks every leg — which is what makes the
      // receipt dismiss this notification on the user's other devices.
      expect(repository.markedRead, ['merged:contact_1']);
      expect(dismissed, ['merged:contact_1']);
      expect(repository.sent, isEmpty);
    });

    test('mark read that fails leaves the notification up', () async {
      repository.failMarkRead = true;

      expect(
        await handler.handle(_activation(WeftNotificationActions.markRead)),
        NotificationActionResult.failed,
      );
      expect(dismissed, isEmpty);
    });

    test('mute for an hour writes a mute an hour out, and no further', () async {
      await withClock(Clock.fixed(_now), () async {
        expect(
          await handler.handle(
            _activation(WeftNotificationActions.muteForAnHour),
          ),
          NotificationActionResult.muted,
        );
      });

      final override = policy.overrideFor('merged:contact_1');
      expect(override.mutedUntil, _now.add(const Duration(hours: 1)));
      // A timed mute, never an indefinite one: `muted` is what would survive
      // the hour, and what `push_rules.dart` would push down to the homeserver.
      expect(override.muted, isFalse);
      expect(dismissed, ['merged:contact_1']);
    });

    test('the mute it writes is the expiry rules_test already pins', () async {
      await withClock(Clock.fixed(_now), () async {
        await handler.handle(
          _activation(WeftNotificationActions.muteForAnHour),
        );
      });

      // Half an hour later: silent, and for the reason the user could go and
      // change.
      final during = _decide(policy, _now.add(const Duration(minutes: 30)));
      expect(during, isA<SuppressedDecision>());
      expect(
        (during as SuppressedDecision).reason,
        NotificationSuppression.chatMuted,
      );

      // An hour and a minute later: audible again, with nothing having run a
      // timer. The expiry is read off the clock at evaluation time.
      expect(
        _decide(policy, _now.add(const Duration(minutes: 61))),
        isA<NotifyDecision>(),
      );
    });

    test(
      'a mute the policy refuses is a failure, not a silent no-op',
      () async {
        final failing = NotificationActionHandler(
          repository: repository,
          muteChat: (chatId, {DateTime? until}) =>
              throw StateError('no settings store'),
          dismiss: (chatId) async => dismissed.add(chatId),
        );

        expect(
          await failing.handle(
            _activation(WeftNotificationActions.muteForAnHour),
          ),
          NotificationActionResult.failed,
        );
        expect(dismissed, isEmpty);
      },
    );

    test('a tap is not an action, and is left to the link handler', () async {
      final result = await handler.handle(_activation(null));

      expect(result, NotificationActionResult.ignored);
      expect(repository.sent, isEmpty);
      expect(repository.markedRead, isEmpty);
      expect(dismissed, isEmpty);
    });

    test('an action id from a newer build is ignored', () async {
      // An iOS category registered by a later version survives on
      // notifications this build posted; guessing at its meaning would be
      // worse than doing nothing.
      final result = await handler.handle(_activation('weft.snooze'));

      expect(result, NotificationActionResult.ignored);
      expect(repository.sent, isEmpty);
    });

    test('an action on a bare-link notification still finds its chat', () async {
      // What the iOS notification service extension posts: it renders from the
      // push payload and cannot build a `NotificationPayload`, so its
      // notifications carry a plain `weft://chat/<id>`.
      final result = await handler.handle(
        NotificationActivation(
          payload: NotificationPayload.decode(
            notificationLinkFor('merged:contact_1'),
          )!,
          actionId: WeftNotificationActions.reply,
          input: 'on my way',
        ),
      );

      expect(result, NotificationActionResult.replied);
      expect(repository.sent.single.chatId, 'merged:contact_1');
    });

    test('a payload naming no chat does nothing at all', () async {
      final result = await handler.handle(
        NotificationActivation(
          payload: NotificationPayload.decode('weft://search?q=cats')!,
          actionId: WeftNotificationActions.markRead,
        ),
      );

      expect(result, NotificationActionResult.ignored);
      expect(repository.markedRead, isEmpty);
    });

    test('notificationChatId prefers the payload over the link', () {
      // They agree in practice. When they cannot — a link rewritten by an older
      // build — the id the notification was rendered from is the one every
      // other part of the payload belongs to.
      expect(
        notificationChatId(
          const NotificationPayload(
            link: 'weft://chat/!wa%3Aexample.org',
            chatId: 'merged:contact_1',
            roomId: '!wa:example.org',
            eventId: r'$e',
            network: ChatNetwork.whatsapp,
          ),
        ),
        'merged:contact_1',
      );
    });
  });

  group('actions end to end', () {
    test('a reply typed in the shade sends and clears the thread', () async {
      // The whole chain in one test: a decided notification is posted, the
      // platform hands back an activation for the reply button, and the
      // repository sees a send — through exactly the wiring `main.dart` builds.
      final sink = RecordingNotificationSink();
      final session = FakeNotificationSession();
      addTearDown(session.close);
      final repository = _ActionRepository();

      final pipeline = MatrixNotificationPipeline(
        session: session,
        chatForRoom: _chatForRoom,
        policy: NotificationPolicy.new,
        now: () => _now,
      );
      final service = WeftNotificationService(
        sink: sink,
        pipeline: pipeline,
        chatForRoom: _chatForRoom,
      );
      addTearDown(pipeline.dispose);
      addTearDown(service.dispose);

      final handler = NotificationActionHandler(
        repository: repository,
        muteChat: (chatId, {DateTime? until}) {},
        dismiss: service.dismissChat,
      );
      service.onAction = (activation) => unawaited(handler.handle(activation));

      await service.start();
      await pipeline.handleMessage(_message(eventId: r'$e1'));
      await pumpEventQueue();
      expect(sink.shown, hasLength(1), reason: 'a notification to act on');

      sink.activate(
        sink.shown.first,
        actionId: WeftNotificationActions.reply,
        input: 'five minutes',
      );
      await pumpEventQueue();

      expect(repository.sent.single.chatId, 'merged:contact_1');
      expect(repository.sent.single.body, 'five minutes');
      expect(repository.markedRead, ['merged:contact_1']);
      // Cleared here as well as on the user's other devices: the read receipt
      // does the second half, `dismissChat` the first.
      expect(service.postedFor('merged:contact_1'), isEmpty);
      expect(
        sink.cancelled.map((c) => c.id),
        contains(stableNotificationId(r'$e1')),
      );
    });

    test('a row this isolate never posted is still cleared', () async {
      // What a notification tap almost always looks like: the poke arrived
      // while Sennit was not running, the background isolate posted the row and
      // exited with its ledger, and the isolate now asked to dismiss has no
      // record of it. The ids are stable so it can be cancelled regardless —
      // and it has to be, or the row the user just tapped stays in the shade.
      final sink = RecordingNotificationSink();
      final session = FakeNotificationSession();
      addTearDown(session.close);

      final pipeline = MatrixNotificationPipeline(
        session: session,
        chatForRoom: _chatForRoom,
        policy: NotificationPolicy.new,
        now: () => _now,
      );
      final service = WeftNotificationService(
        sink: sink,
        pipeline: pipeline,
        chatForRoom: _chatForRoom,
      );
      addTearDown(pipeline.dispose);
      addTearDown(service.dispose);
      await service.start();

      expect(service.postedFor('merged:contact_1'), isEmpty);
      await service.dismissChat('merged:contact_1');

      expect(
        sink.cancelled.map((c) => c.id),
        containsAll([
          stableNotificationId('merged:contact_1'),
          stableNotificationId('summary:merged:contact_1'),
        ]),
      );
    });
  });

  // ------------------------------------------------------- the plugin itself

  /// [LocalNotificationSink] against a fake platform plugin.
  ///
  /// Everything above this point stops at [NotificationSink], which is the
  /// seam — and so leaves the one implementation that actually talks to
  /// `flutter_local_notifications` untested. Here the *real* Dart half of the
  /// plugin runs and only the native half is faked, which buys two things a
  /// fake sink cannot: the method call a device would genuinely receive, and
  /// the fact that every `NotificationDetails` Weft builds survives the
  /// standard codec. A `Color`, a `Person` or a `FilePathAndroidBitmap` that
  /// would not encode is a crash on a phone and silence in a pure-Dart test.
  group('LocalNotificationSink', () {
    late _FakePlatformPlugin plugin;
    late _FakeIntentsHost intents;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      plugin = _FakePlatformPlugin();
      intents = _FakeIntentsHost();
    });

    tearDown(() {
      plugin.dispose();
      intents.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    test('creates the group before the channels that name it', () async {
      await LocalNotificationSink().initialize((_) {});

      final methods = plugin.calls.map((c) => c.method).toList();
      expect(methods.first, 'initialize');
      // Android drops a channel whose group does not exist yet, and the
      // consequence is seventeen loose entries in the system settings screen
      // rather than one "Messages" heading — visible only on a device.
      expect(
        methods.indexOf('createNotificationChannelGroup'),
        lessThan(methods.indexOf('createNotificationChannel')),
      );

      final created = plugin.calls
          .where((c) => c.method == 'createNotificationChannel')
          .map((c) => (c.arguments as Map)['id'])
          .toList();
      expect(created, hasLength(weftNotificationChannels().length));
      expect(
        created,
        containsAll([
          messageChannelFor(ChatNetwork.whatsapp).id,
          kCallsChannelId,
          kBackgroundChannelId,
        ]),
      );
    });

    test('a posted notification crosses the channel whole', () async {
      final sink = LocalNotificationSink();
      await sink.initialize((_) {});
      final presentation = NotificationPresentation.forMessage(
        content: _content(),
        conversation: [
          _content(eventId: r'$0', body: 'earlier'),
          _content(),
        ],
        avatarPaths: {r'$event_1': '/tmp/grace.png'},
      );

      await sink.show(presentation);

      final call = plugin.calls.lastWhere((c) => c.method == 'show');
      final args = call.arguments as Map;
      expect(args['id'], stableNotificationId(presentation.groupKey));
      expect(args['title'], 'Grace');
      expect(args['body'], 'hello');
      // The payload is a string by the time it is an intent extra, and it is
      // the whole of what a tap after a cold start has to work from.
      expect(
        NotificationPayload.decode(args['payload'] as String),
        presentation.payload,
      );

      final specifics = args['platformSpecifics']! as Map;
      expect(
        specifics['channelId'],
        messageChannelFor(ChatNetwork.whatsapp).id,
      );
      expect(specifics['groupKey'], 'merged:contact_1');
      expect(specifics['tag'], 'merged:contact_1');
      expect(specifics['shortcutId'], chatShortcutId('merged:contact_1'));
      expect(specifics['style'], AndroidNotificationStyle.messaging.index);
      expect(
        (specifics['actions']! as List).map((a) => (a as Map)['id']),
        weftAndroidMessageActions().map((a) => a.id),
      );
    });

    test('a cancel carries the tag it was posted with', () async {
      final sink = LocalNotificationSink();
      await sink.initialize((_) {});

      await sink.cancel(id: 42, tag: 'merged:contact_1');

      final args =
          plugin.calls.lastWhere((c) => c.method == 'cancel').arguments as Map;
      // Android matches a cancel on (id, tag). Drop the tag and the call
      // silently does nothing, which is a notification that will not go away.
      expect(args['id'], 42);
      expect(args['tag'], 'merged:contact_1');
    });

    test('a tap the platform reports reaches the callback', () async {
      NotificationActivation? seen;
      final sink = LocalNotificationSink();
      await sink.initialize((activation) => seen = activation);

      await _fireNotificationResponse(
        payload: NotificationPayload.forContent(_content()).encode(),
        actionId: WeftNotificationActions.reply,
        input: 'on my way',
      );

      expect(seen!.actionId, WeftNotificationActions.reply);
      expect(seen!.input, 'on my way');
      expect(seen!.payload.chatId, 'merged:contact_1');
    });

    test('a response carrying nothing usable is dropped, not thrown', () async {
      var fired = 0;
      final sink = LocalNotificationSink();
      await sink.initialize((_) => fired++);

      await _fireNotificationResponse(payload: null);
      await _fireNotificationResponse(payload: '{not json');

      expect(fired, isZero);
    });

    test('a cold start is replayed from the launch details', () async {
      plugin.launchDetails = {
        'notificationLaunchedApp': true,
        'notificationResponse': {
          'notificationId': stableNotificationId(r'$event_1'),
          'notificationResponseType': 0,
          'payload': NotificationPayload.forContent(_content()).encode(),
          'data': <String, Object?>{},
        },
      };

      final activation = await LocalNotificationSink().launchActivation();

      expect(activation!.isTap, isTrue);
      expect(activation.payload.link, 'weft://chat/merged%3Acontact_1');
    });

    test('a launch that was not a notification is null', () async {
      plugin.launchDetails = {'notificationLaunchedApp': false};
      expect(await LocalNotificationSink().launchActivation(), isNull);

      plugin.launchDetails = null;
      expect(await LocalNotificationSink().launchActivation(), isNull);
    });

    test(
      'a conversation shortcut goes to the channel WeftIntents owns',
      () async {
        await LocalNotificationSink().publishConversationShortcut(
          id: chatShortcutId('merged:contact_1'),
          chatId: 'merged:contact_1',
          label: 'Grace',
          link: notificationLinkFor('merged:contact_1'),
          iconPath: '/tmp/grace.png',
        );

        final call = intents.calls.single;
        expect(call.method, 'publishChatShortcut');
        final args = call.arguments! as Map;
        expect(args['id'], 'chat_merged_contact_1');
        // Both, because the id is sanitised and cannot be inverted: a Direct
        // Share tap hands back only the id, and the platform needs the chat it
        // was published for to pre-select anything.
        expect(args['chatId'], 'merged:contact_1');
        expect(args['label'], 'Grace');
        // A plain `weft://chat/<id>` VIEW, so a long-press in the launcher goes
        // through the *existing* intent replay rather than a second front door.
        expect(
          (WeftLink.parse(args['link'] as String)! as OpenChatLink).chatId,
          'merged:contact_1',
        );
      },
    );

    test('a launcher that refuses costs a bubble, not a notification', () async {
      intents.answer = (call) => throw PlatformException(code: 'refused');
      await LocalNotificationSink().publishConversationShortcut(
        id: 'chat_x',
        chatId: 'x',
        label: 'x',
        link: 'weft://chat/x',
      );

      intents.answer = (call) => throw MissingPluginException();
      await LocalNotificationSink().publishConversationShortcut(
        id: 'chat_x',
        chatId: 'x',
        label: 'x',
        link: 'weft://chat/x',
      );
      // Both swallowed: the platform without the handler is every desktop, and
      // the refusal is a launcher at its shortcut limit.
    });

    test('a platform with no shortcuts is never asked', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      await LocalNotificationSink().publishConversationShortcut(
        id: 'chat_x',
        chatId: 'x',
        label: 'x',
        link: 'weft://chat/x',
      );

      expect(intents.calls, isEmpty);
    });

    test(
      'permission is asked for where it is asked for, and not where it is not',
      () async {
        plugin.permission = true;
        expect(await LocalNotificationSink().requestPermission(), isTrue);
        expect(
          plugin.calls.map((c) => c.method),
          contains('requestNotificationsPermission'),
        );

        // Linux and Windows never prompt. Answering false there would leave the
        // caller believing notifications are blocked on a platform that has no
        // way to block them.
        plugin.calls.clear();
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        expect(await LocalNotificationSink().requestPermission(), isTrue);
        expect(plugin.calls, isEmpty);
      },
    );

    test('a refused prompt is reported as refused', () async {
      plugin.permission = false;
      expect(await LocalNotificationSink().requestPermission(), isFalse);
    });
  });

  // ------------------------------------------------------------------ avatars

  group('MatrixNotificationAvatars', () {
    late Directory cache;
    late List<Uri> fetched;

    setUp(() {
      cache = Directory.systemTemp.createTempSync('weft-avatar-test');
      fetched = [];
    });

    tearDown(() => cache.deleteSync(recursive: true));

    MatrixNotificationAvatars avatars({
      Map<String, String>? headers,
      Future<http.Response> Function(http.Request)? respond,
    }) => MatrixNotificationAvatars(
      cacheDirectory: cache,
      headers: headers,
      client: MockClient((request) async {
        fetched.add(request.url);
        return respond?.call(request) ?? http.Response.bytes([1, 2, 3], 200);
      }),
    );

    test('downloads once and answers from memory after that', () async {
      final loader = avatars();
      const url = 'https://example.org/_matrix/media/v3/thumbnail/x';

      final first = await loader.load(url);
      final second = await loader.load(url);

      expect(first, isNotNull);
      expect(File(first!).readAsBytesSync(), [1, 2, 3]);
      expect(second, first);
      // A bridge backfill posts twenty notifications from one sender; twenty
      // fetches of the same face is twenty sockets on a phone that was woken.
      expect(fetched, hasLength(1));
    });

    test('a file already on disk survives the next launch', () async {
      const url = 'https://example.org/thumb/grace';
      final path = await avatars().load(url);
      fetched.clear();

      // A second process, same cache directory.
      expect(await avatars().load(url), path);
      expect(fetched, isEmpty);
    });

    test('sends the headers the inbox fetches avatars with', () async {
      String? authorization;
      await avatars(
        headers: const {'Authorization': 'Bearer token'},
        respond: (request) async {
          authorization = request.headers['Authorization'];
          return http.Response.bytes([1], 200);
        },
      ).load('https://example.org/thumb/grace');

      // Matrix v1.11 put media behind a bearer token, so without these every
      // face is a 401 — which looks exactly like having no avatar at all.
      expect(authorization, 'Bearer token');
    });

    test('an unresolved mxc URI is not fetched', () async {
      expect(await avatars().load('mxc://example.org/abc'), isNull);
      expect(await avatars().load(''), isNull);
      expect(await avatars().load('not a url'), isNull);
      expect(fetched, isEmpty);
    });

    test(
      'a failure costs the notification its face, not its existence',
      () async {
        for (final failure in <Future<http.Response> Function(http.Request)>[
          (_) async => http.Response('nope', 401),
          (_) async => http.Response.bytes(const [], 200),
          (_) async => throw const SocketException('no route to host'),
        ]) {
          final loader = avatars(respond: failure);
          expect(await loader.load('https://example.org/thumb/x'), isNull);
          // And the answer is remembered, so a dead endpoint is not retried once
          // per message for the rest of the session.
          fetched.clear();
          expect(await loader.load('https://example.org/thumb/x'), isNull);
          expect(fetched, isEmpty);
        }
      },
    );
  });
}

// --------------------------------------------------------------------- helpers

/// The merged chat every fixture here belongs to: one contact, two legs.
///
/// [Chat.avatarUrl] is already the resolved HTTP thumbnail — that is what the
/// repository stores — which is what `MatrixNotificationAvatars` expects and
/// what makes the avatar path reachable from a delivered message.
final Chat _mergedChat = Chat(
  id: 'merged:contact_1',
  title: 'Grace',
  contactId: 'contact_1',
  avatarUrl: 'https://example.org/thumb/grace',
  sources: const [
    ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
    ChatSource(roomId: '!sg:example.org', network: ChatNetwork.signal),
  ],
);

Chat? _chatForRoom(String roomId) =>
    _mergedChat.roomIds.contains(roomId) ? _mergedChat : null;

WeftMessage _message({
  String eventId = r'$event_1',
  String roomId = '!wa:example.org',
  ChatNetwork network = ChatNetwork.whatsapp,
  String body = 'hello',
  bool isOwn = false,
  DateTime? timestamp,
}) {
  return WeftMessage(
    eventId: eventId,
    roomId: roomId,
    network: network,
    senderId: '@whatsapp_grace:example.org',
    senderName: 'Grace',
    timestamp: timestamp ?? _now,
    kind: MessageKind.text,
    isOwn: isOwn,
    body: body,
  );
}

NotificationContent _content({
  String eventId = r'$event_1',
  String roomId = '!wa:example.org',
  String groupKey = 'merged:contact_1',
  ChatNetwork network = ChatNetwork.whatsapp,
  String body = 'hello',
  bool isMention = false,
}) {
  return NotificationContent(
    eventId: eventId,
    roomId: roomId,
    groupKey: groupKey,
    title: 'Grace',
    body: body,
    senderName: 'Grace (WhatsApp)',
    timestamp: _now,
    network: network,
    deepLink: notificationLinkFor(groupKey),
    isMention: isMention,
  );
}

/// One button press on the notification [_content] renders.
NotificationActivation _activation(String? actionId, {String? input}) =>
    NotificationActivation(
      payload: NotificationPayload.forContent(_content()),
      actionId: actionId,
      input: input,
    );

/// What `evaluateNotification` makes of an ordinary message under [policy].
///
/// The same call the pipeline makes, so a mute written by the handler is
/// checked against the rule that will actually read it rather than against a
/// re-statement of it.
NotificationDecision _decide(NotificationPolicy policy, DateTime now) =>
    evaluateNotification(
      message: _message(timestamp: now),
      chat: _mergedChat,
      policy: policy,
      now: now,
      lastReadAt: null,
      ownUserIds: const {'@me:example.org'},
    );

/// Records sends and read markers, and can be told to refuse either.
///
/// Everything else throws on purpose: an action handler that starts calling the
/// rest of the repository should fail loudly rather than quietly do half a
/// send.
class _ActionRepository implements ChatRepository {
  final List<({String chatId, String body, ChatNetwork? via})> sent = [];
  final List<String> markedRead = [];

  bool failSend = false;
  bool failMarkRead = false;

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) async {
    if (failSend) throw StateError('offline');
    sent.add((chatId: chatId, body: body, via: via));
  }

  @override
  Future<void> markRead(String chatId) async {
    if (failMarkRead) throw StateError('no read marker');
    markedRead.add(chatId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryPushKeyStore implements PushKeyStore {
  String? _key;

  @override
  String? readPushKey() => _key;

  @override
  void writePushKey(String? value) => _key = value;
}

class _FakePushTransport implements PushTransport {
  _FakePushTransport(this._token);

  final String? _token;

  @override
  Stream<Map<String, Object?>> get pushes => const Stream.empty();

  @override
  Future<String?> token() async => _token;

  @override
  Stream<String> get tokenRefreshes => const Stream.empty();
}

/// The native half of `flutter_local_notifications`, faked.
///
/// The Dart half is the real one — this only answers its method channel — so
/// what lands in [calls] is what a device would have been asked to do, already
/// through the standard codec in both directions.
class _FakePlatformPlugin {
  _FakePlatformPlugin() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  static const MethodChannel _channel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );

  final List<MethodCall> calls = [];

  /// What `getNotificationAppLaunchDetails` answers.
  Map<Object?, Object?>? launchDetails;

  /// What the OS says to the permission prompt.
  bool permission = true;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    return switch (call.method) {
      'initialize' => true,
      'getNotificationAppLaunchDetails' => launchDetails,
      'requestNotificationsPermission' => permission,
      _ => null,
    };
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

/// `MainActivity`'s side of the channel `WeftIntents` already owns.
class _FakeIntentsHost {
  _FakeIntentsHost() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  static const MethodChannel _channel = MethodChannel(
    'com.bostrot.weft/intents',
  );

  final List<MethodCall> calls = [];

  /// Set to make the platform refuse. Both realistic failures are exceptions.
  Object? Function(MethodCall call)? answer;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    return answer?.call(call) ?? true;
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

/// Fires the platform→Dart call the plugin makes when a notification is
/// tapped, which is the only half of a tap a fake sink cannot reproduce.
Future<void> _fireNotificationResponse({
  required String? payload,
  String? actionId,
  String? input,
}) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    .handlePlatformMessage(
      'dexterous.com/flutter/local_notifications',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('didReceiveNotificationResponse', <String, Object?>{
          'notificationId': 1,
          'actionId': actionId,
          'input': input,
          'payload': payload,
          'notificationResponseType': actionId == null ? 0 : 1,
        }),
      ),
      (_) {},
    );

/// An API session that would fail if anything actually called it — which is the
/// assertion: the outcomes tested here are reached before any HTTP happens.
class _UnusableApiSession implements MatrixApiSession {
  @override
  Uri? get baseUrl => null;

  @override
  String? get accessToken => null;

  @override
  Never get httpClient => throw StateError('no HTTP should be attempted');
}
