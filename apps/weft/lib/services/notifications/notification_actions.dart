import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../../app/intents.dart';
import '../../data/chat_repository.dart';
import 'notification_channels.dart';
import 'notification_presentation.dart';
import 'notification_service.dart';

/// Writes a timed mute for one chat.
///
/// The signature of `NotificationPolicyNotifier.muteChat`, taken as a function
/// so this layer needs neither Riverpod nor a settings database to be
/// exercised. Null [until] means indefinitely; the mute action never passes
/// null.
typedef ChatMuteWriter = void Function(String chatId, {DateTime? until});

/// Clears the notifications posted for one chat.
///
/// `WeftNotificationService.dismissChat`, again as a function. It takes a
/// [Chat.id] and not a room id, which is the point: acting on one leg of a
/// merged contact clears the conversation, because the user acted on the
/// conversation.
typedef NotificationDismisser = Future<void> Function(String chatId);

/// Stops the reply reminders for one chat's current message.
/// `ReplyReminderService.dismiss`, as a function for the same reason.
typedef ReplyReminderStopper =
    Future<void> Function(String chatId, {String? eventId});

/// What became of an action.
///
/// An enum rather than a bool because "nothing to do" and "it failed" lead
/// somewhere different: an empty reply is the user closing the input field and
/// deserves no complaint, while a send that threw has left a notification
/// standing on purpose.
enum NotificationActionResult {
  /// The reply was sent, the chat marked read, and the notification cleared.
  replied,

  /// The read marker moved and the notification cleared.
  markedRead,

  /// A timed mute was written and the notification cleared.
  muted,

  /// Reply reminders for the chat's current message were stopped.
  remindersStopped,

  /// A tap, an action id from a newer build, or an empty reply. Nothing was
  /// attempted and nothing is wrong.
  ignored,

  /// The repository refused. The notification is deliberately left up.
  failed,
}

/// The chat an action should act on.
///
/// [NotificationPayload.chatId] whenever there is one, and a parse of the deep
/// link when there is not. The fallback is not padding: a notification posted
/// by the iOS notification service extension — which renders from the push
/// payload and cannot construct a [NotificationPayload] — carries a bare
/// `weft://chat/<id>` string, and its actions have to work too. Both routes
/// end at the same id, which is what
/// [NotificationPayload.decode]'s bare-link case exists to make possible.
///
/// Empty when the payload names no chat at all, which is the caller's cue to
/// do nothing rather than to guess.
String notificationChatId(NotificationPayload payload) {
  if (payload.chatId.isNotEmpty) return payload.chatId;
  final link = WeftLink.parse(payload.link);
  return link is OpenChatLink ? link.chatId : '';
}

/// Performs what a notification action says.
///
/// The other half of [WeftNotificationService.onAction], and deliberately a
/// separate object: the service knows what is on screen, this knows what the
/// three buttons mean, and neither needs the other's state. It holds nothing —
/// every call is resolved from the payload the platform handed back — so a
/// reply typed into a notification posted by a process that has since died is
/// the same code path as one typed while the app is open.
///
/// Nothing here decides *whether* to act. If an activation arrives, the user
/// pressed a button.
class NotificationActionHandler {
  NotificationActionHandler({
    required ChatRepository repository,
    required ChatMuteWriter muteChat,
    required NotificationDismisser dismiss,
    ReplyReminderStopper? stopReplyReminder,
    Duration muteDuration = kMuteForAnHour,
  }) : _repository = repository,
       _muteChat = muteChat,
       _dismiss = dismiss,
       _stopReplyReminder = stopReplyReminder,
       _muteDuration = muteDuration;

  final ChatRepository _repository;
  final ChatMuteWriter _muteChat;
  final NotificationDismisser _dismiss;
  final ReplyReminderStopper? _stopReplyReminder;
  final Duration _muteDuration;

  /// Handles one activation, or declines to.
  ///
  /// A tap is not an action and is returned to the caller untouched —
  /// [WeftNotificationService] routes those to the link handler, and doing it
  /// in both places would open the chat twice.
  Future<NotificationActionResult> handle(
    NotificationActivation activation,
  ) async {
    if (activation.isTap) return NotificationActionResult.ignored;

    final chatId = notificationChatId(activation.payload);
    if (chatId.isEmpty) {
      debugPrint(
        'weft: notification action ${activation.actionId} names no chat',
      );
      return NotificationActionResult.ignored;
    }

    final actionId = activation.actionId ?? '';
    if (actionId.startsWith(WeftNotificationActions.aiReplyPrefix)) {
      final index = int.tryParse(
        actionId.substring(WeftNotificationActions.aiReplyPrefix.length),
      );
      final suggestions = activation.payload.suggestions;
      if (index == null || index < 0 || index >= suggestions.length) {
        return NotificationActionResult.ignored;
      }
      return _reply(chatId, suggestions[index]);
    }

    switch (activation.actionId) {
      case WeftNotificationActions.reply:
        return _reply(chatId, activation.input);
      case WeftNotificationActions.markRead:
        return _markRead(chatId);
      case WeftNotificationActions.muteForAnHour:
        return _mute(chatId);
      case WeftNotificationActions.stopReplyReminder:
        return _stopReminders(chatId, activation.payload.eventId);
      default:
        // An action id this build does not know. Ignored rather than guessed
        // at: an iOS category registered by a *newer* build survives on
        // notifications this one posted.
        return NotificationActionResult.ignored;
    }
  }

  /// Sends what the user typed into the shade.
  ///
  /// No `via`, which is the whole of the network decision: [ChatRepository.send]
  /// resolves the chat's own send network through `sendSourceFor`, exactly as
  /// the composer does. So a reply from the shade rides the leg the user last
  /// chose in that conversation, rather than the leg this particular message
  /// happened to arrive on — a merged contact whose composer is set to Signal
  /// does not silently start answering over WhatsApp because WhatsApp is what
  /// buzzed.
  Future<NotificationActionResult> _reply(String chatId, String? input) async {
    final body = input?.trim() ?? '';
    // The user opened the field and closed it again. Sending an empty message
    // would be the worst possible reading of that.
    if (body.isEmpty) return NotificationActionResult.ignored;

    try {
      await _repository.send(chatId, body);
    } on Object catch (error) {
      // Offline, a room that has gone away, a homeserver saying no. The
      // notification is left standing on purpose: it is the only remaining
      // evidence that the message was neither read nor answered.
      debugPrint(
        'weft: a notification reply to $chatId could not be sent: '
        '$error',
      );
      return NotificationActionResult.failed;
    }

    // Answering is reading. The receipt is also what clears this notification
    // from the user's other devices, so it is worth doing even though the
    // reply already tells them as much.
    await _markReadQuietly(chatId);
    await _dismissQuietly(chatId);
    return NotificationActionResult.replied;
  }

  /// Moves the read marker, which is what dismisses the notification
  /// *elsewhere*.
  ///
  /// [ChatRepository.markRead] writes `m.read` in every source room of the
  /// chat. Two things follow from that one write, and both are the point of
  /// this action: the user's laptop stops showing the notification because its
  /// own `alreadyRead` rule now suppresses the message, and the homeserver's
  /// unread count drops — which is what makes the push gateway send the
  /// clearing push `WeftNotificationService.handlePush` turns into a dismissal.
  Future<NotificationActionResult> _markRead(String chatId) async {
    try {
      await _repository.markRead(chatId);
    } on Object catch (error) {
      debugPrint('weft: $chatId could not be marked read: $error');
      return NotificationActionResult.failed;
    }
    await _dismissQuietly(chatId);
    return NotificationActionResult.markedRead;
  }

  /// Writes a mute that lifts itself an hour from now.
  ///
  /// `clock.now()` rather than `DateTime.now()` so a test can pin the boundary
  /// the expiry is checked against; production never installs a clock, so the
  /// two are the same call.
  ///
  /// Only the policy is written, never the homeserver: a timed mute is
  /// Sennit-only because Matrix push rules cannot express an expiry, and pushing
  /// an unconditional server mute down for it would leave the room silent
  /// forever on every other client the user runs. See `push_rules.dart`.
  Future<NotificationActionResult> _mute(String chatId) async {
    try {
      _muteChat(chatId, until: clock.now().add(_muteDuration));
    } on Object catch (error) {
      debugPrint('weft: $chatId could not be muted: $error');
      return NotificationActionResult.failed;
    }
    await _dismissQuietly(chatId);
    return NotificationActionResult.muted;
  }

  /// "Stop reminding" on a reply reminder. The service cancels the reminder
  /// itself, delivered one included, so there is nothing to dismiss here.
  Future<NotificationActionResult> _stopReminders(
    String chatId,
    String eventId,
  ) async {
    final stop = _stopReplyReminder;
    if (stop == null) return NotificationActionResult.ignored;
    try {
      await stop(chatId, eventId: eventId);
    } on Object catch (error) {
      debugPrint('weft: reply reminders for $chatId could not stop: $error');
      return NotificationActionResult.failed;
    }
    return NotificationActionResult.remindersStopped;
  }

  Future<void> _markReadQuietly(String chatId) async {
    try {
      await _repository.markRead(chatId);
    } on Object catch (error) {
      // The reply went. A read marker that did not is not worth telling the
      // user their message failed over.
      debugPrint('weft: $chatId was replied to but not marked read: $error');
    }
  }

  Future<void> _dismissQuietly(String chatId) async {
    try {
      await _dismiss(chatId);
    } on Object catch (error) {
      // The work succeeded; a notification the platform would not take down is
      // untidy, not a failure.
      debugPrint('weft: $chatId notifications could not be cleared: $error');
    }
  }
}
