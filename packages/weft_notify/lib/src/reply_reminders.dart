import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'rules.dart';

/// The intervals the settings screen offers, shortest first.
///
/// A short list rather than a free field: "every 3 hours" is a decision a
/// person can make in a second, and "every 2 h 47 min" is not a setting anyone
/// wants. A blob holding something else — an older build's choice, a hand
/// edit — is still honoured; see [ReplyReminderSettings.fromJson].
const List<Duration> kReplyReminderIntervals = [
  Duration(minutes: 30),
  Duration(hours: 1),
  Duration(hours: 3),
  Duration(hours: 8),
  Duration(hours: 24),
];

/// The interval a fresh install starts from. Long enough that a message read
/// on the bus is not nagged about before the bus has arrived; short enough
/// that it is still the same day.
const Duration kDefaultReplyReminderInterval = Duration(hours: 3);

/// How old a message may already be when it is first seen read for reminders
/// about it to start.
///
/// Once started, reminders go on until the user answers, says "stop
/// reminding" or excludes the chat — that is the feature. This only keeps
/// switching it on from dredging up the whole inbox: a "thanks!" from last
/// spring, read long ago, does not start buzzing every three hours.
const Duration kReplyReminderMaxAge = Duration(days: 7);

/// How many reminders one chat may have queued with the OS at a time.
///
/// The rest are scheduled the next time the app runs, and the last of them
/// repeats daily until then (see [PlannedReplyReminder.repeatsDaily]), so a
/// chat is still reminded about with Sennit closed for longer than these
/// cover. Bounded because iOS keeps at most 64 pending local notifications
/// for an app — shared with every "remind me" the user set by hand — and
/// silently drops the rest.
const int kReplyRemindersPerChat = 6;

/// How many reminders may be queued with the OS across all chats. Below the
/// iOS limit of 64 with room left for the user's own reminders.
const int kReplyRemindersTotal = 40;

/// A group this small still counts as a conversation someone is waiting on,
/// when [ReplyReminderSettings.includeGroups] is on. People *besides* the user,
/// as [Chat.participantCount] counts them.
const int kReplyReminderMaxGroupPeers = 8;

/// What the user chose about reply reminders.
///
/// Off unless switched on: a feature that buzzes about conversations nobody
/// asked to be reminded of is the opposite of the one this is.
@immutable
class ReplyReminderSettings {
  ReplyReminderSettings({
    this.enabled = false,
    this.interval = kDefaultReplyReminderInterval,
    this.includeGroups = false,
    this.includeMuted = false,
    this.respectQuietHours = true,
    Set<String> excludedChats = const {},
  }) : excludedChats = Set.unmodifiable(excludedChats);

  final bool enabled;

  /// How long after reading a message the first reminder comes, and how long
  /// between each one after it.
  final Duration interval;

  /// Small groups too, not only one-to-one chats. Off by default: reading a
  /// group and saying nothing is what most people do in most groups.
  final bool includeGroups;

  /// Muted chats too. Off by default — a muted chat is one the user has
  /// already said should not interrupt them.
  final bool includeMuted;

  /// A reminder due inside the notification quiet hours waits until they end.
  final bool respectQuietHours;

  /// Chats the user switched reminders off for, keyed by [Chat.id].
  final Set<String> excludedChats;

  bool isExcluded(String chatId) => excludedChats.contains(chatId);

  /// A copy with [chatId] excluded, or included again when [excluded] is false.
  ReplyReminderSettings withChatExcluded(
    String chatId, {
    required bool excluded,
  }) {
    final next = Set<String>.of(excludedChats);
    excluded ? next.add(chatId) : next.remove(chatId);
    return copyWith(excludedChats: next);
  }

  ReplyReminderSettings copyWith({
    bool? enabled,
    Duration? interval,
    bool? includeGroups,
    bool? includeMuted,
    bool? respectQuietHours,
    Set<String>? excludedChats,
  }) {
    return ReplyReminderSettings(
      enabled: enabled ?? this.enabled,
      interval: interval ?? this.interval,
      includeGroups: includeGroups ?? this.includeGroups,
      includeMuted: includeMuted ?? this.includeMuted,
      respectQuietHours: respectQuietHours ?? this.respectQuietHours,
      excludedChats: excludedChats ?? this.excludedChats,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'intervalMinutes': interval.inMinutes,
    'includeGroups': includeGroups,
    'includeMuted': includeMuted,
    'respectQuietHours': respectQuietHours,
    // Sorted so two equal settings serialise byte-identically.
    'excludedChats': excludedChats.toList()..sort(),
  };

  /// Reads settings back, defaulting anything missing or malformed.
  ///
  /// Never throws, and degrades towards *off*: a blob this build cannot read
  /// must not start reminding someone who never asked for it. An interval
  /// shorter than a minute is treated as missing — a reminder loop that fires
  /// as fast as the OS allows is not a setting anyone made.
  static ReplyReminderSettings fromJson(Object? json) {
    if (json is! Map) return ReplyReminderSettings();
    final minutes = json['intervalMinutes'];
    final excluded = json['excludedChats'];
    return ReplyReminderSettings(
      enabled: json['enabled'] == true,
      interval: minutes is int && minutes >= 1
          ? Duration(minutes: minutes)
          : kDefaultReplyReminderInterval,
      includeGroups: json['includeGroups'] == true,
      includeMuted: json['includeMuted'] == true,
      respectQuietHours: json['respectQuietHours'] != false,
      excludedChats: excluded is List
          ? excluded.whereType<String>().toSet()
          : const {},
    );
  }

  static const SetEquality<String> _setEquality = SetEquality();

  @override
  bool operator ==(Object other) =>
      other is ReplyReminderSettings &&
      other.enabled == enabled &&
      other.interval == interval &&
      other.includeGroups == includeGroups &&
      other.includeMuted == includeMuted &&
      other.respectQuietHours == respectQuietHours &&
      _setEquality.equals(other.excludedChats, excludedChats);

  @override
  int get hashCode => Object.hash(
    enabled,
    interval,
    includeGroups,
    includeMuted,
    respectQuietHours,
    _setEquality.hash(excludedChats),
  );

  @override
  String toString() =>
      'ReplyReminderSettings(enabled: $enabled, every ${interval.inMinutes}m, '
      '${excludedChats.length} excluded)';
}

/// Why a chat gets no reply reminder. Named for the same reason
/// [NotificationSuppression] is: "why did it not remind me" has an answer.
enum ReplyReminderSkip {
  /// Reply reminders are switched off, or notifications are.
  disabled,

  /// Nothing has been said in the chat yet.
  empty,

  /// The user spoke last. Replying is exactly what ends a reminder.
  answered,

  /// The last message has not been read. That is what message notifications
  /// and the unread badge are for; the reminder starts once it is read.
  unread,

  /// The last event is not something a person said to the user: a membership
  /// change, a redaction, a bridge narrating its connection.
  notAMessage,

  /// The message was already older than [kReplyReminderMaxAge] when it was
  /// first seen read. A message that grows old while being reminded about is
  /// not stale: reminders go on until it is answered.
  stale,

  /// A conversation the user has not accepted.
  pendingRequest,

  /// Archived: put away on purpose.
  archived,

  /// A bridge's management room, or a status feed. Nobody is waiting there.
  serviceRoom,

  /// A group, while [ReplyReminderSettings.includeGroups] is off, or one
  /// larger than [kReplyReminderMaxGroupPeers] — or of unknown size — while it
  /// is on.
  group,

  /// Muted, in Matrix or in the notification policy, while
  /// [ReplyReminderSettings.includeMuted] is off.
  muted,

  /// The user switched reminders off for this chat.
  excluded,

  /// The user said "stop reminding" for this message. A new message from the
  /// other side starts over.
  dismissed,
}

/// Whether the user has read the last thing said in [chat] and not answered.
///
/// Read means unread count zero, the same fact the inbox draws. A chat whose
/// last event is not a message — a membership change, a redaction, a bridge
/// notice — is not waiting on anyone, whatever came before it.
bool isAwaitingReply(Chat chat) => _awaitingSkip(chat) == null;

ReplyReminderSkip? _awaitingSkip(Chat chat) {
  final last = chat.lastMessage;
  if (last == null) return ReplyReminderSkip.empty;
  if (last.isOwn) return ReplyReminderSkip.answered;
  if (last.kind == MessageKind.event || last.redacted || last.isBridgeNotice) {
    return ReplyReminderSkip.notAMessage;
  }
  if (chat.unreadCount > 0) return ReplyReminderSkip.unread;
  return null;
}

/// Why [chat] gets no reminder, or null when it should get one.
///
/// [serviceChatIds] are the bridge management rooms and status feeds the app
/// already knows about; this package cannot tell them from a person.
/// [policy] is consulted for its per-chat mutes, timed ones included, so a
/// chat muted for an hour from the notification shade is muted here too.
///
/// Facts about the conversation come first and the switches the user set
/// last, so a chat that is both archived and excluded reads as archived — the
/// reason that would still hold after the switch was flipped.
ReplyReminderSkip? replyReminderSkipFor(
  Chat chat, {
  required ReplyReminderSettings settings,
  required DateTime now,
  NotificationPolicy? policy,
  Set<String> serviceChatIds = const {},
  ReplyReminderEntry? entry,
}) {
  // The notification master switch says nothing is ever posted, and a
  // reminder is something posted.
  if (!settings.enabled || policy?.enabled == false) {
    return ReplyReminderSkip.disabled;
  }
  final awaiting = _awaitingSkip(chat);
  if (awaiting != null) return awaiting;
  final last = chat.lastMessage!;
  // Measured when the reminders started, not now: one that started keeps
  // going until the message is answered, however old it gets.
  final startedAt = entry != null && entry.eventId == last.eventId
      ? entry.readAt
      : now;
  if (startedAt.difference(last.timestamp) > kReplyReminderMaxAge) {
    return ReplyReminderSkip.stale;
  }
  if (chat.isPendingRequest) return ReplyReminderSkip.pendingRequest;
  if (chat.archived) return ReplyReminderSkip.archived;
  if (serviceChatIds.contains(chat.id)) return ReplyReminderSkip.serviceRoom;
  if (chat.isGroup) {
    final peers = chat.participantCount;
    if (!settings.includeGroups ||
        peers == null ||
        peers > kReplyReminderMaxGroupPeers) {
      return ReplyReminderSkip.group;
    }
  }
  if (!settings.includeMuted) {
    final mutedByPolicy = policy?.overrideFor(chat.id).isMutedAt(now) ?? false;
    if (chat.muted || mutedByPolicy) return ReplyReminderSkip.muted;
  }
  if (settings.isExcluded(chat.id)) return ReplyReminderSkip.excluded;
  if (entry != null && entry.dismissed && entry.eventId == last.eventId) {
    return ReplyReminderSkip.dismissed;
  }
  return null;
}

/// What is remembered about one chat that is waiting for a reply.
///
/// [readAt] is when this device first saw the message as read, which is when
/// the reminder clock starts. Matrix keeps no timestamp on "the unread count
/// went to zero", and the receipt's own timestamp is not available for a
/// merged chat as one number — so the observation is the honest clock. A
/// message read on another device while Sennit was closed starts counting
/// when Sennit next runs, which errs late rather than early.
@immutable
class ReplyReminderEntry {
  const ReplyReminderEntry({
    required this.eventId,
    required this.readAt,
    this.dismissed = false,
  });

  /// The message being waited on. A new message replaces the entry.
  final String eventId;
  final DateTime readAt;

  /// The user said "stop reminding" for this message.
  final bool dismissed;

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'readAt': readAt.toUtc().millisecondsSinceEpoch,
    if (dismissed) 'dismissed': true,
  };

  static ReplyReminderEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final eventId = json['eventId'];
    final readAt = json['readAt'];
    if (eventId is! String || readAt is! int) return null;
    return ReplyReminderEntry(
      eventId: eventId,
      readAt: DateTime.fromMillisecondsSinceEpoch(readAt, isUtc: true),
      dismissed: json['dismissed'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReplyReminderEntry &&
      other.eventId == eventId &&
      other.readAt == readAt &&
      other.dismissed == dismissed;

  @override
  int get hashCode => Object.hash(eventId, readAt, dismissed);

  @override
  String toString() =>
      'ReplyReminderEntry($eventId read $readAt${dismissed ? ', dismissed' : ''})';
}

/// Every chat currently waiting for a reply, keyed by [Chat.id].
///
/// Persisted beside the settings so the clock survives a restart: without it
/// every launch would restart every reminder's interval from zero.
@immutable
class ReplyReminderLedger {
  ReplyReminderLedger([Map<String, ReplyReminderEntry> entries = const {}])
    : entries = Map.unmodifiable(entries);

  static final ReplyReminderLedger empty = ReplyReminderLedger();

  final Map<String, ReplyReminderEntry> entries;

  ReplyReminderEntry? operator [](String chatId) => entries[chatId];

  /// A copy in which [chatId]'s current message is dismissed. A chat with no
  /// entry — the reminder fired from a ledger since rebuilt — gets one, keyed
  /// on [eventId] when the caller knows it.
  ReplyReminderLedger dismiss(
    String chatId, {
    required DateTime now,
    String? eventId,
  }) {
    final current = entries[chatId];
    final id = eventId ?? current?.eventId;
    if (id == null) return this;
    return ReplyReminderLedger({
      ...entries,
      chatId: ReplyReminderEntry(
        eventId: id,
        readAt: current?.eventId == id ? current!.readAt : now,
        dismissed: true,
      ),
    });
  }

  Map<String, Object?> toJson() => {
    for (final entry in entries.entries) entry.key: entry.value.toJson(),
  };

  static ReplyReminderLedger fromJson(Object? json) {
    if (json is! Map) return empty;
    return ReplyReminderLedger({
      for (final MapEntry(:key, :value) in json.entries)
        if (key is String) key: ?ReplyReminderEntry.fromJson(value),
    });
  }

  static const MapEquality<String, ReplyReminderEntry> _mapEquality =
      MapEquality();

  @override
  bool operator ==(Object other) =>
      other is ReplyReminderLedger &&
      _mapEquality.equals(other.entries, entries);

  @override
  int get hashCode => _mapEquality.hash(entries);
}

/// One reminder to hand to the OS.
@immutable
class PlannedReplyReminder {
  const PlannedReplyReminder({
    required this.chatId,
    required this.title,
    required this.at,
    this.repeatsDaily = false,
  });

  final String chatId;

  /// The chat's name, for the notification. Never the message.
  final String title;
  final DateTime at;

  /// Fires at [at] and then every day at the same time until it is taken
  /// back. The last reminder queued for each chat is one, so a chat is still
  /// reminded about while Sennit stays closed past the rest; the next run
  /// plans again and moves it.
  final bool repeatsDaily;

  /// Stable for one chat and one instant, so planning twice yields the same
  /// key and the app can diff what it has scheduled against what it should.
  String get key =>
      '$chatId@${at.toUtc().millisecondsSinceEpoch}${repeatsDaily ? '+daily' : ''}';

  @override
  bool operator ==(Object other) =>
      other is PlannedReplyReminder &&
      other.chatId == chatId &&
      other.title == title &&
      other.at == at &&
      other.repeatsDaily == repeatsDaily;

  @override
  int get hashCode => Object.hash(chatId, title, at, repeatsDaily);

  @override
  String toString() =>
      'PlannedReplyReminder($chatId at $at${repeatsDaily ? ', daily' : ''})';
}

/// What [planReplyReminders] decided: the ledger to persist and the reminders
/// that should be pending with the OS, soonest first.
@immutable
class ReplyReminderPlan {
  const ReplyReminderPlan({required this.ledger, required this.reminders});

  final ReplyReminderLedger ledger;
  final List<PlannedReplyReminder> reminders;
}

/// The next reminders for a message read at [readAt] and still unanswered.
///
/// The k-th reminder is due at `readAt + k × interval`, for k ≥ 1 — so the
/// sequence is anchored to the read and not to whenever the app happened to
/// plan it, and replanning on every sync moves nothing. Only instants after
/// [now] — and no later than [giveUpAt], when one is given — are returned, at
/// most [count] of them.
///
/// With [quietHours], a reminder due inside the window is moved to its end;
/// reminders that land on the same instant that way are merged into one.
List<DateTime> replyReminderTimes({
  required DateTime readAt,
  required Duration interval,
  required DateTime now,
  DateTime? giveUpAt,
  int count = kReplyRemindersPerChat,
  QuietHours? quietHours,
}) {
  if (interval <= Duration.zero || count <= 0) return const [];
  final out = <DateTime>[];
  // Skip straight to the first k due after now rather than walking every
  // past interval of a week-old read at 30 minutes.
  final elapsed = now.difference(readAt);
  var k = elapsed.isNegative
      ? 1
      : elapsed.inMicroseconds ~/ interval.inMicroseconds + 1;
  while (out.length < count) {
    final due = readAt.add(interval * k);
    if (giveUpAt != null && due.isAfter(giveUpAt)) break;
    k++;
    final at = quietHours == null ? due : _afterQuietHours(due, quietHours);
    if (!at.isAfter(now)) continue;
    if (out.isNotEmpty && !at.isAfter(out.last)) continue;
    out.add(at);
  }
  return out;
}

/// [at], or the end of the quiet-hours window it falls in.
DateTime _afterQuietHours(DateTime at, QuietHours quiet) {
  if (!quiet.isActiveAt(at)) return at;
  final local = at.toUtc().add(quiet.offset);
  final minute = local.hour * 60 + local.minute;
  var wait = quiet.endMinute % (24 * 60) - minute;
  if (wait <= 0) wait += 24 * 60;
  // Back to the top of the minute, so the result is exactly the window's end.
  return at
      .add(Duration(minutes: wait))
      .subtract(
        Duration(
          seconds: local.second,
          milliseconds: local.millisecond,
          microseconds: local.microsecond,
        ),
      );
}

/// Decides, for the whole inbox at once, which reply reminders should exist.
///
/// Pure: [ledger] is what was remembered last time, and the returned plan
/// carries the ledger to remember next time. The rules, in order:
///
/// * A chat awaiting a reply with no entry, or whose entry names an older
///   message, gets a fresh entry read at [now].
/// * A chat that is not awaiting a reply — the user answered, or something new
///   arrived unread — loses its entry, which is what stops its reminders.
/// * A chat that no longer exists loses its entry too.
/// * Every awaiting chat that [replyReminderSkipFor] lets through gets up to
///   [perChat] reminders from [replyReminderTimes]; across all chats the
///   soonest [total] are kept.
/// * The last reminder kept for each chat repeats daily, so reminding goes on
///   until the chat is answered even if the app does not run to plan again.
///
/// Entries are kept for excluded chats that are still awaiting a reply, so
/// re-including one does not restart its clock.
ReplyReminderPlan planReplyReminders({
  required Iterable<Chat> chats,
  required ReplyReminderSettings settings,
  required ReplyReminderLedger ledger,
  required DateTime now,
  NotificationPolicy? policy,
  Set<String> serviceChatIds = const {},
  int perChat = kReplyRemindersPerChat,
  int total = kReplyRemindersTotal,
}) {
  if (!settings.enabled) {
    return ReplyReminderPlan(
      ledger: ReplyReminderLedger.empty,
      reminders: const [],
    );
  }

  final entries = <String, ReplyReminderEntry>{};
  final reminders = <PlannedReplyReminder>[];
  final quiet = settings.respectQuietHours ? policy?.quietHours : null;

  for (final chat in chats) {
    if (!isAwaitingReply(chat)) continue;
    final last = chat.lastMessage!;
    final previous = ledger[chat.id];
    final entry = previous != null && previous.eventId == last.eventId
        ? previous
        : ReplyReminderEntry(eventId: last.eventId, readAt: now);
    entries[chat.id] = entry;

    final skip = replyReminderSkipFor(
      chat,
      settings: settings,
      now: now,
      policy: policy,
      serviceChatIds: serviceChatIds,
      entry: entry,
    );
    if (skip != null) continue;

    final times = replyReminderTimes(
      readAt: entry.readAt,
      interval: settings.interval,
      now: now,
      count: perChat,
      quietHours: quiet,
    );
    for (final at in times) {
      reminders.add(
        PlannedReplyReminder(chatId: chat.id, title: chat.title, at: at),
      );
    }
  }

  reminders.sort((a, b) {
    final byTime = a.at.compareTo(b.at);
    return byTime != 0 ? byTime : a.chatId.compareTo(b.chatId);
  });
  final kept = reminders.length > total
      ? reminders.sublist(0, total)
      : reminders;
  // After the cap, so the repeating one is the last a chat actually has
  // queued, wherever the cap cut it off.
  final lastOfChat = <String, int>{
    for (var i = 0; i < kept.length; i++) kept[i].chatId: i,
  };
  return ReplyReminderPlan(
    ledger: ReplyReminderLedger(entries),
    reminders: [
      for (final (i, r) in kept.indexed)
        lastOfChat[r.chatId] == i
            ? PlannedReplyReminder(
                chatId: r.chatId,
                title: r.title,
                at: r.at,
                repeatsDaily: true,
              )
            : r,
    ],
  );
}
