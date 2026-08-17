import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_share/weft_share.dart' show shareTargetSlotId;

import 'notification_channels.dart';

/// What a posted notification carries so a tap — or an action — can be acted on
/// after the process that posted it has died.
///
/// JSON in a string, because that is the only shape every backend of
/// `flutter_local_notifications` agrees to carry: Android puts it in an intent
/// extra, iOS in `userInfo`, Linux in a D-Bus hint. It has to survive a cold
/// start, so it holds ids rather than object references — by the time the user
/// taps, the [Chat] this was rendered from may not have been rebuilt yet.
///
/// [link] is the whole answer for a tap. The other three are for the
/// notification *actions*: replying needs a chat, marking read needs the room
/// the read marker lives in, and dismissing needs the event id the dedupe
/// ledger is keyed on.
@immutable
class NotificationPayload {
  const NotificationPayload({
    required this.link,
    required this.chatId,
    required this.roomId,
    required this.eventId,
    required this.network,
  });

  /// Built from the content the notification was rendered from.
  factory NotificationPayload.forContent(NotificationContent content) =>
      NotificationPayload(
        link: content.deepLink,
        chatId: content.groupKey,
        roomId: content.roomId,
        eventId: content.eventId,
        network: content.network,
      );

  /// `weft://chat/<encoded chat id>` — the merged chat's, not the room's.
  final String link;

  /// [Chat.id]: `merged:<contactId>` for a merged contact, else the room id.
  final String chatId;

  /// The *source* room. A merged chat has several; this is the one this
  /// notification's message actually arrived in, and the one a read marker
  /// would move in.
  final String roomId;

  final String eventId;
  final ChatNetwork network;

  String encode() => jsonEncode({
    'link': link,
    'chatId': chatId,
    'roomId': roomId,
    'eventId': eventId,
    'network': network.id,
  });

  /// Reads a payload back, tolerating everything a payload can turn out to be.
  ///
  /// A bare `weft://…` string decodes to a link-only payload rather than to
  /// null. That is not defensive padding: a notification posted by an older
  /// build, or by the iOS service extension — which renders from the push
  /// payload and has no access to this class — carries a plain link, and it
  /// must still open the right conversation when tapped. Null is reserved for
  /// "there was nothing here at all".
  static NotificationPayload? decode(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;

    if (!text.startsWith('{')) {
      return NotificationPayload(
        link: text,
        chatId: '',
        roomId: '',
        eventId: '',
        network: ChatNetwork.unknown,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    final link = decoded['link'];
    if (link is! String || link.isEmpty) return null;
    return NotificationPayload(
      link: link,
      chatId: decoded['chatId'] as String? ?? '',
      roomId: decoded['roomId'] as String? ?? '',
      eventId: decoded['eventId'] as String? ?? '',
      network: ChatNetwork.fromId(decoded['network'] as String? ?? ''),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationPayload &&
      other.link == link &&
      other.chatId == chatId &&
      other.roomId == roomId &&
      other.eventId == eventId &&
      other.network == network;

  @override
  int get hashCode => Object.hash(link, chatId, roomId, eventId, network);

  @override
  String toString() => 'NotificationPayload($eventId → $link)';
}

/// A stable notification id for [key].
///
/// The platforms want a 32-bit int where Weft has an event id, and the mapping
/// has to be a *function*: the same event must produce the same id in the sync
/// path, in the push path, and in a process that starts an hour later to
/// dismiss it. A counter would not survive the third case.
///
/// FNV-1a, folded into 31 bits so it is positive on every backend (Windows
/// rejects a negative id outright) and never zero, which some launchers read as
/// "no id". Collisions are possible and their consequence is bounded: two
/// notifications replace one another in the shade. The alternative — a
/// persisted id table — is a second database that would have to be pruned.
int stableNotificationId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  final folded = hash & 0x7fffffff;
  return folded == 0 ? 1 : folded;
}

/// One notification, rendered all the way down to what each platform's plugin
/// takes.
///
/// The seam this file exists to create: turning a [NotificationContent] into an
/// id, a payload and a `NotificationDetails` needs no device, no channel and no
/// plugin, so it is testable — while the one line that actually posts has
/// nothing left in it to test.
@immutable
class NotificationPresentation {
  const NotificationPresentation({
    required this.id,
    required this.groupKey,
    required this.title,
    required this.body,
    required this.payload,
    required this.details,
  });

  /// Renders one message.
  ///
  /// [conversation] is the messages already showing for this chat, oldest
  /// first and *including* this one. Android's `MessagingStyle` wants the
  /// thread rather than the latest line — it is what makes the expanded
  /// notification read like a conversation, and what a smartwatch or Android
  /// Auto reads out. An empty list degrades to a single-message style, which is
  /// what the first message in a chat is anyway.
  ///
  /// [avatarPaths] maps event id to a *file path*, not a URL: the platform
  /// draws the icon itself and cannot fetch. Resolving an `mxc://` URI to a
  /// file is [WeftNotificationService]'s job, through `mxcToThumbnailUrl`.
  /// Keyed by event rather than by sender because that is the key the caller
  /// already has one of per rendered message, and in a group each line is a
  /// different face.
  factory NotificationPresentation.forMessage({
    required NotificationContent content,
    bool silent = false,
    bool isGroup = false,
    List<NotificationContent> conversation = const [],
    Map<String, String> avatarPaths = const {},
  }) {
    final thread = conversation.isEmpty ? [content] : conversation;
    final avatarPath = avatarPaths[content.eventId];

    return NotificationPresentation(
      id: stableNotificationId(content.eventId),
      groupKey: content.groupKey,
      title: content.title,
      body: content.body,
      payload: NotificationPayload.forContent(content),
      details: NotificationDetails(
        android: AndroidNotificationDetails(
          messageChannelFor(content.network).id,
          content.network.label,
          channelDescription:
              'Messages that arrive over ${content.network.label}.',
          groupKey: content.groupKey,
          // The conversation *is* the notification. Without this the shade
          // shows one line and the expanded form shows the same line again.
          styleInformation: MessagingStyleInformation(
            _self,
            conversationTitle: content.title,
            groupConversation: isGroup,
            messages: [
              for (final message in thread)
                Message(
                  message.body,
                  message.timestamp,
                  Person(
                    key: message.senderName,
                    name: message.senderName,
                    icon: _androidIcon(avatarPaths[message.eventId]),
                  ),
                ),
            ],
          ),
          largeIcon: avatarPath == null
              ? null
              : FilePathAndroidBitmap(avatarPath),
          // `category: message` is what tells Do Not Disturb's "allow
          // messages" exception that this is one, and what puts the
          // notification where it belongs in Android Auto.
          category: AndroidNotificationCategory.message,
          importance: content.isMention ? Importance.max : Importance.high,
          priority: content.isMention
              ? Priority.high
              : Priority.defaultPriority,
          // Quiet hours with `deliverSilently`: waiting in the shade in the
          // morning, and nothing happened at 3am.
          silent: silent,
          // The shortcut is what makes this notification bubble-capable and
          // what puts the conversation in the launcher's share sheet.
          // Publishing it is native; only the id is agreed here.
          shortcutId: chatShortcutId(content.groupKey),
          when: content.timestamp.millisecondsSinceEpoch,
          color: Color(content.network.brandColor),
          tag: content.groupKey,
          // Reply, mark read, mute. The payload above is what makes them
          // answerable after this process has died: each one needs a chat to
          // act on, a room to move a read marker in, and an event id the dedupe
          // ledger is keyed on.
          actions: weftAndroidMessageActions(),
        ),
        iOS: DarwinNotificationDetails(
          // Must equal the Android group key. A merged contact whose iPhone
          // stacks its notifications differently from its Android is the exact
          // failure `notificationGroupKey` exists to prevent.
          threadIdentifier: content.threadId,
          categoryIdentifier: kMessageCategoryId,
          presentSound: !silent,
          interruptionLevel: content.isMention
              ? InterruptionLevel.timeSensitive
              : InterruptionLevel.active,
          subtitle: content.senderName,
        ),
        macOS: DarwinNotificationDetails(
          threadIdentifier: content.threadId,
          categoryIdentifier: kMessageCategoryId,
          presentSound: !silent,
          subtitle: content.senderName,
        ),
        linux: LinuxNotificationDetails(
          category: LinuxNotificationCategory.imReceived,
          urgency: content.isMention
              ? LinuxNotificationUrgency.critical
              : LinuxNotificationUrgency.normal,
          suppressSound: silent,
          icon: avatarPath == null ? null : FilePathLinuxIcon(avatarPath),
        ),
        windows: WindowsNotificationDetails(
          subtitle: content.senderName,
          images: [
            if (avatarPath != null)
              WindowsImage(
                Uri.file(avatarPath),
                altText: content.senderName,
                placement: WindowsImagePlacement.appLogoOverride,
              ),
          ],
        ),
      ),
    );
  }

  /// Renders the Android group summary for a chat with several unread
  /// notifications.
  ///
  /// Android only, and deliberately: iOS and macOS stack by `threadIdentifier`
  /// themselves and a summary posted there would simply be one more
  /// notification, while Linux and Windows have no grouping to summarise into.
  /// Posting it is what stops a bridge backfill filling the shade with forty
  /// rows for one conversation.
  factory NotificationPresentation.forSummary(NotificationSummary summary) {
    return NotificationPresentation(
      id: stableNotificationId('summary:${summary.groupKey}'),
      groupKey: summary.groupKey,
      title: summary.title,
      body: summary.body,
      payload: NotificationPayload(
        link: summary.deepLink,
        chatId: summary.groupKey,
        roomId: summary.latest.roomId,
        eventId: summary.latest.eventId,
        network: summary.latest.network,
      ),
      details: NotificationDetails(
        android: AndroidNotificationDetails(
          messageChannelFor(summary.latest.network).id,
          summary.latest.network.label,
          groupKey: summary.groupKey,
          setAsGroupSummary: true,
          // The children have already made their noise. Without this the
          // summary buzzes a second time for the same message.
          groupAlertBehavior: GroupAlertBehavior.children,
          styleInformation: InboxStyleInformation(
            summary.lines,
            contentTitle: summary.title,
            summaryText: summary.hiddenCount > 0
                ? '+${summary.hiddenCount} more'
                : null,
          ),
          category: AndroidNotificationCategory.message,
          importance: summary.containsMention
              ? Importance.max
              : Importance.high,
          onlyAlertOnce: true,
          shortcutId: chatShortcutId(summary.groupKey),
          when: summary.timestamp.millisecondsSinceEpoch,
          tag: 'summary:${summary.groupKey}',
        ),
      ),
    );
  }

  /// Stable across processes; see [stableNotificationId].
  final int id;

  /// [Chat.id]. Android's group key, iOS's thread identifier, and the key the
  /// service tracks posted notifications under.
  final String groupKey;

  final String title;
  final String body;
  final NotificationPayload payload;
  final NotificationDetails details;

  @override
  String toString() =>
      'NotificationPresentation($id in $groupKey, "$title: $body")';
}

/// The launcher shortcut id for a conversation.
///
/// Android requires a *published* shortcut with this id before it will let a
/// notification become a bubble or appear in the conversation section of the
/// shade. It derives from [Chat.id] for the same reason the group key does: one
/// merged contact is one conversation, so it is one shortcut, and long-pressing
/// it in the launcher opens the merged thread rather than one leg of it.
///
/// Sanitised because a shortcut id is written into the launcher's own XML
/// storage, and a raw room id (`!abc:example.org`) carries characters some
/// launchers have historically choked on.
///
/// Now one line over `weft_share`'s [shareTargetSlotId], which is the whole
/// point of it: a bubble and a Direct Share target are the *same shortcut* seen
/// from two places, and this had been the second derivation of that id. Two
/// derivations only have to disagree once — a notification naming a shortcut
/// published under a different string does not fail loudly, it simply stops
/// bubbling. The name stays because it is what the notification path calls the
/// thing, and `chatShortcutId` reads better at those call sites than a share
/// concept would.
String chatShortcutId(String chatId) => shareTargetSlotId(chatId);

/// The user, as `MessagingStyle` names the person a message is *not* from.
const Person _self = Person(name: 'You');

AndroidIcon<Object>? _androidIcon(String? path) =>
    path == null ? null : BitmapFilePathAndroidIcon(path);
