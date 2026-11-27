import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/localisation.dart';
import 'notification_actions.dart';
import 'notification_channels.dart';
import 'notification_presentation.dart';
import 'notification_service.dart' show NotificationActivation;

/// One reply reminder as the OS is handed it.
@immutable
class ReplyReminderNotice {
  const ReplyReminderNotice({
    required this.id,
    required this.title,
    required this.body,
    required this.at,
    required this.payload,
    this.repeatsDaily = false,
  });

  final int id;
  final String title;
  final String body;
  final DateTime at;
  final NotificationPayload payload;

  /// Fires again every day at the same time until it is cancelled; see
  /// [PlannedReplyReminder.repeatsDaily].
  final bool repeatsDaily;
}

/// Where reply reminders are queued. A fake of it is how the service is
/// tested without a device.
abstract interface class ReplyReminderPoster {
  Future<void> schedule(ReplyReminderNotice notice);

  /// Takes back a queued reminder, and a delivered one with the same id.
  Future<void> cancel(int id);
}

/// [ReplyReminderPoster] over `flutter_local_notifications`.
///
/// Android, iOS, macOS and Windows queue the reminder with the OS, so it
/// arrives with Sennit closed. Linux has no scheduled notifications in the
/// plugin, so there a timer posts it while Sennit is running — the service
/// requeues everything on every launch, so a timer lost with the process is
/// replaced by the next one. A daily repeat is a calendar trigger on Android,
/// iOS and macOS and a periodic timer on Linux; the Windows plugin has no
/// repeating schedule, so there it fires once.
class LocalReplyReminderPoster implements ReplyReminderPoster {
  LocalReplyReminderPoster({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final Map<int, Timer> _timers = {};
  static var _tzReady = false;

  static bool get _osSchedules =>
      !kIsWeb && defaultTargetPlatform != TargetPlatform.linux;

  @override
  Future<void> schedule(ReplyReminderNotice notice) async {
    final details = _details();
    final payload = notice.payload.encode();
    if (!_osSchedules) {
      _timers.remove(notice.id)?.cancel();
      final delay = notice.at.difference(clock.now());
      void show() => unawaited(
        _plugin.show(
          id: notice.id,
          title: notice.title,
          body: notice.body,
          notificationDetails: details,
          payload: payload,
        ),
      );
      _timers[notice.id] = Timer(delay.isNegative ? Duration.zero : delay, () {
        _timers.remove(notice.id);
        show();
        if (notice.repeatsDaily) {
          _timers[notice.id] = Timer.periodic(
            const Duration(days: 1),
            (_) => show(),
          );
        }
      });
      return;
    }

    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    // An absolute instant, as `ReminderScheduler` does: UTC needs no device
    // timezone to be right.
    await _plugin.zonedSchedule(
      id: notice.id,
      title: notice.title,
      body: notice.body,
      scheduledDate: tz.TZDateTime.from(notice.at.toUtc(), tz.UTC),
      notificationDetails: details,
      // Inexact spares the exact-alarm permission. A nudge a few minutes late
      // is still a nudge.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
      // In UTC, "the same time" is exactly a day later, whatever the clocks
      // do locally.
      matchDateTimeComponents: notice.repeatsDaily
          ? DateTimeComponents.time
          : null,
    );
  }

  @override
  Future<void> cancel(int id) async {
    _timers.remove(id)?.cancel();
    await _plugin.cancel(id: id);
  }

  static NotificationDetails _details() {
    final l10n = weftPlatformL10n();
    return NotificationDetails(
      android: AndroidNotificationDetails(
        kReplyRemindersChannelId,
        l10n.notificationChannelReplyReminders,
        channelDescription: l10n.notificationChannelReplyRemindersDescription,
        category: AndroidNotificationCategory.reminder,
        groupKey: kReplyRemindersChannelId,
        actions: weftAndroidReplyReminderActions(),
      ),
      iOS: const DarwinNotificationDetails(
        categoryIdentifier: kReplyReminderCategoryId,
        threadIdentifier: kReplyRemindersChannelId,
      ),
      macOS: const DarwinNotificationDetails(
        categoryIdentifier: kReplyReminderCategoryId,
        threadIdentifier: kReplyRemindersChannelId,
      ),
    );
  }
}

/// The words on a reply reminder, supplied by the app's catalogue.
typedef ReplyReminderWords = ({
  String Function(String chat) title,
  String hiddenTitle,
  String body,
});

/// Keeps the reminders queued with the OS in line with the inbox.
///
/// [onChats] is called on every inbox tick. Each call plans the whole inbox
/// with [planReplyReminders] and diffs the plan against what was queued last
/// time, so an ordinary tick — nothing read, nothing answered — makes no
/// platform call at all. Replying shows up as the chat's last message being
/// the user's own, which drops it from the plan and cancels its reminder,
/// a delivered one included. Until then each person has one reminder, under
/// one notification id, that repeats daily, so the reminding goes on when
/// Sennit does not run to plan again — and a new message from them moves that
/// one instead of adding another.
///
/// Everything stays on the device: the plan is built from the chat list
/// already in memory, and a reminder names the chat — or, with previews off,
/// not even that — and never what was said.
class ReplyReminderService {
  ReplyReminderService({
    required ReplyReminderPoster poster,
    required SettingsStore? store,
    required ReplyReminderSettings Function() settings,
    required NotificationPolicy Function() policy,
    required ReplyReminderWords Function() words,
    bool Function(Chat chat)? isServiceChat,
  }) : _poster = poster,
       _store = store,
       _settings = settings,
       _policy = policy,
       _words = words,
       _isServiceChat = isServiceChat ?? ((_) => false);

  final ReplyReminderPoster _poster;
  final SettingsStore? _store;
  final ReplyReminderSettings Function() _settings;
  final NotificationPolicy Function() _policy;
  final ReplyReminderWords Function() _words;

  /// A bridge's management room or a status feed — nobody waiting there.
  final bool Function(Chat chat) _isServiceChat;

  List<Chat>? _chats;

  /// What the store holds, read once. This service is the only writer, and
  /// the inbox ticks several times a second — two settings reads per tick
  /// would be most of what a quiet tick costs.
  ReplyReminderLedger? _ledger;
  List<_Queued>? _queued;

  /// False until the first pass of this process. That pass queues everything
  /// again, whatever the store says: an Android force-stop or an app update
  /// drops alarms, and a Linux timer dies with its process.
  bool _requeued = false;

  Future<void>? _running;
  bool _again = false;

  /// Plans against [chats]. An empty list is ignored: it is what the inbox
  /// emits before it has loaded, and planning against it would forget every
  /// clock.
  Future<void> onChats(List<Chat> chats) {
    if (chats.isEmpty) return Future.value();
    _chats = chats;
    return replan();
  }

  /// Plans again against the last inbox — after a settings change.
  ///
  /// Calls that arrive while a pass is running collapse into one more pass,
  /// so a burst of syncs costs two passes rather than twenty.
  Future<void> replan() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    do {
      _again = false;
      try {
        await _pass();
      } on Object catch (error) {
        debugPrint('weft: reply reminders could not be planned: $error');
      }
    } while (_again);
  }

  /// "Stop reminding" for [chatId]'s current message.
  ///
  /// Works with no inbox too — a background engine answering the action with
  /// Sennit closed has none to plan against. Then [chatId]'s queued reminder
  /// is taken back directly, and the dismissal recorded for the app to plan
  /// with when it next runs.
  Future<void> dismiss(String chatId, {String? eventId}) async {
    _saveLedger(
      _loadLedger().dismiss(
        chatId,
        now: clock.now(),
        eventId: eventId == null || eventId.isEmpty ? null : eventId,
      ),
    );
    if (_chats == null) return _cancelChat(chatId);
    await replan();
  }

  Future<void> _cancelChat(String chatId) async {
    final previous = _loadQueued();
    final kept = [
      for (final queued in previous)
        if (queued.chatId != chatId) queued,
    ];
    if (kept.length == previous.length) return;
    for (final queued in previous) {
      if (queued.chatId == chatId) await _poster.cancel(queued.id);
    }
    _queued = List.unmodifiable(kept);
    _store?.setJson(WeftSettings.notifyReplyRemindersQueued, {
      'queued': [for (final q in kept) q.toJson()],
    });
  }

  /// Cancels every queued reminder and forgets every clock. For sign-out.
  Future<void> clear() async {
    _chats = null;
    for (final queued in _loadQueued()) {
      await _poster.cancel(queued.id);
    }
    _store?.remove(WeftSettings.notifyReplyRemindersQueued);
    _store?.remove(WeftSettings.notifyReplyReminderLedger);
    _ledger = ReplyReminderLedger.empty;
    _queued = const [];
  }

  Future<void> _pass() async {
    final chats = _chats;
    if (chats == null) return;
    final now = clock.now();
    final policy = _policy();
    final previousLedger = _loadLedger();
    final plan = planReplyReminders(
      chats: chats,
      settings: _settings(),
      ledger: previousLedger,
      now: now,
      policy: policy,
      serviceChatIds: {
        for (final chat in chats)
          if (_isServiceChat(chat)) chat.id,
      },
    );
    if (plan.ledger != previousLedger) _saveLedger(plan.ledger);

    final words = _words();
    final wanted = <String, _Queued>{};
    final notices = <String, ReplyReminderNotice>{};
    for (final reminder in plan.reminders) {
      final title = policy.showPreviews
          ? words.title(reminder.title)
          : words.hiddenTitle;
      final queued = _Queued(
        // The text is part of the key, so a renamed chat or a flipped preview
        // setting requeues under the same id rather than going stale.
        key: '${reminder.key}|$title',
        // One id per chat for the repeating one: moving it later is then a
        // reschedule that replaces it, and never a cancel that would also
        // take one it already posted out of the shade.
        id: stableNotificationId(
          reminder.repeatsDaily
              ? 'reply-reminder-daily:${reminder.chatId}'
              : 'reply-reminder:${reminder.key}',
        ),
        chatId: reminder.chatId,
        at: reminder.at,
        repeatsDaily: reminder.repeatsDaily,
      );
      wanted[queued.key] = queued;
      notices[queued.key] = ReplyReminderNotice(
        id: queued.id,
        title: title,
        body: words.body,
        at: reminder.at,
        payload: NotificationPayload(
          link: chatDeepLink(reminder.chatId),
          chatId: reminder.chatId,
          roomId: '',
          eventId: plan.ledger[reminder.chatId]?.eventId ?? '',
          network: ChatNetwork.unknown,
        ),
        repeatsDaily: reminder.repeatsDaily,
      );
    }

    final previous = _loadQueued();
    final kept = <_Queued>[];
    final cancel = <int>{};
    // Anything no longer planned is taken back, delivered or not. A person
    // still waiting keeps their one notification: it is planned again under
    // the same id, so it is moved rather than cancelled, and the copy in the
    // shade is replaced when the next one fires instead of joined by it.
    for (final queued in previous) {
      if (wanted.containsKey(queued.key)) {
        if (_requeued) kept.add(queued);
        continue;
      }
      cancel.add(queued.id);
    }

    final keptKeys = {for (final q in kept) q.key};
    final toQueue = [
      for (final entry in wanted.entries)
        if (!keptKeys.contains(entry.key)) entry,
    ];
    // An id about to be queued again is not cancelled: the new schedule
    // replaces it, and a cancel landing after it would take the new one too.
    final requeuedIds = {for (final e in toQueue) e.value.id};
    for (final id in cancel.difference(requeuedIds)) {
      await _poster.cancel(id);
    }
    for (final entry in toQueue) {
      await _poster.schedule(notices[entry.key]!);
      kept.add(entry.value);
    }
    _requeued = true;

    final changed =
        toQueue.isNotEmpty ||
        cancel.isNotEmpty ||
        kept.length != previous.length;
    if (changed) {
      _queued = List.unmodifiable(kept);
      _store?.setJson(WeftSettings.notifyReplyRemindersQueued, {
        'queued': [for (final q in kept) q.toJson()],
      });
    }
  }

  ReplyReminderLedger _loadLedger() => _ledger ??= ReplyReminderLedger.fromJson(
    _store?.getJson(WeftSettings.notifyReplyReminderLedger),
  );

  void _saveLedger(ReplyReminderLedger ledger) {
    _ledger = ledger;
    _store?.setJson(WeftSettings.notifyReplyReminderLedger, ledger.toJson());
  }

  List<_Queued> _loadQueued() {
    if (_queued case final queued?) return queued;
    final list = _store?.getJson(
      WeftSettings.notifyReplyRemindersQueued,
    )?['queued'];
    return _queued = list is List
        ? [for (final raw in list) ?_Queued.fromJson(raw)]
        : const [];
  }
}

/// A reminder this service has handed to the OS.
@immutable
class _Queued {
  const _Queued({
    required this.key,
    required this.id,
    required this.chatId,
    required this.at,
    this.repeatsDaily = false,
  });

  final String key;
  final int id;
  final String chatId;
  final DateTime at;
  final bool repeatsDaily;

  Map<String, Object?> toJson() => {
    'key': key,
    'id': id,
    'chatId': chatId,
    'at': at.toUtc().millisecondsSinceEpoch,
    if (repeatsDaily) 'repeatsDaily': true,
  };

  static _Queued? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final id = raw['id'];
    final chatId = raw['chatId'];
    final at = raw['at'];
    if (key is! String || id is! int || chatId is! String || at is! int) {
      return null;
    }
    return _Queued(
      key: key,
      id: id,
      chatId: chatId,
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      repeatsDaily: raw['repeatsDaily'] == true,
    );
  }
}

/// "Stop reminding" pressed with no UI to hand it to.
///
/// What `runBackgroundNotificationAction` does for that one action: it needs
/// only the settings store, where the ledger and the queue are kept, so it
/// opens nothing else — no session, no repository — and is quick enough to
/// skip through a shade of reminders without Sennit coming up for any of
/// them.
Future<NotificationActionResult> stopReplyReminderHeadless(
  NotificationActivation activation, {
  required Future<SettingsStore> Function() store,
  ReplyReminderPoster? poster,
}) async {
  final chatId = notificationChatId(activation.payload);
  if (chatId.isEmpty) return NotificationActionResult.ignored;
  try {
    final settings = await store();
    // Only [ReplyReminderService.dismiss] runs, and it neither plans nor
    // words a notification: the settings, policy and words are never read.
    final service = ReplyReminderService(
      poster: poster ?? LocalReplyReminderPoster(),
      store: settings,
      settings: () => ReplyReminderSettings.fromJson(
        settings.getJson(WeftSettings.notifyReplyReminders),
      ),
      policy: () => NotificationPolicy.fromJson(
        settings.getJson(WeftSettings.notifyPolicy),
      ),
      words: () => (title: (chat) => chat, hiddenTitle: '', body: ''),
    );
    await service.dismiss(chatId, eventId: activation.payload.eventId);
  } on Object catch (error) {
    debugPrint('weft: reply reminders for $chatId could not stop: $error');
    return NotificationActionResult.failed;
  }
  return NotificationActionResult.remindersStopped;
}
