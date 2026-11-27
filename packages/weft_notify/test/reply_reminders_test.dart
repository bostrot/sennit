import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

import 'support/fixtures.dart';

/// A DM whose last message arrived an hour before [now] and has been read.
Chat waiting({
  String id = '!room:example.org',
  String title = 'Grace',
  String eventId = r'$event_1',
  Duration age = const Duration(hours: 1),
  bool isOwn = false,
  int unread = 0,
  bool isGroup = false,
  int? participantCount,
  bool archived = false,
  bool muted = false,
  ChatRequestState? request,
  MessageKind kind = MessageKind.text,
  bool isBridgeNotice = false,
  DateTime? reactedUpTo,
}) {
  return Chat(
    id: id,
    title: title,
    sources: [ChatSource(roomId: id, network: ChatNetwork.whatsapp)],
    lastMessage: msg(
      eventId: eventId,
      roomId: id,
      timestamp: now.subtract(age),
      isOwn: isOwn,
      kind: kind,
      isBridgeNotice: isBridgeNotice,
    ),
    unreadCount: unread,
    isGroup: isGroup,
    participantCount: participantCount,
    archived: archived,
    muted: muted,
    request: request,
    reactedUpTo: reactedUpTo,
  );
}

final ReplyReminderSettings on = ReplyReminderSettings(enabled: true);

ReplyReminderSkip? skipFor(
  Chat chat, {
  ReplyReminderSettings? settings,
  NotificationPolicy? policy,
  Set<String> serviceChatIds = const {},
  ReplyReminderEntry? entry,
}) => replyReminderSkipFor(
  chat,
  settings: settings ?? on,
  now: now,
  policy: policy,
  serviceChatIds: serviceChatIds,
  entry: entry,
);

void main() {
  group('awaiting a reply', () {
    test('a read incoming message is awaiting a reply', () {
      expect(isAwaitingReply(waiting()), isTrue);
      expect(skipFor(waiting()), isNull);
    });

    test('the user speaking last means it was answered', () {
      expect(skipFor(waiting(isOwn: true)), ReplyReminderSkip.answered);
    });

    test('an unread message is not awaiting yet', () {
      expect(skipFor(waiting(unread: 1)), ReplyReminderSkip.unread);
    });

    test('an empty chat is not awaiting anything', () {
      final empty = Chat(id: '!e:example.org', title: 'E', sources: const []);
      expect(skipFor(empty), ReplyReminderSkip.empty);
    });

    test('a membership event or a bridge notice is not a message', () {
      expect(
        skipFor(waiting(kind: MessageKind.event)),
        ReplyReminderSkip.notAMessage,
      );
      expect(
        skipFor(waiting(isBridgeNotice: true)),
        ReplyReminderSkip.notAMessage,
      );
    });

    test('a message already older than the cut-off when read is stale', () {
      expect(
        skipFor(waiting(age: kReplyReminderMaxAge + const Duration(hours: 1))),
        ReplyReminderSkip.stale,
      );
    });

    test('a message that grows old while being reminded about is not', () {
      final age = kReplyReminderMaxAge * 4;
      expect(
        skipFor(
          waiting(age: age),
          entry: ReplyReminderEntry(
            eventId: r'$event_1',
            readAt: now.subtract(age).add(const Duration(minutes: 5)),
          ),
        ),
        isNull,
      );
    });
  });

  group('a reaction as a reply', () {
    // The message [waiting] builds arrived an hour ago.
    final sentAt = now.subtract(const Duration(hours: 1));

    test('my reaction on the last message answers the chat', () {
      final chat = waiting(reactedUpTo: sentAt);
      expect(answeredByReaction(chat), isTrue);
      expect(isUnanswered(chat), isFalse);
      expect(isAwaitingReply(chat), isFalse);
      expect(skipFor(chat), ReplyReminderSkip.answered);
    });

    test('a reaction on a message after the one waiting answers it', () {
      final chat = waiting(reactedUpTo: sentAt.add(const Duration(minutes: 5)));
      expect(skipFor(chat), ReplyReminderSkip.answered);
    });

    test('a reaction on an older message does not', () {
      final chat = waiting(
        reactedUpTo: sentAt.subtract(const Duration(minutes: 1)),
      );
      expect(answeredByReaction(chat), isFalse);
      expect(isUnanswered(chat), isTrue);
      expect(skipFor(chat), isNull);
    });

    test('a reaction taken back leaves the chat unanswered again', () {
      // A redaction drops the reaction from the chat's reactedUpTo.
      expect(skipFor(waiting()), isNull);
      expect(isUnanswered(waiting()), isTrue);
    });

    test('with the setting off a reaction answers nothing', () {
      final off = on.copyWith(reactionsCountAsReply: false);
      final chat = waiting(reactedUpTo: sentAt);
      expect(isUnanswered(chat, reactionsCount: false), isTrue);
      expect(isAwaitingReply(chat, reactionsCount: false), isTrue);
      expect(skipFor(chat, settings: off), isNull);
    });

    test('answered by reaction even while unread', () {
      // Reacting from the notification or another device answers it; the
      // unread count is beside the point once it is answered.
      final chat = waiting(unread: 1, reactedUpTo: sentAt);
      expect(skipFor(chat), ReplyReminderSkip.answered);
    });

    test('a reaction stops the reminders and a redaction restarts them', () {
      final first = planReplyReminders(
        chats: [waiting()],
        settings: on,
        ledger: ReplyReminderLedger.empty,
        now: now,
      );
      expect(first.reminders, isNotEmpty);
      final reacted = planReplyReminders(
        chats: [waiting(reactedUpTo: sentAt)],
        settings: on,
        ledger: first.ledger,
        now: now,
      );
      expect(reacted.reminders, isEmpty);
      expect(reacted.ledger.entries, isEmpty);
      final takenBack = planReplyReminders(
        chats: [waiting()],
        settings: on,
        ledger: reacted.ledger,
        now: now,
      );
      expect(takenBack.reminders, isNotEmpty);
      final off = planReplyReminders(
        chats: [waiting(reactedUpTo: sentAt)],
        settings: on.copyWith(reactionsCountAsReply: false),
        ledger: ReplyReminderLedger.empty,
        now: now,
      );
      expect(off.reminders, isNotEmpty);
    });

    test('is on by default, also for settings saved before it existed', () {
      expect(ReplyReminderSettings().reactionsCountAsReply, isTrue);
      expect(
        ReplyReminderSettings.fromJson({'enabled': true}).reactionsCountAsReply,
        isTrue,
      );
      final off = ReplyReminderSettings(reactionsCountAsReply: false);
      expect(ReplyReminderSettings.fromJson(off.toJson()), off);
      expect(off, isNot(ReplyReminderSettings()));
    });
  });

  group('exclusions', () {
    test('off means off', () {
      expect(
        skipFor(waiting(), settings: ReplyReminderSettings()),
        ReplyReminderSkip.disabled,
      );
    });

    test('notifications switched off switch reminders off too', () {
      expect(
        skipFor(waiting(), policy: NotificationPolicy(enabled: false)),
        ReplyReminderSkip.disabled,
      );
    });

    test('pending requests, archived chats and service rooms are skipped', () {
      expect(
        skipFor(waiting(request: ChatRequestState.pending)),
        ReplyReminderSkip.pendingRequest,
      );
      expect(skipFor(waiting(archived: true)), ReplyReminderSkip.archived);
      expect(
        skipFor(waiting(), serviceChatIds: {'!room:example.org'}),
        ReplyReminderSkip.serviceRoom,
      );
    });

    test('groups are skipped unless small groups are included', () {
      final small = waiting(isGroup: true, participantCount: 3);
      expect(skipFor(small), ReplyReminderSkip.group);
      final groups = on.copyWith(includeGroups: true);
      expect(skipFor(small, settings: groups), isNull);
      expect(
        skipFor(
          waiting(
            isGroup: true,
            participantCount: kReplyReminderMaxGroupPeers + 1,
          ),
          settings: groups,
        ),
        ReplyReminderSkip.group,
      );
      // A group of unknown size could be a hundred people.
      expect(
        skipFor(waiting(isGroup: true), settings: groups),
        ReplyReminderSkip.group,
      );
    });

    test('muted chats are skipped unless included', () {
      expect(skipFor(waiting(muted: true)), ReplyReminderSkip.muted);
      expect(
        skipFor(
          waiting(muted: true),
          settings: on.copyWith(includeMuted: true),
        ),
        isNull,
      );
    });

    test('a timed mute in the notification policy counts as muted', () {
      final policy = NotificationPolicy().muteChat(
        '!room:example.org',
        until: now.add(const Duration(hours: 1)),
      );
      expect(skipFor(waiting(), policy: policy), ReplyReminderSkip.muted);
      final lapsed = NotificationPolicy().muteChat(
        '!room:example.org',
        until: now.subtract(const Duration(minutes: 1)),
      );
      expect(skipFor(waiting(), policy: lapsed), isNull);
    });

    test('a chat the user excluded is skipped', () {
      final settings = on.withChatExcluded('!room:example.org', excluded: true);
      expect(
        skipFor(waiting(), settings: settings),
        ReplyReminderSkip.excluded,
      );
      expect(
        skipFor(
          waiting(),
          settings: settings.withChatExcluded(
            '!room:example.org',
            excluded: false,
          ),
        ),
        isNull,
      );
    });

    test('a dismissal holds for that message only', () {
      final dismissed = ReplyReminderEntry(
        eventId: r'$event_1',
        readAt: now,
        dismissed: true,
      );
      expect(skipFor(waiting(), entry: dismissed), ReplyReminderSkip.dismissed);
      expect(skipFor(waiting(eventId: r'$event_2'), entry: dismissed), isNull);
    });
  });

  group('replyReminderTimes', () {
    final readAt = now.subtract(const Duration(minutes: 10));

    test('repeats every interval from the read', () {
      final times = replyReminderTimes(
        readAt: readAt,
        interval: const Duration(hours: 1),
        now: now,
        giveUpAt: now.add(const Duration(days: 7)),
        count: 3,
      );
      expect(times, [
        readAt.add(const Duration(hours: 1)),
        readAt.add(const Duration(hours: 2)),
        readAt.add(const Duration(hours: 3)),
      ]);
    });

    test('skips reminders already in the past without moving the rest', () {
      final early = now.subtract(const Duration(hours: 2, minutes: 30));
      final times = replyReminderTimes(
        readAt: early,
        interval: const Duration(hours: 1),
        now: now,
        giveUpAt: now.add(const Duration(days: 7)),
        count: 2,
      );
      expect(times, [
        early.add(const Duration(hours: 3)),
        early.add(const Duration(hours: 4)),
      ]);
    });

    test('goes on without a give-up instant', () {
      final times = replyReminderTimes(
        readAt: now.subtract(const Duration(days: 30)),
        interval: const Duration(hours: 1),
        now: now,
        count: 2,
      );
      expect(times, hasLength(2));
    });

    test('stops at the give-up instant', () {
      final times = replyReminderTimes(
        readAt: readAt,
        interval: const Duration(hours: 1),
        now: now,
        giveUpAt: readAt.add(const Duration(hours: 2)),
        count: 6,
      );
      expect(times, hasLength(2));
    });

    test('moves a reminder inside quiet hours to their end, merging', () {
      // now is 21:00 UTC; quiet 22:00 → 07:00 UTC.
      const quiet = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60);
      final times = replyReminderTimes(
        readAt: now,
        interval: const Duration(hours: 3),
        now: now,
        giveUpAt: now.add(const Duration(days: 7)),
        count: 3,
        quietHours: quiet,
      );
      final sevenAm = DateTime.utc(2026, 1, 16, 7);
      // 00:00, 03:00 and 06:00 all wait for 07:00 and become one; 09:00 and
      // 12:00 follow.
      expect(times, [
        sevenAm,
        DateTime.utc(2026, 1, 16, 9),
        DateTime.utc(2026, 1, 16, 12),
      ]);
    });
  });

  group('planReplyReminders', () {
    ReplyReminderPlan plan(
      List<Chat> chats, {
      ReplyReminderSettings? settings,
      ReplyReminderLedger? ledger,
      DateTime? at,
      int perChat = kReplyRemindersPerChat,
      int total = kReplyRemindersTotal,
    }) => planReplyReminders(
      chats: chats,
      settings: settings ?? on,
      ledger: ledger ?? ReplyReminderLedger.empty,
      now: at ?? now,
      perChat: perChat,
      total: total,
    );

    test('a newly read message starts its clock now', () {
      final result = plan([waiting()]);
      expect(result.ledger['!room:example.org']?.readAt, now);
      expect(
        result.reminders.first,
        PlannedReplyReminder(
          chatId: '!room:example.org',
          title: 'Grace',
          at: now.add(kDefaultReplyReminderInterval),
          repeatsDaily: true,
        ),
      );
      // One per person, so the next one replaces the last in the shade.
      expect(result.reminders, hasLength(1));
    });

    test('the last reminder of a chat repeats daily, the others do not', () {
      final reminders = plan([waiting()], perChat: 6).reminders;
      expect(reminders, hasLength(6));
      expect(reminders.last.repeatsDaily, isTrue);
      expect(reminders.where((r) => r.repeatsDaily), hasLength(1));
      expect(reminders.last.key, endsWith('+daily'));
    });

    test('keeps reminding until answered, however long that takes', () {
      final first = plan([waiting()]);
      final monthLater = now.add(const Duration(days: 30));
      final later = plan([waiting()], ledger: first.ledger, at: monthLater);
      expect(later.reminders, hasLength(kReplyRemindersPerChat));
      expect(later.reminders.first.at.isAfter(monthLater), isTrue);
      expect(later.ledger, first.ledger);
      expect(
        plan(
          [waiting(isOwn: true)],
          ledger: later.ledger,
          at: monthLater,
        ).reminders,
        isEmpty,
      );
    });

    test('replanning later keeps the clock and the same instants', () {
      final first = plan([waiting()]);
      final later = plan(
        [waiting()],
        ledger: first.ledger,
        at: now.add(const Duration(minutes: 5)),
      );
      expect(later.ledger, first.ledger);
      expect(later.reminders, first.reminders);
    });

    test('replying ends the reminders and forgets the entry', () {
      final first = plan([waiting()]);
      final replied = plan([waiting(isOwn: true)], ledger: first.ledger);
      expect(replied.reminders, isEmpty);
      expect(replied.ledger.entries, isEmpty);
    });

    test('a new message restarts the clock', () {
      final first = plan([waiting()]);
      final later = now.add(const Duration(hours: 1));
      final next = plan(
        [waiting(eventId: r'$event_2', age: Duration.zero)],
        ledger: first.ledger,
        at: later,
      );
      expect(next.ledger['!room:example.org']?.readAt, later);
    });

    test('dismissing stops reminders until something new arrives', () {
      final first = plan([waiting()]);
      final dismissed = first.ledger.dismiss('!room:example.org', now: now);
      expect(plan([waiting()], ledger: dismissed).reminders, isEmpty);
      expect(
        plan([waiting(eventId: r'$event_2')], ledger: dismissed).reminders,
        isNotEmpty,
      );
    });

    test('an excluded chat keeps its clock but gets nothing', () {
      final settings = on.withChatExcluded('!room:example.org', excluded: true);
      final result = plan([waiting()], settings: settings);
      expect(result.reminders, isEmpty);
      expect(result.ledger['!room:example.org'], isNotNull);
    });

    test('turning the feature off clears everything', () {
      final first = plan([waiting()]);
      final off = plan(
        [waiting()],
        settings: ReplyReminderSettings(),
        ledger: first.ledger,
      );
      expect(off.reminders, isEmpty);
      expect(off.ledger.entries, isEmpty);
    });

    test('keeps the soonest reminders across chats within the cap', () {
      final first = plan([waiting(id: '!a:x', title: 'A')]);
      final result = plan(
        [waiting(id: '!a:x', title: 'A'), waiting(id: '!b:x', title: 'B')],
        ledger: first.ledger,
        at: now.add(const Duration(hours: 1)),
        perChat: 6,
        total: 3,
      );
      expect(result.reminders, hasLength(3));
      // A was read an hour earlier, so its reminders come first.
      expect(result.reminders.map((r) => r.chatId), ['!a:x', '!b:x', '!a:x']);
      // Each chat's last reminder within the cap is the one that repeats.
      expect(result.reminders.map((r) => r.repeatsDaily), [false, true, true]);
      final sorted = [...result.reminders]
        ..sort((a, b) => a.at.compareTo(b.at));
      expect(result.reminders, sorted);
    });
  });

  group('one reminder per person', () {
    // Grace on WhatsApp, Signal and Telegram: merged into one person, but
    // each chat still its own row here — the case the merge fold misses, and
    // the shape the rule must hold for either way.
    Chat leg(
      String id, {
      required String eventId,
      required Duration age,
      bool isOwn = false,
      int unread = 0,
      DateTime? reactedUpTo,
    }) {
      final chat = waiting(
        id: id,
        eventId: eventId,
        age: age,
        isOwn: isOwn,
        unread: unread,
        reactedUpTo: reactedUpTo,
      );
      return Chat(
        id: chat.id,
        title: chat.title,
        sources: chat.sources,
        contactId: 'contact_grace',
        lastMessage: chat.lastMessage,
        unreadCount: chat.unreadCount,
        reactedUpTo: chat.reactedUpTo,
      );
    }

    List<Chat> grace({
      bool repliedOnSignal = false,
      bool newOnTelegram = false,
    }) => [
      leg('!wa:x', eventId: r'$wa', age: const Duration(hours: 3)),
      leg(
        '!signal:x',
        eventId: repliedOnSignal ? r'$mine' : r'$signal',
        age: repliedOnSignal ? Duration.zero : const Duration(hours: 2),
        isOwn: repliedOnSignal,
      ),
      leg(
        '!tg:x',
        eventId: newOnTelegram ? r'$tg_2' : r'$tg',
        age: newOnTelegram
            ? const Duration(minutes: 1)
            : const Duration(hours: 1),
      ),
    ];

    ReplyReminderPlan plan(
      List<Chat> chats, {
      ReplyReminderLedger? ledger,
      DateTime? at,
    }) => planReplyReminders(
      chats: chats,
      settings: on,
      ledger: ledger ?? ReplyReminderLedger.empty,
      now: at ?? now,
    );

    test('several merged chats with read messages give one reminder', () {
      final result = plan(grace());
      expect(result.reminders, hasLength(1));
      // About the message they sent last, wherever they sent it.
      expect(result.reminders.single.chatId, '!tg:x');
      expect(result.ledger.entries.keys, ['!tg:x']);
      expect(result.ledger['!tg:x']?.eventId, r'$tg');
    });

    test('an unread message in any of them waits for it to be read', () {
      final chats = grace();
      chats[0] = leg(
        '!wa:x',
        eventId: r'$wa',
        age: const Duration(hours: 3),
        unread: 1,
      );
      expect(plan(chats).reminders, isEmpty);
    });

    test('replying in one merged chat clears it', () {
      final first = plan(grace());
      final replied = plan(
        grace(repliedOnSignal: true),
        ledger: first.ledger,
        at: now.add(const Duration(minutes: 1)),
      );
      expect(replied.reminders, isEmpty);
      expect(replied.ledger.entries, isEmpty);
    });

    test('a reaction in one merged chat clears it too', () {
      final chats = grace();
      chats[0] = leg(
        '!wa:x',
        eventId: r'$wa',
        age: const Duration(hours: 3),
        reactedUpTo: now,
      );
      expect(plan(chats).reminders, isEmpty);
    });

    test('a new message re-arms it once', () {
      final first = plan(grace());
      final later = now.add(const Duration(hours: 1));
      final next = plan(
        grace(newOnTelegram: true),
        ledger: first.ledger,
        at: later,
      );
      expect(next.reminders, hasLength(1));
      expect(next.ledger.entries, hasLength(1));
      expect(next.ledger['!tg:x']?.eventId, r'$tg_2');
      expect(next.ledger['!tg:x']?.readAt, later);
      expect(
        next.reminders.single.at,
        later.add(kDefaultReplyReminderInterval),
      );
      // And planning again changes nothing: it is one reminder, kept.
      final again = plan(
        grace(newOnTelegram: true),
        ledger: next.ledger,
        at: later.add(const Duration(minutes: 5)),
      );
      expect(again.reminders, next.reminders);
      expect(again.ledger, next.ledger);
    });

    test('its clock holds when someone else in the chats moves first', () {
      final first = plan(grace());
      // The same three chats in another order: still Telegram's message.
      final later = plan(
        grace().reversed.toList(),
        ledger: first.ledger,
        at: now.add(const Duration(minutes: 5)),
      );
      expect(later.ledger, first.ledger);
      expect(later.reminders, first.reminders);
    });

    test('excluding one of their chats excludes the person', () {
      final result = planReplyReminders(
        chats: grace(),
        settings: on.withChatExcluded('!wa:x', excluded: true),
        ledger: ReplyReminderLedger.empty,
        now: now,
      );
      expect(result.reminders, isEmpty);
    });

    test('different people and groups are not folded together', () {
      final result = plan([
        ...grace(),
        waiting(id: '!ada:x', title: 'Ada'),
        waiting(id: '!bob:x', title: 'Bob'),
      ]);
      expect(result.reminders.map((r) => r.chatId).toSet(), {
        '!tg:x',
        '!ada:x',
        '!bob:x',
      });
    });
  });

  group('codecs', () {
    test('settings round-trip and default to off', () {
      final settings = ReplyReminderSettings(
        enabled: true,
        interval: const Duration(hours: 8),
        includeGroups: true,
        includeMuted: true,
        respectQuietHours: false,
        excludedChats: {'b', 'a'},
      );
      expect(ReplyReminderSettings.fromJson(settings.toJson()), settings);
      expect(ReplyReminderSettings.fromJson(null).enabled, isFalse);
      expect(
        ReplyReminderSettings.fromJson({'intervalMinutes': 0}).interval,
        kDefaultReplyReminderInterval,
      );
    });

    test('the ledger round-trips and drops malformed entries', () {
      final ledger = ReplyReminderLedger({
        'a': ReplyReminderEntry(eventId: r'$1', readAt: now, dismissed: true),
      });
      expect(ReplyReminderLedger.fromJson(ledger.toJson()), ledger);
      expect(
        ReplyReminderLedger.fromJson({
          'a': {'eventId': 1},
        }).entries,
        isEmpty,
      );
    });
  });
}
