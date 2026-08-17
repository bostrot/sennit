import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:weft_domain/weft_domain.dart';

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

  /// The input field's id on the platforms that name one.
  static const String replyInput = 'weft.reply.input';
}

/// What the "Mute for 1 hour" action writes.
///
/// An hour because that is what the action says, and a *timed* mute because
/// that is the only kind this action can be: Matrix push rules have no expiry,
/// so a mute that lifts itself is necessarily Weft's own. `push_rules.dart`
/// therefore never sends it to the homeserver, and the suppression happens
/// where the body is readable — locally, in `evaluateNotification`.
const Duration kMuteForAnHour = Duration(hours: 1);

/// The three action buttons an Android message notification carries.
///
/// **All three set `showsUserInterface: true`, and that is a decision rather
/// than an oversight.** Android delivers an action whose pending intent is a
/// broadcast — which is what `showsUserInterface: false` produces — only to a
/// *background* isolate, through
/// `onDidReceiveBackgroundNotificationResponse`. Every one of Weft's actions
/// needs the Matrix client that lives in the main isolate: a reply has to be
/// encrypted with an Olm session, a read marker is a write through the same
/// `Client`, and a timed mute lands in the settings database the app already
/// holds open. A second isolate would need its own vodozemac initialisation and
/// its own handle on that database — the same wall background decryption hit,
/// and for the same reason it is not climbed here.
///
/// So the action's intent launches the activity instead, and the response
/// arrives in the main isolate through `onDidReceiveNotificationResponse` —
/// or, when Weft was not running, through `getNotificationAppLaunchDetails`,
/// which [NotificationSink.launchActivation] already reads. The reply text is
/// still typed in the shade: `RemoteInput` collects it before the intent fires
/// and it travels on that intent. What it costs is that Weft comes to the
/// foreground to do the work, which is the thing to revisit if a
/// background-capable client isolate is ever built.
///
/// `cancelNotification` is false on all three: the plugin only honours it in
/// the broadcast receiver these actions deliberately do not use, and
/// [NotificationActionHandler] dismisses the conversation itself once the work
/// has actually succeeded. A reply that could not be sent therefore leaves its
/// notification standing rather than vanishing into a message that never went.
List<AndroidNotificationAction> weftAndroidMessageActions() => [
  AndroidNotificationAction(
    WeftNotificationActions.reply,
    'Reply',
    inputs: const [AndroidNotificationActionInput(label: 'Message')],
    // What tells Android Auto, Wear and the launcher's bubble that this is
    // *the* reply action rather than a button that happens to be first.
    semanticAction: SemanticAction.reply,
    // Deliberately left at its default of false. Generated replies are the
    // system reading the message body to propose an answer to it, and Weft
    // has spent this whole phase keeping that body off every surface it does
    // not have to be on.
    showsUserInterface: true,
    cancelNotification: false,
  ),
  const AndroidNotificationAction(
    WeftNotificationActions.markRead,
    'Mark read',
    semanticAction: SemanticAction.markAsRead,
    showsUserInterface: true,
    cancelNotification: false,
  ),
  const AndroidNotificationAction(
    WeftNotificationActions.muteForAnHour,
    'Mute for 1 hour',
    semanticAction: SemanticAction.mute,
    showsUserInterface: true,
    cancelNotification: false,
  ),
];

/// The Android channel a message on [network] is posted to.
///
/// Per network, which is the point: Android's per-channel controls are the only
/// place a user can turn a *sound* down without turning Weft off, and "mute
/// WhatsApp, keep Signal" is the single most asked-for thing in a unified
/// messenger. Weft's own [NotificationPolicy] can express the same idea, but
/// only Weft obeys it — the channel is what the system's own settings screen,
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
  description: 'Messages that arrive over ${network.label}.',
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
List<AndroidNotificationChannel> weftNotificationChannels() => [
  for (final network in ChatNetwork.values) messageChannelFor(network),
  const AndroidNotificationChannel(
    kCallsChannelId,
    'Calls',
    description: 'Incoming calls.',
    importance: Importance.max,
  ),
  const AndroidNotificationChannel(
    kBackgroundChannelId,
    'Background activity',
    description: 'Syncing, bridge reconnections and finished uploads.',
    importance: Importance.low,
    showBadge: false,
    playSound: false,
    enableVibration: false,
  ),
];

const AndroidNotificationChannelGroup weftMessagesChannelGroup =
    AndroidNotificationChannelGroup(
      kMessagesChannelGroupId,
      'Messages',
      description: 'One channel per network, so each can be tuned separately.',
    );

/// The Darwin categories registered at initialisation.
///
/// [DarwinNotificationAction.text] is iOS's inline reply — the field that opens
/// under the notification without opening Weft. The two `foreground: false`
/// actions deliberately do not launch the app: marking read and muting for an
/// hour are things a user does *instead* of opening a conversation, and an
/// action that opens the app to do them has failed at the only thing it was for.
List<DarwinNotificationCategory> weftDarwinCategories() => [
  DarwinNotificationCategory(
    kMessageCategoryId,
    actions: [
      DarwinNotificationAction.text(
        WeftNotificationActions.reply,
        'Reply',
        buttonTitle: 'Send',
        placeholder: 'Message',
      ),
      DarwinNotificationAction.plain(
        WeftNotificationActions.markRead,
        'Mark read',
      ),
      DarwinNotificationAction.plain(
        WeftNotificationActions.muteForAnHour,
        'Mute for 1 hour',
      ),
    ],
    options: {
      // Without this iOS shows the app name where the conversation title
      // should be, and a merged contact's two legs read as two apps.
      DarwinNotificationCategoryOption.hiddenPreviewShowTitle,
      DarwinNotificationCategoryOption.hiddenPreviewShowSubtitle,
    },
  ),
];
