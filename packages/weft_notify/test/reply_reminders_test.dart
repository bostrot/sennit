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

    test('a message older than the cut-off is stale', () {
      expect(
        skipFor(waiting(age: kReplyReminderMaxAge + const Duration(hours: 1))),
        ReplyReminderSkip.stale,
      );
    });
  });

  group('exclusions', () {
    test('off means off', () {
      expect(
        skipFor(waiting(), settings: ReplyReminderSettings()),
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

    test('stops at the give-up instant', () {
      final times = replyReminderTimes(
        readAt: readAt,
        interval: const Duration(hours: 1),
        now: now,
        giveUpAt: readAt.add(const Duration(hours: 2)),
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
      int total = kReplyRemindersTotal,
    }) => planReplyReminders(
      chats: chats,
      settings: settings ?? on,
      ledger: ledger ?? ReplyReminderLedger.empty,
      now: at ?? now,
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
        ),
      );
      expect(result.reminders, hasLength(kReplyRemindersPerChat));
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
        total: 3,
      );
      expect(result.reminders, hasLength(3));
      // A was read an hour earlier, so its reminders come first.
      expect(result.reminders.map((r) => r.chatId), ['!a:x', '!b:x', '!a:x']);
      final sorted = [...result.reminders]
        ..sort((a, b) => a.at.compareTo(b.at));
      expect(result.reminders, sorted);
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
