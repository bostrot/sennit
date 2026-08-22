import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

import 'rules.dart';

/// Longest body a notification carries.
///
/// The platform truncates for itself, but it does so *after* the string has
/// crossed a method channel, been held by the system notification service, and
/// — on Android — been written into the notification's parcel, which has a hard
/// size limit shared with every other notification the app has posted. A
/// four-thousand-character paste is a real message; carrying all of it to the
/// shade is not.
const int kMaxNotificationBodyLength = 240;

/// How many messages a summary spells out before it starts counting instead.
///
/// Android's `InboxStyle` renders at most six or seven lines depending on the
/// launcher, and iOS shows a stack rather than a list. Five leaves room for the
/// count line under it on every surface.
const int kMaxSummaryLines = 5;

/// What the body says when previews are switched off.
///
/// A notification, not the absence of one — see [renderNotificationBody].
const String kHiddenPreviewBody = 'New message';

/// The key every notification for one conversation shares.
///
/// It is [Chat.id], unchanged and unprefixed, because the app has already
/// answered the question this key asks. `MatrixChatRepository._applyMerges`
/// folds a contact's legs into a single `Chat` with `id: 'merged:<contactId>'`;
/// anything else keeps its room id. Re-deriving a key here — from the room id,
/// from the contact id, from a hash of the sources — is a second answer to that
/// question, and two answers drift.
///
/// **What it looks like when this is wrong.** Key on [WeftMessage.roomId] and a
/// merged contact's WhatsApp leg and Signal leg become two notification
/// threads: two rows in the shade for one conversation, two summaries each
/// counting half the messages ("2 new messages" twice for four messages), and
/// two taps that open two different single-source chats — neither of which is
/// the conversation the user actually reads, and neither of which clears the
/// other's badge when they read it. Key on [Chat.contactId] instead and every
/// group chat collapses into one thread, because `contactId` is null for
/// anything that is not a DM.
///
/// One consequence to know about rather than be surprised by: the key is not
/// stable forever. A merged chat reverts to a plain room id when a leg is left
/// or forgotten (`_applyMerges` needs two resolvable legs), so notifications
/// already in the shade under the old `merged:` key are not regrouped by the
/// platform. They stay where they are until dismissed, which is untidy and not
/// wrong.
String notificationGroupKey(Chat chat) => chat.id;

/// The deep link that opens [chatId], for a notification tap.
///
/// Delegates to [chatDeepLink]: a launcher shortcut and an iOS share slot now
/// have to produce the byte-identical string for the same chat, and the
/// escaping rule that makes a merged id survive the round trip is a property of
/// the link, not of notifications. Kept as a name of its own because a caller
/// building a `NotificationContent` is asking for a *notification's* tap
/// target, and that is worth saying at the call site.
String notificationLinkFor(String chatId) => chatDeepLink(chatId);

/// One notification, rendered but not yet posted.
///
/// Everything the platform layer needs and nothing it has to look up: the
/// strings to show, the key to group under, the link to fire on tap, and the
/// two Matrix ids an action has to send against. It is deliberately a value
/// object rather than a call into a plugin, so the mapping from a message to
/// what the user reads is testable without a device — which is the whole reason
/// this package exists.
///
/// Built from a [DeliveredDecision] rather than being a case of it: a silent
/// notification shows exactly the same text as a loud one, so rendering hangs
/// off *delivery*, not off loud-versus-quiet.
@immutable
class NotificationContent {
  const NotificationContent({
    required this.eventId,
    required this.roomId,
    required this.groupKey,
    required this.title,
    required this.body,
    required this.senderName,
    required this.timestamp,
    required this.network,
    required this.deepLink,
    this.senderAvatarUrl,
    this.isMention = false,
  });

  /// Renders [message] as it should appear for [chat] under [policy].
  ///
  /// [decision] is the verdict [evaluateNotification] already reached. Only
  /// [DeliveredDecision.mentioned] is read from it — the caller has established
  /// that something is being posted by the fact that they are calling this at
  /// all — and it is carried through so a collapsed summary can stay loud when
  /// one of the messages under it was a mention.
  ///
  /// [senderAvatarUrl] is an `mxc://` URI the caller resolved; this package
  /// cannot fetch one. It defaults to the chat's own avatar for a DM, where the
  /// chat avatar *is* the other person's, and to null for a group, where it
  /// would be the room's picture shown as if it were the sender's face.
  ///
  /// [disambiguateSender] appends the network name to the sender. It defaults
  /// to [Chat.isMerged] — see [disambiguatedSenderName].
  factory NotificationContent.forMessage({
    required WeftMessage message,
    required Chat chat,
    required NotificationPolicy policy,
    DeliveredDecision decision = const NotifyDecision(),
    String? senderAvatarUrl,
    bool? disambiguateSender,
  }) {
    return NotificationContent(
      eventId: message.eventId,
      roomId: message.roomId,
      groupKey: notificationGroupKey(chat),
      title: chat.title,
      body: renderNotificationBody(message, showPreview: policy.showPreviews),
      senderName: disambiguatedSenderName(
        message,
        withNetwork: disambiguateSender ?? chat.isMerged,
        // In a DM the chat title is the person, already resolved through
        // handles and the address book — the rescue for a bridge ghost whose
        // profile never backfilled and whose "name" is a raw identifier.
        fallbackName: chat.isGroup ? null : chat.title,
      ),
      senderAvatarUrl:
          senderAvatarUrl ?? (chat.isGroup ? null : chat.avatarUrl),
      timestamp: message.timestamp,
      network: message.network,
      deepLink: notificationLinkFor(chat.id),
      isMention: decision.mentioned,
    );
  }

  /// The event this notification is for. Not in the visible payload, but the
  /// handle everything after posting needs: dismissing this one notification,
  /// telling the platform two posts are the same message, and letting
  /// [NotificationDedupe] forget it if it is dismissed unread.
  final String eventId;

  /// The room the message actually arrived in — a *source* room, not the merged
  /// chat.
  ///
  /// Carried because a mark-as-read action has to move a read marker, and a
  /// read marker lives in a room. [groupKey] cannot answer that question: for a
  /// merged chat it names a conversation that no homeserver has heard of.
  final String roomId;

  /// The conversation this belongs to, from [notificationGroupKey]. Android's
  /// group key and, via [threadId], iOS's thread identifier.
  final String groupKey;

  /// Conversation title — the chat's, not the sender's, so a group reads as the
  /// group. For a DM they are the same string, which is why the sender is also
  /// carried separately.
  final String title;

  /// The text to show, already rendered per kind and already degraded if
  /// previews are off. Never empty.
  final String body;

  /// Who sent it, with the network appended when that would otherwise be
  /// ambiguous. Feeds Android's `MessagingStyle` sender and the inbox lines of
  /// a [NotificationSummary].
  final String senderName;

  /// `mxc://` URI for the sender's avatar, or null. Resolving it to bytes is
  /// the platform layer's job — `mxcToThumbnailUrl` in `weft_matrix`.
  final String? senderAvatarUrl;

  /// The message's origin timestamp, so a backfilled batch sorts by when it was
  /// *said* rather than when it was received.
  final DateTime timestamp;

  /// Which network the message came in on. Picks the channel and the badge; for
  /// a merged chat it is also the only thing distinguishing two otherwise
  /// identical notifications.
  final ChatNetwork network;

  /// `weft://chat/<encoded chat id>`, for the tap. Parsed by `WeftLink.parse`
  /// into an `OpenChatLink` and pushed by the router that already exists.
  final String deepLink;

  /// Whether the message mentioned the user. Raises priority — it is the reason
  /// this notification may have broken through a mute.
  final bool isMention;

  /// iOS/macOS `threadIdentifier`. The same string as [groupKey]: the platforms
  /// name the concept differently and Weft does not, and the platform task
  /// requires the two to match or a merged chat's iOS notifications stack apart
  /// from its Android ones.
  String get threadId => groupKey;

  /// One line of an inbox-style summary: who, then what.
  ///
  /// The sender is in the line even for a DM, because a summary is read at a
  /// glance and "Grace (WhatsApp): on my way" says more than "on my way". Any
  /// newlines are collapsed — a line is a line.
  String get inboxLine => '$senderName: ${_collapseWhitespace(body)}';

  NotificationContent copyWith({
    String? title,
    String? body,
    String? senderName,
    Object? senderAvatarUrl = _sentinel,
    bool? isMention,
  }) {
    return NotificationContent(
      eventId: eventId,
      roomId: roomId,
      groupKey: groupKey,
      title: title ?? this.title,
      body: body ?? this.body,
      senderName: senderName ?? this.senderName,
      senderAvatarUrl: identical(senderAvatarUrl, _sentinel)
          ? this.senderAvatarUrl
          : senderAvatarUrl as String?,
      timestamp: timestamp,
      network: network,
      deepLink: deepLink,
      isMention: isMention ?? this.isMention,
    );
  }

  static const Object _sentinel = Object();

  @override
  bool operator ==(Object other) =>
      other is NotificationContent &&
      other.eventId == eventId &&
      other.groupKey == groupKey &&
      other.title == title &&
      other.body == body &&
      other.senderName == senderName &&
      other.senderAvatarUrl == senderAvatarUrl &&
      other.timestamp == timestamp &&
      other.network == network &&
      other.deepLink == deepLink &&
      other.isMention == isMention;

  @override
  int get hashCode => Object.hash(
    eventId,
    groupKey,
    title,
    body,
    senderName,
    senderAvatarUrl,
    timestamp,
    network,
    deepLink,
    isMention,
  );

  @override
  String toString() =>
      'NotificationContent($eventId in $groupKey, "$senderName: $body")';
}

/// Several notifications for one conversation, collapsed into one.
///
/// Needed because a bridge backfill is not a trickle: connecting a WhatsApp
/// bridge, or coming back online after a flight, delivers dozens of events in
/// one sync. Posting each of them is a phone that buzzes forty times and a shade
/// the user clears rather than reads.
@immutable
class NotificationSummary {
  const NotificationSummary({
    required this.groupKey,
    required this.title,
    required this.body,
    required this.lines,
    required this.count,
    required this.hiddenCount,
    required this.timestamp,
    required this.deepLink,
    required this.networks,
    required this.containsMention,
    required this.latest,
  });

  /// The conversation, same value as every [NotificationContent.groupKey] under
  /// it. On Android this is what the group *summary* notification posts under.
  final String groupKey;

  /// The chat title, from the most recent message.
  final String title;

  /// The collapsed line: "3 new messages". At a count of one it is that
  /// message's own body instead — a summary that only says "1 new message" has
  /// thrown away the one thing the user wanted to know.
  final String body;

  /// The expanded, inbox-style list, oldest first so it reads like the
  /// conversation does. At most [kMaxSummaryLines] entries; the rest are
  /// counted in [hiddenCount].
  final List<String> lines;

  /// How many messages this stands for, [lines] included.
  final int count;

  /// How many of [count] have no line of their own. Zero unless the batch
  /// exceeded the line cap; the platform renders it as "+15 more".
  final int hiddenCount;

  /// The newest message's timestamp, so the summary sorts where the
  /// conversation belongs.
  final DateTime timestamp;

  /// Same link as every notification under it — they all open the one chat.
  final String deepLink;

  /// Which networks contributed, in stable enum order. For a merged chat this
  /// is the whole point of the summary being one thing: three messages on
  /// WhatsApp and two on Signal are five messages from one person.
  final Set<ChatNetwork> networks;

  /// Whether any of the messages mentioned the user. Kept so collapsing a batch
  /// cannot quietly demote a mention to background chatter.
  final bool containsMention;

  /// The most recent notification, for the avatar, sender, and network the
  /// collapsed row shows.
  final NotificationContent latest;

  @override
  String toString() =>
      'NotificationSummary($groupKey, $count messages, ${lines.length} lines)';
}

/// Collapses [contents] — all for one conversation — into a single summary.
///
/// Returns null for an empty list: nothing to summarise is not an empty
/// summary, and posting "0 new messages" is worse than posting nothing.
///
/// Ordering is by [NotificationContent.timestamp] with the event id as
/// tie-breaker, the same rule the merged timeline sorts by, so two messages
/// stamped identically on two networks always collapse the same way round.
///
/// Mixed group keys are a caller error — the argument is one chat's
/// notifications — and the assert says so in debug. In release the newest
/// entry's conversation wins and foreign entries are dropped rather than
/// counted: a summary that mixes two conversations is wrong in a way the user
/// sees, and one that quietly ignores a caller's bug is wrong in a way they
/// don't.
NotificationSummary? summarise(
  List<NotificationContent> contents, {
  int maxLines = kMaxSummaryLines,
}) {
  if (contents.isEmpty) return null;

  final ordered = [...contents]..sort(_byTimestampThenEventId);
  final latest = ordered.last;
  assert(
    ordered.every((c) => c.groupKey == latest.groupKey),
    'summarise takes the notifications of one conversation; got '
    '${ordered.map((c) => c.groupKey).toSet()}',
  );
  final group = ordered
      .where((c) => c.groupKey == latest.groupKey)
      .toList(growable: false);

  final lines =
      (group.length <= maxLines
              ? group
              : group.sublist(group.length - maxLines))
          .map((c) => c.inboxLine)
          .toList(growable: false);

  final networks = group.map((c) => c.network).toSet();

  return NotificationSummary(
    groupKey: latest.groupKey,
    title: latest.title,
    body: group.length == 1 ? latest.body : '${group.length} new messages',
    lines: lines,
    count: group.length,
    hiddenCount: group.length - lines.length,
    timestamp: latest.timestamp,
    deepLink: latest.deepLink,
    // Stable enum order rather than encounter order, so the same batch
    // summarises identically however it arrived.
    networks: {
      for (final network in ChatNetwork.values)
        if (networks.contains(network)) network,
    },
    containsMention: group.any((c) => c.isMention),
    latest: latest,
  );
}

/// The sender as the notification names them.
///
/// [withNetwork] appends the network label, which matters exactly when the same
/// person reaches the user two ways: in a merged chat "Grace" and "Grace" are
/// two notifications the user cannot tell apart, and replying to the wrong one
/// sends over the wrong network. "Grace (WhatsApp)" and "Grace (Signal)" are
/// two conversations with one person, which is what they are.
///
/// Falls back to the network label alone when the sender has no display name —
/// a bridge ghost that has not backfilled its profile yet — because "(WhatsApp)"
/// as a whole name is still better than an empty string where a name goes.
String disambiguatedSenderName(
  WeftMessage message, {
  required bool withNetwork,
  String? fallbackName,
}) {
  var name = message.senderName.trim();
  // "Whatsapp Lid-135575105487050" is a bridge ghost's raw identifier worn
  // as a display name — WhatsApp's hidden-number ids and Signal's UUIDs both
  // reach here when the ghost's profile has not backfilled. A caller who
  // knows who the conversation is *with* supplies that instead.
  if (looksLikeRawBridgeIdentifier(name)) {
    final fallback = fallbackName?.trim() ?? '';
    if (fallback.isNotEmpty && !looksLikeRawBridgeIdentifier(fallback)) {
      name = fallback;
    }
  }
  if (name.isEmpty) return message.network.label;
  return withNetwork ? '$name (${message.network.label})' : name;
}

/// Whether [name] is a machine identifier rather than something a person is
/// called: a long digit run (phone numbers, WhatsApp LIDs) or a UUID chunk.
/// Deliberately conservative — a false positive here renames a real person.
bool looksLikeRawBridgeIdentifier(String name) {
  if (RegExp(r'\d{7,}').hasMatch(name)) return true;
  return RegExp(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}',
    caseSensitive: false,
  ).hasMatch(name);
}

/// The text of a notification for [message].
///
/// Per kind, because "sent you a photo" and the photo's filename are different
/// facts and only one of them is in the body of an `m.image`. A voice note
/// renders its transcript when one has landed — a notification that reads
/// "running 10 late" is the difference between opening the app and not — and
/// "Voice message" until then.
///
/// With [showPreview] false the whole thing degrades to [kHiddenPreviewBody]
/// rather than the notification being dropped. That is the distinction the
/// setting actually names: the user asked not to have their messages readable
/// over their shoulder, not to stop being told they have any. The sender and
/// chat title are still shown — this matches Android's "hide sensitive content"
/// and not iOS's "hide previews", and a caller that wants the stricter reading
/// degrades [NotificationContent.title] and [NotificationContent.senderName]
/// too, which it can do with `copyWith`.
///
/// A [maxLength] of zero or less disables truncation. That is how
/// `weft_snapshot` reuses the per-kind rendering under a cut of its own: a
/// widget row is a fixed box where the UTF-16 `substring` below can leave half
/// a surrogate pair on screen until the next message arrives, so it truncates
/// on grapheme clusters instead and needs the untruncated body to do it.
///
/// No emoji, deliberately, which is where this parts company with
/// `ChatTile._preview` ("📷 Photo"). A notification body is read aloud by
/// TalkBack and VoiceOver; "camera Photo IMG_4021.jpg" is not an improvement on
/// "Photo · IMG_4021.jpg", and the inbox already carries the decorated version
/// for the surface people actually look at.
String renderNotificationBody(
  WeftMessage message, {
  bool showPreview = true,
  int maxLength = kMaxNotificationBodyLength,
}) {
  if (!showPreview) return kHiddenPreviewBody;
  return _truncate(_bodyForKind(message), maxLength);
}

String _bodyForKind(WeftMessage message) {
  // The projected body, not the raw one. A formatted message must reach the
  // shade as what it says — `<b>fire</b>` notifies as "fire", never as its
  // tags, which is also what stops a `<script>` the reader was never shown from
  // being read out by TalkBack. And a reply's quoted-context fallback goes with
  // it: a notification that opened with `> <@alice:example.org> …` would
  // announce the message being answered instead of the answer.
  final body = plainMessageText(
    body: message.body,
    formattedBody: message.formattedBody,
  ).trim();
  return switch (message.kind) {
    // Media bodies are the filename for most senders and the caption for the
    // ones that follow MSC2530. Either way it is the text the sender attached
    // to the file, and either way it belongs after the label — which is why
    // this does not try to tell the two apart.
    MessageKind.image => _labelled('Photo', body),
    MessageKind.video => _labelled('Video', body),
    MessageKind.file => _labelled('File', body),
    MessageKind.audio => _labelled('Audio', body),
    MessageKind.voice => _voice(message),
    MessageKind.sticker => _labelled('Sticker', body),
    MessageKind.location => 'Location',
    MessageKind.poll => _labelled('Poll', body),
    // Suppressed by `evaluateNotification` before it ever reaches here; handled
    // anyway so a caller rendering a decision it made itself cannot produce an
    // empty notification.
    MessageKind.text ||
    MessageKind.event => body.isEmpty ? kHiddenPreviewBody : body,
  };
}

String _voice(WeftMessage message) {
  final transcript = message.transcript?.trim();
  if (transcript == null || transcript.isEmpty) return 'Voice message';
  return transcript;
}

String _labelled(String label, String body) =>
    body.isEmpty ? label : '$label · $body';

String _truncate(String text, int maxLength) {
  if (maxLength <= 0 || text.length <= maxLength) return text;
  // Cut at the last space in the tail rather than mid-word, but only if there
  // is one close enough that the result is not visibly short.
  final head = text.substring(0, maxLength);
  final space = head.lastIndexOf(' ');
  final cut = space > maxLength - 24 ? head.substring(0, space) : head;
  return '${cut.trimRight()}…';
}

String _collapseWhitespace(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim();

int _byTimestampThenEventId(NotificationContent a, NotificationContent b) {
  final byTime = a.timestamp.compareTo(b.timestamp);
  return byTime != 0 ? byTime : a.eventId.compareTo(b.eventId);
}
