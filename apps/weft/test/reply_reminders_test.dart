import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/reply_reminder_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/reply_reminders_screen.dart';
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
  }) => Chat(
    id: id,
    title: title,
    sources: [ChatSource(roomId: id, network: ChatNetwork.signal)],
    lastMessage: WeftMessage(
      eventId: eventId,
      roomId: id,
      network: ChatNetwork.signal,
      senderId: isOwn ? '@me:example.org' : '@grace:example.org',
      senderName: isOwn ? 'Me' : 'Grace',
      timestamp: now.subtract(const Duration(minutes: 5)),
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
      expect(poster.queued, hasLength(kReplyRemindersPerChat + 1));

      await withClock(
        Clock.fixed(later),
        () => reminders.onChats([dm(isOwn: true, eventId: r'$2')]),
      );
      expect(poster.queued, isEmpty);
    });

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
  int calls = 0;

  @override
  Future<void> schedule(ReplyReminderNotice notice) async {
    calls++;
    queued[notice.id] = notice;
  }

  @override
  Future<void> cancel(int id) async {
    calls++;
    queued.remove(id);
  }
}
