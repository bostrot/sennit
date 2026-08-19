import 'package:characters/characters.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

import 'policy.dart';

/// Version stamped into every snapshot payload.
///
/// Load-bearing, which is where this parts company with
/// `kStagedShareFormatVersion`. That one is documented as being "present for
/// diagnosis, not for gating: the extension ships *inside* the app bundle, so a
/// reader older than its writer cannot exist." That premise is false here. A
/// home screen widget, a watch app and a Lock Screen accessory are processes
/// the OS starts and keeps on its own schedule, and it can hold one across an
/// app update — so a reader older than its writer is the ordinary case rather
/// than the pathological one, and the version is how it finds out. See
/// `SnapshotCodec.decode` for what it does about it, which is degrade rather
/// than refuse.
const int kSnapshotFormatVersion = 1;

/// How long a snapshot is presented as current.
///
/// After this a surface should say "open Weft on your phone" rather than show
/// counts it cannot vouch for. Twelve hours because the writer only runs while
/// the app does: a phone that was not opened overnight has a snapshot from
/// bedtime, and showing that at breakfast is right. Showing it at dinner is
/// showing yesterday's unread count as today's.
const Duration kSnapshotStaleAfter = Duration(hours: 12);

/// Longest preview a row carries.
///
/// Shorter than `kMaxNotificationBodyLength` (240) and for a different reason.
/// A notification body is capped by Android's parcel budget; a snapshot preview
/// is capped by the box it is drawn in. The widest surface that renders one —
/// the large WidgetKit family, the Glance list — gives a preview two lines of
/// roughly forty characters at the default text size, and the first thing many
/// users do to a widget is make the text bigger. Anything past this is carried
/// across a process boundary, counted against the payload byte cap sixteen
/// times over, and then clipped by a `Text` that was never going to draw it.
const int kMaxSnapshotPreviewLength = 80;

/// What a row's title says when [SnapshotPolicy.includeSenderNames] is off.
///
/// A row rather than no row: the same reasoning as `kHiddenPreviewBody` — the
/// user asked not to have their conversations readable over their shoulder, not
/// to stop being told they have any. The unread count is still there, and that
/// is the fact the surface exists to show.
const String kRedactedRowTitle = 'Conversation';

/// What a preview says when the last message was redacted.
///
/// Matches `ChatTile`'s wording rather than inventing a second one; a deleted
/// message reads the same in the inbox and on the wrist.
const String kDeletedPreview = 'Message deleted';

/// Above this, an unread count renders as `99+`.
///
/// The same rule as `WeftUnreadBadge`, restated here because that widget is
/// Flutter and this number has to reach a Glance composable and a SwiftUI view
/// that cannot import it. One conversation reading `120` on the phone and `99+`
/// on the watch is two surfaces disagreeing about a number neither of them
/// computed.
const int kUnreadBadgeCap = 99;

/// One conversation, as a companion surface is allowed to see it.
///
/// Everything a Glance row or a WidgetKit `Link` needs and nothing it has to
/// look up — because the process rendering this has no Matrix session, no
/// database, and on iOS not even a Flutter engine. Every field here has already
/// been through [SnapshotPolicy]; there is no second filter on the far side and
/// there cannot be one.
@immutable
class SnapshotRow {
  const SnapshotRow({
    required this.chatId,
    required this.title,
    required this.link,
    required this.unreadCount,
    required this.networks,
    this.preview,
    this.senderName,
    this.avatarUrl,
    this.timestamp,
    this.isMerged = false,
  });

  /// `Chat.id` — a room id, or `merged:<contactId>` for a merged conversation.
  ///
  /// Taken from the chat, never re-derived. `MatrixChatRepository._applyMerges`
  /// has already answered "which conversation is this", and a widget answering
  /// it a second time is a second answer that will drift: key on a room id
  /// instead and a merged contact's WhatsApp and Signal legs become two rows
  /// counting half the unread each, two taps into two chats, and neither of
  /// them the conversation the user actually reads.
  final String chatId;

  /// What the row is labelled: the chat's title, or [kRedactedRowTitle] when
  /// [SnapshotPolicy.includeSenderNames] is off.
  final String title;

  /// `weft://chat/<encoded id>`, from `chatDeepLink`.
  ///
  /// Produced in Dart and carried, rather than rebuilt on each platform. Glance
  /// sets it on an intent and WidgetKit on a `widgetURL`, and a merged id's
  /// colon has to survive both — one escape apart and the link opens nothing.
  ///
  /// A row can outlive the conversation it names: a merged chat reverts to a
  /// plain room id when one of its legs is left, and a widget process may hold
  /// this payload for hours afterwards. The link is therefore a request, not a
  /// promise, and the deep-link handling on the other side has to tolerate an
  /// id that no longer resolves.
  final String link;

  /// Unread messages in the conversation, uncapped. See [unreadLabel] for what
  /// a surface draws.
  final int unreadCount;

  /// Which networks feed this conversation, in stable enum order.
  ///
  /// Stable order so the same conversation renders its glyph strip the same way
  /// round on every surface and every refresh.
  final Set<ChatNetwork> networks;

  /// What the last message said, already rendered per kind and already
  /// truncated. Null when previews are off or the conversation has no messages.
  final String? preview;

  /// Who sent the last message, or null when names are off.
  final String? senderName;

  /// `mxc://` avatar URI, or null when names are off or the chat has none.
  ///
  /// A reference, not bytes: resolving it is the platform layer's job, and a
  /// snapshot carrying sixteen thumbnails would blow the payload byte cap
  /// before it carried a single word.
  final String? avatarUrl;

  /// When the last message landed, or null for a conversation with none.
  final DateTime? timestamp;

  /// Whether this is a merged conversation.
  ///
  /// Carried explicitly rather than inferred from `networks.length`, because a
  /// surface has to signal merged-ness at least two ways — `ChatTile` uses
  /// three, and never colour alone — and a row with room for one glyph still
  /// needs to be able to say so in its accessibility label.
  final bool isMerged;

  /// The badge text, capped at [kUnreadBadgeCap].
  ///
  /// Formatted here rather than on each platform for the same reason [link] is:
  /// two hand-written renderers implementing one rule is one rule too many.
  String get unreadLabel =>
      unreadCount > kUnreadBadgeCap ? '$kUnreadBadgeCap+' : '$unreadCount';

  Map<String, Object?> toJson() => {
    'id': chatId,
    'title': title,
    'link': link,
    'unread': unreadCount,
    'unreadLabel': unreadLabel,
    'networks': [for (final network in networks) network.id],
    'merged': isMerged,
    if (preview != null) 'preview': preview,
    if (senderName != null) 'sender': senderName,
    if (avatarUrl != null) 'avatar': avatarUrl,
    if (timestamp != null)
      'timestamp': timestamp!.toUtc().millisecondsSinceEpoch,
  };

  /// [raw] as a row, or null when it is not a usable one.
  ///
  /// Usable means it has an id: without one the row cannot be tapped, and a row
  /// that renders but does nothing is worse than a row that is not there. Every
  /// other field degrades rather than refusing — a missing title reads as
  /// [kRedactedRowTitle], a missing link is rebuilt from the id, an
  /// unparseable count is zero.
  static SnapshotRow? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;

    final title = raw['title'];
    final link = raw['link'];
    final unread = raw['unread'];
    final preview = raw['preview'];
    final sender = raw['sender'];
    final avatar = raw['avatar'];
    final merged = raw['merged'];

    final networks = <ChatNetwork>{
      for (final network in _listOrEmpty(raw['networks']))
        if (network is String) ChatNetwork.fromId(network),
    };

    return SnapshotRow(
      chatId: id,
      title: title is String && title.isNotEmpty ? title : kRedactedRowTitle,
      link: link is String && link.isNotEmpty ? link : chatDeepLink(id),
      unreadCount: unread is int && unread > 0 ? unread : 0,
      networks: orderedNetworks(networks),
      preview: preview is String && preview.isNotEmpty ? preview : null,
      senderName: sender is String && sender.isNotEmpty ? sender : null,
      avatarUrl: avatar is String && avatar.isNotEmpty ? avatar : null,
      timestamp: parseSnapshotTimestamp(raw['timestamp']),
      isMerged: merged is bool ? merged : networks.length > 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SnapshotRow &&
      other.chatId == chatId &&
      other.title == title &&
      other.link == link &&
      other.unreadCount == unreadCount &&
      other.preview == preview &&
      other.senderName == senderName &&
      other.avatarUrl == avatarUrl &&
      other.timestamp == timestamp &&
      other.isMerged == isMerged &&
      const SetEquality<ChatNetwork>().equals(other.networks, networks);

  @override
  int get hashCode => Object.hash(
    chatId,
    title,
    link,
    unreadCount,
    preview,
    senderName,
    avatarUrl,
    timestamp,
    isMerged,
    const SetEquality<ChatNetwork>().hash(networks),
  );

  @override
  String toString() =>
      'SnapshotRow($chatId, "$title", $unreadCount unread, $networks)';
}

/// The whole of what leaves the encrypted store for a companion surface.
///
/// Three states a surface has to tell apart, and this is how:
///
/// * **Signed out** — no payload at all. The writer deletes it on logout, so an
///   absent payload means "nobody is logged in" rather than "nothing has
///   happened yet".
/// * **Switched off** — a payload with [enabled] false and no rows. Written
///   rather than deleted, precisely so the widget can say *why* it is empty and
///   point at the setting instead of showing a sign-in prompt to someone who is
///   already signed in.
/// * **Nothing to show** — [enabled] true, [rows] empty. An inbox with no
///   conversations, or one whose every conversation is on an excluded network.
@immutable
class InboxSnapshot {
  const InboxSnapshot({
    required this.generatedAt,
    required this.rows,
    required this.totalUnread,
    this.enabled = true,
    this.version = kSnapshotFormatVersion,
  });

  /// The switched-off payload: empty, and saying why.
  InboxSnapshot.disabled(DateTime now)
    : generatedAt = now.toUtc(),
      rows = const [],
      totalUnread = 0,
      enabled = false,
      version = kSnapshotFormatVersion;

  /// When the phone wrote this, in UTC. What [isStaleAt] judges, and the only
  /// thing standing between a widget and confidently showing yesterday.
  final DateTime generatedAt;

  /// Conversations, in the order the inbox gave them.
  ///
  /// Not re-sorted here, deliberately: the inbox has already decided what
  /// "recent" means — pinned first, then activity — and a companion surface
  /// showing a different top three than the app it companions is a bug the user
  /// reads as the app being wrong about their messages.
  final List<SnapshotRow> rows;

  /// Unread messages across every conversation the policy allowed — including
  /// the ones past the row cap.
  ///
  /// A field rather than a sum over [rows], because the Lock Screen accessory
  /// and the watch complication show exactly this number, and the seventeenth
  /// conversation's unread messages are still unread.
  final int totalUnread;

  /// Whether the gate was open when this was written. False only for
  /// [InboxSnapshot.disabled].
  final bool enabled;

  /// The format version this was written as, or decoded from. See
  /// [kSnapshotFormatVersion].
  final int version;

  /// Whether this payload is old enough that a surface should stop presenting
  /// it as current.
  bool isStaleAt(DateTime now, {Duration staleAfter = kSnapshotStaleAfter}) =>
      now.toUtc().difference(generatedAt) > staleAfter;

  /// True when the payload came from a build newer than this reader.
  ///
  /// Not an error and not a refusal — see `SnapshotCodec.decode`. It is a
  /// reason for a surface to prefer the counts it understood over any layout
  /// that assumes it understood everything.
  bool get isFutureVersion => version > kSnapshotFormatVersion;

  /// Brand colours for the networks present, as `0xAARRGGBB` ints.
  ///
  /// Carried in the payload rather than re-tabled on each platform. The
  /// precedent is `ChatNetwork.brandColor` itself, held as an int "so this
  /// package stays Flutter-free"; this is the same trick one process further
  /// out, for renderers that cannot import Dart at all. Only the networks
  /// actually in [rows], because the table is dead weight for the fourteen
  /// networks a given inbox does not use.
  Map<String, int> get palette => {
    for (final network in ChatNetwork.values)
      if (rows.any((row) => row.networks.contains(network)))
        network.id: network.brandColor,
  };

  Map<String, Object?> toJson() => {
    'version': version,
    'generatedAt': generatedAt.toUtc().millisecondsSinceEpoch,
    'enabled': enabled,
    'totalUnread': totalUnread,
    'palette': palette,
    'rows': [for (final row in rows) row.toJson()],
  };

  InboxSnapshot copyWith({List<SnapshotRow>? rows, int? totalUnread}) =>
      InboxSnapshot(
        generatedAt: generatedAt,
        rows: rows ?? this.rows,
        totalUnread: totalUnread ?? this.totalUnread,
        enabled: enabled,
        version: version,
      );

  @override
  bool operator ==(Object other) =>
      other is InboxSnapshot &&
      other.generatedAt.isAtSameMomentAs(generatedAt) &&
      other.totalUnread == totalUnread &&
      other.enabled == enabled &&
      other.version == version &&
      const ListEquality<SnapshotRow>().equals(other.rows, rows);

  @override
  int get hashCode => Object.hash(
    generatedAt.toUtc(),
    totalUnread,
    enabled,
    version,
    const ListEquality<SnapshotRow>().hash(rows),
  );

  @override
  String toString() =>
      'InboxSnapshot(${rows.length} rows, $totalUnread unread, '
      'enabled: $enabled, generated $generatedAt)';
}

/// Applies [policy] to [chats] and returns what a companion surface may render.
///
/// This is the whole privacy decision, in one function, so that it is one test
/// file rather than three platform reviews. In order:
///
/// 1. A disabled policy returns [InboxSnapshot.disabled] — empty, and *saying*
///    it is empty because it was switched off. Never a partial snapshot: there
///    is no "a bit disabled".
/// 2. Any chat with a network the policy excludes is dropped whole. Not
///    filtered down to its allowed legs — a merged row shows one title and one
///    preview for several networks, and there is no way to render "the Signal
///    half" of it. Excluding a network has to mean its messages do not leave
///    the encrypted store, and half a merged row does not clear that bar.
/// 3. [InboxSnapshot.totalUnread] is summed over everything that survived step
///    2, *before* the row cap, so the watch complication also counts the
///    conversations the list had no room for.
/// 4. Rows are taken in the caller's order and cut at [SnapshotPolicy.rowCap].
/// 5. Previews are rendered by `weft_notify`, collapsed to one line, and cut at
///    [kMaxSnapshotPreviewLength] on a grapheme boundary.
///
/// [now] is injected rather than read, because "is this snapshot stale" is a
/// question a test has to be able to ask.
InboxSnapshot buildSnapshot({
  required List<Chat> chats,
  required SnapshotPolicy policy,
  required DateTime now,
}) {
  if (!policy.enabled) return InboxSnapshot.disabled(now);

  final allowed = chats
      .where((chat) => chat.networks.every(policy.allows))
      .toList(growable: false);

  final totalUnread = allowed.fold<int>(
    0,
    (sum, chat) => sum + (chat.unreadCount > 0 ? chat.unreadCount : 0),
  );

  final capped = allowed.length > policy.rowCap
      ? allowed.sublist(0, policy.rowCap)
      : allowed;

  return InboxSnapshot(
    generatedAt: now.toUtc(),
    rows: [for (final chat in capped) buildSnapshotRow(chat, policy)],
    totalUnread: totalUnread,
  );
}

/// One chat as a row under [policy].
///
/// Exposed because the surfaces settings screen shows a live preview of exactly
/// what a widget row would say, and that preview has to be built the real way:
/// a hand-made mock-up of a row is a second answer to what the policy does, and
/// it is the answer nobody re-checks after the policy changes.
SnapshotRow buildSnapshotRow(Chat chat, SnapshotPolicy policy) {
  final last = chat.lastMessage;
  return SnapshotRow(
    chatId: chat.id,
    title: policy.includeSenderNames ? chat.title : kRedactedRowTitle,
    link: chatDeepLink(chat.id),
    unreadCount: chat.unreadCount > 0 ? chat.unreadCount : 0,
    networks: orderedNetworks(chat.networks.toSet()),
    preview: policy.includePreviews ? renderSnapshotPreview(last) : null,
    senderName: policy.includeSenderNames && last != null
        ? snapshotSenderName(last, chat: chat)
        : null,
    avatarUrl: policy.includeSenderNames ? chat.avatarUrl : null,
    timestamp: last?.timestamp,
    isMerged: chat.isMerged,
  );
}

/// The preview line for [message], or null when there is nothing to show.
///
/// Delegates the per-kind rendering to `renderNotificationBody`, so a widget row
/// says what a notification for the same message would have said: the
/// plain-text projection of a formatted body rather than its tags — which is
/// also what keeps markup from a bridged network out of a view the system
/// renders — "Photo · IMG_4021.jpg" rather than a bare filename, and a voice
/// note's transcript once one has landed. It also means **no emoji**, parting
/// company with `ChatTile._preview`'s "📷 Photo": a widget is looked at, but a
/// WidgetKit view is also read aloud by VoiceOver, and this is the more
/// constrained of the two surfaces.
///
/// Two things are this package's own. Newlines are collapsed, because a Glance
/// `Text` handed a three-line paste renders three lines into a box sized for
/// two. And the cut is at a grapheme boundary — see [truncatePreview].
String? renderSnapshotPreview(WeftMessage? message) {
  if (message == null) return null;
  if (message.redacted) return kDeletedPreview;
  // `maxLength: 0` disables `weft_notify`'s own UTF-16 truncation, so the
  // grapheme-aware cut below is the only one that happens.
  final body = renderNotificationBody(message, maxLength: 0);
  return truncatePreview(_collapseWhitespace(body));
}

/// Who sent the last message, as a row names them.
///
/// The network is appended for a merged chat and only there, the same rule
/// `disambiguatedSenderName` applies to notifications: "Grace" and "Grace" are
/// two rows the reader cannot tell apart, and on a watch they are two things
/// they might reply to.
String snapshotSenderName(WeftMessage message, {required Chat chat}) =>
    disambiguatedSenderName(message, withNetwork: chat.isMerged);

/// [text] cut to [maxLength] **grapheme clusters**, with an ellipsis.
///
/// The one place this package deliberately does not copy `weft_notify`. Its
/// `_truncate` works in UTF-16 code units via `substring`, which can split a
/// surrogate pair, a combining sequence, a skin-tone modifier or a ZWJ emoji.
/// In a notification shade that is a momentary replacement glyph in a row that
/// scrolls away. In a widget it is a fixed box that renders a broken glyph at
/// the end of every refresh for as long as that message is the newest one, and
/// on a watch face it is one of about forty glyphs on screen.
///
/// Word-boundary behaviour is the same as `weft_notify`'s: cut at the last
/// space when one is close enough to the end that the result is not visibly
/// short, otherwise cut hard. The 24-cluster window is measured in graphemes
/// here rather than code units, so an emoji-heavy preview does not silently
/// lose the word cut.
String truncatePreview(
  String text, [
  int maxLength = kMaxSnapshotPreviewLength,
]) {
  if (maxLength <= 0) return text;
  final clusters = text.characters;
  if (clusters.length <= maxLength) return text;

  final head = clusters.take(maxLength).toString();
  final space = head.lastIndexOf(' ');
  if (space > 0) {
    final tail = head.substring(space).characters.length;
    if (tail <= 24) return '${head.substring(0, space).trimRight()}…';
  }
  return '${head.trimRight()}…';
}

/// [networks] in stable enum order.
///
/// A `Set` preserves insertion order in Dart, so building one in enum order is
/// how a set stays a set and still renders the same way round twice running.
/// The same thing `summarise` does for a notification summary's networks.
Set<ChatNetwork> orderedNetworks(Set<ChatNetwork> networks) => {
  for (final network in ChatNetwork.values)
    if (networks.contains(network)) network,
};

/// Epoch milliseconds or an ISO-8601 string, as UTC, or null.
///
/// The inversion of `weft_share`'s `_parseTimestamp`, and the reason both forms
/// are accepted: there, Swift wrote and Dart read; here Dart writes and Swift
/// and Kotlin read, so the payload uses the integer both of them parse without
/// a formatter. The string form stays supported because a hand-written fixture
/// reaches for it first.
DateTime? parseSnapshotTimestamp(Object? raw) {
  if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

List<Object?> _listOrEmpty(Object? raw) => raw is List ? raw : const [];

String _collapseWhitespace(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim();
