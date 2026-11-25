import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/localisation.dart';

/// The Android channel group every conversation channel sits under.
///
/// A group rather than a flat list because there is one channel *per network*,
/// and seventeen loose entries in Android's notification settings is a screen
/// nobody reads. Grouped, the user sees "Messages" and can open it to silence
/// WhatsApp without silencing Signal — which is the whole reason the channels
/// are split that way.
const String kMessagesChannelGroupId = 'weft.messages';

/// Channel for calls. Created now, unused until M9.
///
/// Created *now* rather than when calling ships because a channel's importance
/// is fixed at creation: Android ignores every later attempt to raise it, on the
/// grounds that an app must not be able to make itself louder after the user has
/// turned it down. A calls channel created at high importance on first launch is
/// therefore the only calls channel Weft will ever get to have.
const String kCallsChannelId = 'weft.calls';

/// Channel for the app's own background work — sync progress, a bridge
/// reconnecting, an upload finishing after the app was backgrounded.
///
/// Low importance and no badge: this is the channel that exists so those
/// notices have somewhere to go that is *not* the one the user's messages
/// arrive on.
const String kBackgroundChannelId = 'weft.background';

/// Channel for reply reminders — "you read this and have not answered".
///
/// Its own channel rather than the network's, so a user who finds the nudges
/// too loud can turn *them* down in Android's settings without touching the
/// messages they are about. Default importance: a reminder is worth a sound,
/// not a heads-up over whatever the user is doing.
const String kReplyRemindersChannelId = 'weft.reply_reminders';

/// The Darwin category a reply reminder is posted under. Separate from
/// [kMessageCategoryId] because its one action is not a message's three.
const String kReplyReminderCategoryId = 'weft.reply_reminder';

/// Prefix of the per-network conversation channels. See [messageChannelFor].
const String kMessageChannelPrefix = 'weft.messages.';

/// The Darwin category a message notification is posted under.
///
/// One category, not one per network: on iOS the category names the *set of
/// actions* a notification carries, and reply/mark-read/mute are the same three
/// whichever network the message rode in on. Networks are distinguished by the
/// thread identifier and the body, which is where a user looks for them.
const String kMessageCategoryId = 'weft.message';

/// Action ids, shared by every platform that has actions.
///
/// One set of strings rather than one per platform, because the handler that
/// receives them is one function: `flutter_local_notifications` hands back the
/// same `actionId` whether it came from an Android action button, an iOS
/// `UNNotificationAction`, or a Linux `org.freedesktop.Notifications` action.
/// They are constants rather than literals because the same three strings are
/// written in three places — the iOS category, the Android actions, and
/// `NotificationActionHandler` — and a typo in any one of them is an action
/// that silently does nothing.
///
/// iOS categories are registered at *initialisation*, so an action added later
/// does not appear on a notification posted by a build that had already
/// registered the category without it. That is why all three were declared
/// before any of them did anything.
abstract final class WeftNotificationActions {
  static const String reply = 'weft.reply';
  static const String markRead = 'weft.mark_read';
  static const String muteForAnHour = 'weft.mute_1h';

  /// Android's third button: one action whose input choices are the two
  /// reminders and the mute, because Android shows three buttons and no more.
  static const String later = 'weft.later';

  /// iOS and macOS have room for the reminders as actions of their own.
  static const String remindInAnHour = 'weft.remind_1h';
  static const String remindTonight = 'weft.remind_tonight';

  /// "Stop reminding" on a reply reminder: no more reminders about the message
  /// it is about. The next message from the other side starts over.
  static const String stopReplyReminder = 'weft.reply_reminder.stop';

  /// The input field's id on the platforms that name one.
  static const String replyInput = 'weft.reply.input';

  /// Prefix of the tappable AI answer actions; the index into
  /// `NotificationPayload.suggestions` follows it.
  static const String aiReplyPrefix = 'weft.ai_reply.';
}

/// What the "Mute for 1 hour" action writes.
///
/// An hour because that is what the action says, and a *timed* mute because
/// that is the only kind this action can be: Matrix push rules have no expiry,
/// so a mute that lifts itself is necessarily Sennit's own. `push_rules.dart`
/// therefore never sends it to the homeserver, and the suppression happens
/// where the body is readable — locally, in `evaluateNotification`.
const Duration kMuteForAnHour = Duration(hours: 1);

/// What "Later" can mean, picked from its choices or from the iOS actions.
enum LaterChoice { remindInAnHour, remindTonight, muteForAnHour }

/// When "Remind tonight" reminds: 19:00 today, the time the chat's own
/// "Remind me" offers. Once that has passed, 9:00 tomorrow — the Android
/// choice is then labelled "Tomorrow morning"; the iOS action's title is
/// registered once and cannot follow the clock.
DateTime remindTonightAt(DateTime now) {
  final tonight = DateTime(now.year, now.month, now.day, 19);
  return tonight.isAfter(now)
      ? tonight
      : DateTime(now.year, now.month, now.day + 1, 9);
}

/// The input choices of Android's "Later" action, in order, as of [now].
List<String> laterChoiceLabels(DateTime now) {
  final l10n = weftPlatformL10n();
  return [
    l10n.notificationRemindInAnHour,
    remindTonightAt(now).day == now.day
        ? l10n.notificationRemindTonight
        : l10n.notificationRemindTomorrowMorning,
    l10n.notificationActionMuteHour,
  ];
}

/// Which choice the text Android hands back is.
///
/// A choice comes back as its label, so this matches the label against every
/// one the action can have carried; null for anything else.
LaterChoice? laterChoiceFor(String? input) {
  final l10n = weftPlatformL10n();
  final text = input?.trim();
  if (text == l10n.notificationRemindInAnHour) {
    return LaterChoice.remindInAnHour;
  }
  if (text == l10n.notificationRemindTonight ||
      text == l10n.notificationRemindTomorrowMorning) {
    return LaterChoice.remindTonight;
  }
  if (text == l10n.notificationActionMuteHour) return LaterChoice.muteForAnHour;
  return null;
}

/// The three action buttons an Android message notification carries.
///
/// **Reply and Mark read run headless (`showsUserInterface: false`); Mute
/// opens Sennit.** Android Auto, Wear and the conversation bubble only offer
/// an action that does not bring up the phone's screen — a driver cannot be
/// handed the app — and they find the two by their [SemanticAction], not by
/// position. Such an action is a broadcast, which the plugin delivers to a
/// background isolate through `onDidReceiveBackgroundNotificationResponse`;
/// `runBackgroundNotificationAction` passes it to the UI isolate's (or the
/// sync daemon's) live Matrix client when there is one, and boots the same
/// headless stack background push uses when there is not. The reply text is
/// collected by `RemoteInput` and travels on the broadcast.
///
/// The third is "Later": its choices remind in an hour, remind tonight, or
/// mute for an hour. Headless too, so a reminder is set without opening the
/// app; the UI isolate does it when alive, and otherwise the headless stack
/// writes the reminder and the mute where the app reads them back.
///
/// `cancelNotification` is false on all three: [NotificationActionHandler]
/// dismisses the conversation itself once the work has actually succeeded. A
/// reply that could not be sent therefore leaves its notification standing
/// rather than vanishing into a message that never went.
List<AndroidNotificationAction> weftAndroidMessageActions({
  List<String> aiReplies = const [],
  DateTime? now,
}) {
  final l10n = weftPlatformL10n();
  return [
    AndroidNotificationAction(
      WeftNotificationActions.reply,
      l10n.notificationActionReply,
      // The AI answers ride the reply input as *choices*: Android renders
      // them as tappable chips above the action row — the smart-reply look —
      // and a tapped chip arrives as ordinary reply text through the same
      // handler typed replies use. Chips instead of extra actions, because
      // three actions is all Android shows and Mark read is worth keeping.
      inputs: [
        AndroidNotificationActionInput(
          label: l10n.chatComposerMessage,
          choices: aiReplies,
        ),
      ],
      // What tells Android Auto, Wear and the launcher's bubble that this is
      // *the* reply action rather than a button that happens to be first.
      semanticAction: SemanticAction.reply,
      // Generated replies (`allowGeneratedReplies`) are deliberately left at
      // their default of false. They are the system reading the message body
      // to propose an answer to it, and Sennit has spent this whole phase
      // keeping that body off every surface it does not have to be on.
      showsUserInterface: false,
      cancelNotification: false,
    ),
    AndroidNotificationAction(
      WeftNotificationActions.markRead,
      l10n.notificationActionMarkRead,
      semanticAction: SemanticAction.markAsRead,
      showsUserInterface: false,
      cancelNotification: false,
    ),
    AndroidNotificationAction(
      WeftNotificationActions.later,
      l10n.notificationActionLater,
      inputs: [
        AndroidNotificationActionInput(
          label: l10n.notificationActionLater,
          choices: laterChoiceLabels(now ?? DateTime.now()),
          allowFreeFormInput: false,
        ),
      ],
      showsUserInterface: false,
      cancelNotification: false,
    ),
  ];
}

/// The Android channel a message on [network] is posted to.
///
/// Per network, which is the point: Android's per-channel controls are the only
/// place a user can turn a *sound* down without turning Weft off, and "mute
/// WhatsApp, keep Signal" is the single most asked-for thing in a unified
/// messenger. Weft's own [NotificationPolicy] can express the same idea, but
/// only Sennit obeys it — the channel is what the system's own settings screen,
/// Do Not Disturb, and a smartwatch see.
///
/// A merged chat therefore posts to *two* channels, one per leg, which is
/// correct: the group key still collapses them into one conversation in the
/// shade, while the sound each one makes stays under the control of the network
/// it arrived on.
AndroidNotificationChannel messageChannelFor(
  ChatNetwork network,
) => AndroidNotificationChannel(
  '$kMessageChannelPrefix${network.id}',
  network.label,
  description: weftPlatformL10n().notificationChannelNetwork(network.label),
  groupId: kMessagesChannelGroupId,
  // High rather than max: max is a heads-up notification that takes over the
  // screen, which is a phone call, not a text message.
  importance: Importance.high,
);

/// Every channel Weft creates at startup.
///
/// All of them, every launch: creating a channel that already exists updates its
/// *name and description* and leaves the user's own importance and sound
/// choices alone, so this is also how a renamed network or a translated string
/// reaches a device that has been installed for a year.
List<AndroidNotificationChannel> weftNotificationChannels() {
  final l10n = weftPlatformL10n();
  return [
    for (final network in ChatNetwork.values) messageChannelFor(network),
    AndroidNotificationChannel(
      kCallsChannelId,
      l10n.notificationChannelCalls,
      description: l10n.notificationChannelCallsDescription,
      importance: Importance.max,
    ),
    AndroidNotificationChannel(
      kBackgroundChannelId,
      l10n.notificationChannelBackground,
      description: l10n.notificationChannelBackgroundDescription,
      importance: Importance.low,
      showBadge: false,
      playSound: false,
      enableVibration: false,
    ),
    AndroidNotificationChannel(
      kReplyRemindersChannelId,
      l10n.notificationChannelReplyReminders,
      description: l10n.notificationChannelReplyRemindersDescription,
    ),
  ];
}

/// The one action a reply reminder carries on Android.
///
/// `showsUserInterface: true`: the reminder ledger and its scheduler live in
/// the UI isolate, which a headless action could not reach with the app
/// closed. No semantic action either, on purpose — a reminder is Sennit
/// talking, not a person, so it is posted without `MessagingStyle` and stays
/// off Android Auto, which reads only conversations, and off CarPlay, which
/// announces only messages.
List<AndroidNotificationAction> weftAndroidReplyReminderActions() => [
  AndroidNotificationAction(
    WeftNotificationActions.stopReplyReminder,
    weftPlatformL10n().notificationActionStopReminding,
    showsUserInterface: true,
    cancelNotification: false,
  ),
];

AndroidNotificationChannelGroup weftMessagesChannelGroup() {
  final l10n = weftPlatformL10n();
  return AndroidNotificationChannelGroup(
    kMessagesChannelGroupId,
    l10n.notificationChannelGroupMessages,
    description: l10n.notificationChannelGroupDescription,
  );
}

/// The Darwin categories registered at initialisation.
///
/// [DarwinNotificationAction.text] is iOS's inline reply — the field that opens
/// under the notification without opening Weft. The plain actions
/// deliberately do not launch the app: marking read, muting for an hour and
/// asking to be reminded later are things a user does *instead* of opening a
/// conversation, and an action that opens the app to do them has failed at
/// the only thing it was for.
List<DarwinNotificationCategory> weftDarwinCategories() {
  final l10n = weftPlatformL10n();
  return [
    DarwinNotificationCategory(
      kMessageCategoryId,
      actions: [
        DarwinNotificationAction.text(
          WeftNotificationActions.reply,
          l10n.notificationActionReply,
          buttonTitle: l10n.commonSend,
          placeholder: l10n.chatComposerMessage,
        ),
        DarwinNotificationAction.plain(
          WeftNotificationActions.markRead,
          l10n.notificationActionMarkRead,
        ),
        DarwinNotificationAction.plain(
          WeftNotificationActions.muteForAnHour,
          l10n.notificationActionMuteHour,
        ),
        DarwinNotificationAction.plain(
          WeftNotificationActions.remindInAnHour,
          l10n.notificationRemindInAnHour,
        ),
        DarwinNotificationAction.plain(
          WeftNotificationActions.remindTonight,
          l10n.notificationRemindTonight,
        ),
      ],
      options: {
        // Without this iOS shows the app name where the conversation title
        // should be, and a merged contact's two legs read as two apps.
        DarwinNotificationCategoryOption.hiddenPreviewShowTitle,
        DarwinNotificationCategoryOption.hiddenPreviewShowSubtitle,
        // What lets a message reach the car's screen once Apple has granted
        // the CarPlay communication entitlement; without the entitlement iOS
        // ignores it. Only messages: a reply reminder is not something to
        // put in front of a driver. See docs/car-integrations.md.
        DarwinNotificationCategoryOption.allowInCarPlay,
      },
    ),
    DarwinNotificationCategory(
      kReplyReminderCategoryId,
      actions: [
        // Foreground, for the reason the Android action gives: the reminder
        // ledger is the UI isolate's, and a background engine with the app
        // closed has no scheduler to stop.
        DarwinNotificationAction.plain(
          WeftNotificationActions.stopReplyReminder,
          l10n.notificationActionStopReminding,
          options: {DarwinNotificationActionOption.foreground},
        ),
      ],
    ),
  ];
}
