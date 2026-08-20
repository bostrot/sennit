import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:weft_domain/weft_domain.dart';

import '../../app/providers.dart';
import '../../app/stores.dart';

/// One message waiting for its send time.
class ScheduledMessage {
  const ScheduledMessage({
    required this.id,
    required this.chatId,
    required this.chatTitle,
    required this.body,
    required this.dueAtMs,
    this.networkId,
  });

  final String id;
  final String chatId;

  /// For the outbox list and the confirmation — the chat may have been
  /// renamed or merged by the time it sends.
  final String chatTitle;

  final String body;
  final int dueAtMs;
  final String? networkId;

  DateTime get dueAt => DateTime.fromMillisecondsSinceEpoch(dueAtMs);

  Map<String, Object?> toJson() => {
    'id': id,
    'chatId': chatId,
    'chatTitle': chatTitle,
    'body': body,
    'dueAtMs': dueAtMs,
    'network': ?networkId,
  };

  static ScheduledMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final chatId = raw['chatId'];
    final body = raw['body'];
    final dueAtMs = raw['dueAtMs'];
    if (id is! String || chatId is! String || body is! String) return null;
    if (dueAtMs is! int) return null;
    return ScheduledMessage(
      id: id,
      chatId: chatId,
      chatTitle: raw['chatTitle'] is String ? raw['chatTitle'] as String : '',
      body: body,
      dueAtMs: dueAtMs,
      networkId: raw['network'] as String?,
    );
  }
}

/// Sends messages at the time the user chose.
///
/// Honest about its shape: the sends happen when Weft is *running* — the
/// queue is persisted, checked every half minute in the foreground and on
/// every startup, and anything that came due while the app was dead goes out
/// the moment it opens. What this is not is an OS-level background job; a
/// message that must leave at 09:00 sharp from a phone that stays off all
/// morning will leave at open.
class MessageScheduler extends Notifier<List<ScheduledMessage>> {
  static const _key = 'schedule.outbox';
  Timer? _ticker;

  /// Last attempt per id, so a failing send retries on a breath, not a spin.
  final Map<String, DateTime> _attempts = {};

  /// True under `flutter test`, where a live ticker is poison: the a11y
  /// harness holds its provider container past the widget tree's disposal, so
  /// a timer started here is still pending when the framework's end-of-test
  /// invariant runs — and every test pumping the inbox fails on it.
  ///
  /// Read off the binding's runtime type rather than a `FLUTTER_TEST` define,
  /// which this workspace's test compilation demonstrably does not carry.
  static bool get _underTest =>
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  @override
  List<ScheduledMessage> build() {
    if (!_underTest) {
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
      // Startup flush: whatever came due while the app was closed.
      final kick = Timer(const Duration(seconds: 3), _tick);
      ref.onDispose(() {
        _ticker?.cancel();
        kick.cancel();
      });
    }

    final json = storesOrNull(ref)?.settings.getJson(_key);
    final list = json?['pending'];
    if (list is! List) return const [];
    return [for (final entry in list) ?ScheduledMessage.fromJson(entry)];
  }

  void schedule(ScheduledMessage message) {
    state = [...state, message];
    _persist();
  }

  void cancel(String id) {
    state = [
      for (final m in state)
        if (m.id != id) m,
    ];
    _persist();
  }

  Future<void> _tick() async {
    final now = DateTime.now();
    final due = [
      for (final m in state)
        if (!m.dueAt.isAfter(now) &&
            (_attempts[m.id] == null ||
                now.difference(_attempts[m.id]!) > const Duration(seconds: 60)))
          m,
    ];
    if (due.isEmpty) return;

    final repository = ref.read(chatRepositoryProvider);
    for (final message in due) {
      _attempts[message.id] = now;
      try {
        await repository.send(
          message.chatId,
          message.body,
          via: message.networkId == null
              ? null
              : ChatNetwork.fromId(message.networkId!),
        );
        cancel(message.id);
      } on Object catch (error) {
        // Stays queued; the next tick retries. A send that keeps failing keeps
        // its place rather than silently vanishing.
        debugPrint('weft: scheduled send ${message.id} failed: $error');
      }
    }
  }

  void _persist() {
    storesOrNull(ref)?.settings.setJson(_key, {
      'pending': [for (final m in state) m.toJson()],
    });
  }
}

final messageSchedulerProvider =
    NotifierProvider<MessageScheduler, List<ScheduledMessage>>(
      MessageScheduler.new,
    );

/// Posts "you wanted to come back to this" notifications.
///
/// Scheduled through the OS, so a reminder fires with the app closed. The
/// instant is computed in UTC — an absolute moment needs no timezone database
/// to be right, and Weft has not initialised one with the device's zone.
class ReminderScheduler {
  ReminderScheduler({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  static var _tzReady = false;

  Future<void> remind({
    required String chatId,
    required String title,
    required String body,
    required DateTime at,
  }) async {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }

    final delay = at.difference(DateTime.now());
    final when = tz.TZDateTime.now(tz.UTC).add(delay);

    await _plugin.zonedSchedule(
      // Stable per chat+time so re-scheduling the same reminder replaces it.
      id: Object.hash(chatId, at.millisecondsSinceEpoch) & 0x7fffffff,
      title: title,
      body: body,
      scheduledDate: when,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'weft.reminders',
          'Reminders',
          channelDescription: 'Messages you asked to be reminded about',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      ),
      // Inexact spares the exact-alarm permission; a reminder a minute late
      // is still a reminder.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      // A bare link payload — NotificationPayload.decode reads it as
      // link-only and the tap opens the conversation.
      payload: 'weft://chat/${Uri.encodeComponent(chatId)}',
    );
  }
}

final reminderSchedulerProvider = Provider<ReminderScheduler>(
  (ref) => ReminderScheduler(),
);
