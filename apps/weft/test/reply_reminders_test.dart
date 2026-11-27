import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/reply_reminder_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/reply_reminders_screen.dart';
import 'package:weft/services/notifications/notification_actions.dart';
import 'package:weft/services/notifications/notification_channels.dart';
import 'package:weft/services/notifications/notification_presentation.dart';
import 'package:weft/services/notifications/notification_service.dart';
import 'package:weft/services/notifications/reply_reminders.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

/// The rules themselves are pinned in `weft_notify`. What is pinned here is
/// the part that touches a device: what is handed to the OS, what is taken
/// back, and what the settings screen writes.
void main() {
  final now = DateTime.utc(2026, 11, 19, 12);

  Chat dm({
    String id = '!grace:example.org',
    String title = 'Grace',
    bool isOwn = false,
    String eventId = r'$1',
    String? contactId,
    Duration age = const Duration(minutes: 5),
  }) => Chat(
    id: id,
    title: title,
    contactId: contactId,
    sources: [ChatSource(roomId: id, network: ChatNetwork.signal)],
    lastMessage: WeftMessage(
      eventId: eventId,
      roomId: id,
      network: ChatNetwork.signal,
      senderId: isOwn ? '@me:example.org' : '@grace:example.org',
      senderName: isOwn ? 'Me' : 'Grace',
      timestamp: now.subtract(age),
      kind: MessageKind.text,
      isOwn: isOwn,
      body: 'are you coming?',
    ),
  );

  group('ReplyReminderService', () {
    late WeftStores stores;
    late _FakePoster poster;
    late ReplyReminderSettings settings;
    late NotificationPolicy policy;

    ReplyReminderService service() => ReplyReminderService(
      poster: poster,
      store: stores.settings,
      settings: () => settings,
      policy: () => policy,
      words: () => (
        title: (chat) => 'You haven’t replied to $chat',
        hiddenTitle: 'A chat is waiting for your reply',
        body: 'Tap to open the chat.',
      ),
    );

    setUp(() {
      stores = WeftStores.inMemory();
      poster = _FakePoster();
      settings = ReplyReminderSettings(enabled: true);
      policy = NotificationPolicy();
    });
    tearDown(() => stores.dispose());

    test('off by default queues nothing', () async {
      settings = ReplyReminderSettings();
      await withClock(Clock.fixed(now), () => service().onChats([dm()]));
      expect(poster.queued, isEmpty);
    });

    test('a read, unanswered chat is queued by name only', () async {
      await withClock(Clock.fixed(now), () => service().onChats([dm()]));

      expect(poster.queued, hasLength(kReplyRemindersPerChat));
      final first = poster.queued.values.reduce(
        (a, b) => a.at.isBefore(b.at) ? a : b,
      );
      expect(first.at, now.add(kDefaultReplyReminderInterval));
      expect(first.title, 'You haven’t replied to Grace');
      // Never the message.
      expect(first.title, isNot(contains('coming')));
      expect(first.body, isNot(contains('coming')));
      expect(first.payload.chatId, '!grace:example.org');
      expect(first.payload.link, chatDeepLink('!grace:example.org'));
      expect(first.payload.eventId, r'$1');
    });

    test('with previews off the chat is not named', () async {
      policy = NotificationPolicy(showPreviews: false);
      await withClock(Clock.fixed(now), () => service().onChats([dm()]));
      expect(poster.queued.values.map((n) => n.title).toSet(), {
        'A chat is waiting for your reply',
      });
    });

    test('an unchanged inbox makes no platform call', () async {
      final reminders = service();
      await withClock(Clock.fixed(now), () => reminders.onChats([dm()]));
      final calls = poster.calls;
      await withClock(
        Clock.fixed(now.add(const Duration(minutes: 1))),
        () => reminders.onChats([dm()]),
      );
      expect(poster.calls, calls);
    });

    test('replying takes every reminder back, delivered ones too', () async {
      final reminders = service();
      await withClock(Clock.fixed(now), () => reminders.onChats([dm()]));
      // The first one has fired by the time the user answers.
      final later = now.add(kDefaultReplyReminderInterval * 1.5);
      await withClock(Clock.fixed(later), () => reminders.onChats([dm()]));
      // Still one: the fired reminder is moved under its own id, so the one
      // in the shade is replaced by the next rather than joined by it.
      expect(poster.queued, hasLength(1));

      await withClock(
        Clock.fixed(later),
        () => reminders.onChats([dm(isOwn: true, eventId: r'$2')]),
      );
      expect(poster.queued, isEmpty);
    });

    test(
      'the last reminder repeats daily and is moved, not cancelled',
      () async {
        final reminders = service();
        await withClock(Clock.fixed(now), () => reminders.onChats([dm()]));
        final daily = poster.queued.values
            .where((n) => n.repeatsDaily)
            .toList();
        expect(daily, hasLength(1));
        final latest = poster.queued.values.reduce(
          (a, b) => a.at.isAfter(b.at) ? a : b,
        );
        expect(daily.single.id, latest.id);

        // A reminder has fired, so the window moves on and the repeating one
        // with it — under the same id, so a copy already in the shade is
        // replaced rather than taken away.
        final later = now.add(kDefaultReplyReminderInterval * 1.5);
        await withClock(Clock.fixed(later), () => reminders.onChats([dm()]));
        final moved = poster.queued.values
            .where((n) => n.repeatsDaily)
            .toList();
        expect(moved, hasLength(1));
        expect(moved.single.id, daily.single.id);
        expect(moved.single.at.isAfter(daily.single.at), isTrue);
        expect(poster.cancelled, isNot(contains(daily.single.id)));
      },
    );

    test('stop reminding cancels until something new arrives', () async {
      final reminders = service();
      await withClock(Clock.fixed(now), () => reminders.onChats([dm()]));
      await withClock(
        Clock.fixed(now),
        () => reminders.dismiss('!grace:example.org', eventId: r'$1'),
      );
      expect(poster.queued, isEmpty);

      await withClock(
        Clock.fixed(now),
        () => reminders.onChats([dm(eventId: r'$3')]),
      );
      expect(poster.queued, isNotEmpty);
    });

    test('a person in several chats is one notification', () async {
      final reminders = service();
      List<Chat> grace({String? telegram}) => [
        dm(
          id: '!wa:x',
          eventId: r'$wa',
          contactId: 'grace',
          age: const Duration(minutes: 30),
        ),
        dm(
          id: '!signal:x',
          eventId: r'$signal',
          contactId: 'grace',
          age: const Duration(minutes: 20),
        ),
        dm(
          id: '!tg:x',
          eventId: telegram ?? r'$tg',
          contactId: 'grace',
          age: telegram == null ? const Duration(minutes: 10) : Duration.zero,
        ),
      ];
      await withClock(Clock.fixed(now), () => reminders.onChats(grace()));
      expect(poster.queued, hasLength(1));
      final first = poster.queued.values.single;

      // A new message from her, read: the same notification is moved, not a
      // second one queued beside it.
      final later = now.add(const Duration(hours: 1));
      await withClock(
        Clock.fixed(later),
        () => reminders.onChats(grace(telegram: r'$tg_2')),
      );
      expect(poster.queued, hasLength(1));
      final moved = poster.queued.values.single;
      expect(moved.payload.eventId, r'$tg_2');
      expect(moved.at, later.add(kDefaultReplyReminderInterval));
      expect(moved.id, first.id);
    });

    test('stopping from the shade works with no inbox', () async {
      // The UI queued it; then Sennit was closed.
      await withClock(Clock.fixed(now), () => service().onChats([dm()]));
      expect(poster.queued, hasLength(1));

      // The background engine: a fresh process, no chats, only the store.
      final background = _FakePoster()..queued.addAll(poster.queued);
      final result = await withClock(
        Clock.fixed(now),
        () => stopReplyReminderHeadless(
          NotificationActivation(
            actionId: WeftNotificationActions.stopReplyReminder,
            payload: poster.queued.values.single.payload,
          ),
          store: () async => stores.settings,
          poster: background,
        ),
      );
      expect(result, NotificationActionResult.remindersStopped);
      expect(background.queued, isEmpty);

      // And when the app runs again, the message is still dismissed.
      poster.queued.clear();
      await withClock(Clock.fixed(now), () => service().onChats([dm()]));
      expect(poster.queued, isEmpty);
      // Until something new arrives.
      await withClock(
        Clock.fixed(now),
        () => service().onChats([dm(eventId: r'$2')]),
      );
      expect(poster.queued, hasLength(1));
    });

    test('stopping from the shade without a chat does nothing', () async {
      final result = await stopReplyReminderHeadless(
        NotificationActivation(
          actionId: WeftNotificationActions.stopReplyReminder,
          payload: const NotificationPayload(
            link: '',
            chatId: '',
            roomId: '',
            eventId: '',
            network: ChatNetwork.unknown,
          ),
        ),
        store: () async => stores.settings,
        poster: poster,
      );
      expect(result, NotificationActionResult.ignored);
    });

    test('a new process queues everything again', () async {
      await withClock(Clock.fixed(now), () => service().onChats([dm()]));
      // An Android force-stop drops alarms; a Linux timer dies with its
      // process. The store still lists them, so only a requeue brings them
      // back.
      poster.queued.clear();
      await withClock(Clock.fixed(now), () => service().onChats([dm()]));
      expect(poster.queued, hasLength(kReplyRemindersPerChat));
    });

    test('an empty inbox is not planned against', () async {
      final reminders = service();
      await withClock(Clock.fixed(now), () => reminders.onChats([dm()]));
      await withClock(Clock.fixed(now), () => reminders.onChats(const []));
      expect(poster.queued, hasLength(kReplyRemindersPerChat));
    });

    test('switching off and signing out both cancel', () async {
      final reminders = service();
      await withClock(Clock.fixed(now), () => reminders.onChats([dm()]));
      settings = ReplyReminderSettings();
      await withClock(Clock.fixed(now), reminders.replan);
      expect(poster.queued, isEmpty);

      settings = ReplyReminderSettings(enabled: true);
      await withClock(Clock.fixed(now), () => reminders.onChats([dm()]));
      await reminders.clear();
      expect(poster.queued, isEmpty);
      expect(
        stores.settings.getJson(WeftSettings.notifyReplyReminderLedger),
        isNull,
      );
    });
  });

  group('ReplyRemindersScreen', () {
    Future<WeftStores> pump(WidgetTester tester, {List<Chat>? chats}) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesProvider.overrideWithValue(stores),
            chatsProvider.overrideWith((ref) => Stream.value(chats ?? [dm()])),
            replyReminderPosterProvider.overrideWithValue(_FakePoster()),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: const ReplyRemindersScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return stores;
    }

    ReplyReminderSettings persisted(WeftStores stores) =>
        ReplyReminderSettings.fromJson(
          stores.settings.getJson(WeftSettings.notifyReplyReminders),
        );

    testWidgets('starts off, with nothing below the switch', (tester) async {
      await pump(tester);
      expect(find.text('Remind me to reply'), findsOneWidget);
      expect(find.text('How often'), findsNothing);
      expect(find.text('Small groups'), findsNothing);
    });

    testWidgets('switching on persists and shows the options', (tester) async {
      final stores = await pump(tester);
      await tester.tap(find.text('Remind me to reply'));
      await tester.pumpAndSettle();

      expect(persisted(stores).enabled, isTrue);
      expect(find.text('Every 30 minutes'), findsOneWidget);
      expect(find.text('Every 3 hours'), findsOneWidget);
      expect(find.text('Every 24 hours'), findsOneWidget);
      expect(find.text('Small groups'), findsOneWidget);
      expect(find.text('Muted chats'), findsOneWidget);
      expect(find.text('Respect quiet hours'), findsOneWidget);
    });

    testWidgets('the interval and the switches persist', (tester) async {
      final stores = await pump(tester);
      await tester.tap(find.text('Remind me to reply'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Every hour'));
      await tester.pumpAndSettle();
      expect(persisted(stores).interval, const Duration(hours: 1));

      await tester.tap(find.text('Small groups'));
      await tester.tap(find.text('Muted chats'));
      await tester.tap(find.text('Respect quiet hours'));
      await tester.pumpAndSettle();
      final saved = persisted(stores);
      expect(saved.includeGroups, isTrue);
      expect(saved.includeMuted, isTrue);
      expect(saved.respectQuietHours, isFalse);
    });

    testWidgets('a chat can be excluded and included again', (tester) async {
      final stores = await pump(tester);
      await tester.tap(find.text('Remind me to reply'));
      await tester.pumpAndSettle();
      expect(find.text('No chats excluded.'), findsOneWidget);

      await tester.tap(find.text('Exclude a chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SimpleDialogOption, 'Grace'));
      await tester.pumpAndSettle();

      expect(persisted(stores).excludedChats, {'!grace:example.org'});
      expect(find.text('Grace'), findsOneWidget);

      await tester.tap(find.byTooltip('Remind me again'));
      await tester.pumpAndSettle();
      expect(persisted(stores).excludedChats, isEmpty);
      expect(find.text('No chats excluded.'), findsOneWidget);
    });
  });
}

class _FakePoster implements ReplyReminderPoster {
  final Map<int, ReplyReminderNotice> queued = {};
  final List<int> cancelled = [];
  int calls = 0;

  @override
  Future<void> schedule(ReplyReminderNotice notice) async {
    calls++;
    queued[notice.id] = notice;
  }

  @override
  Future<void> cancel(int id) async {
    calls++;
    cancelled.add(id);
    queued.remove(id);
  }
}
