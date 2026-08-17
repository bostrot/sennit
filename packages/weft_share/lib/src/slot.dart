import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// Longest short label, in code points.
///
/// Android renders `shortLabel` under a share-sheet icon in a single line about
/// ten characters wide, and truncates the rest itself — but it truncates
/// mid-word, so "Alexandra Ka…" is what the user gets for a name that
/// [shortShareLabel] could have shown as "Alexandra".
const int kMaxShortLabelLength = 12;

/// Longest long label, in code points.
///
/// The launcher and the iOS picker both truncate for themselves; the cap here
/// is about what crosses the method channel and lands in the launcher's own XML
/// storage, once per published slot on every inbox tick.
const int kMaxLongLabelLength = 48;

/// What a target with no usable title is called.
const String kUnnamedShareTarget = 'Chat';

/// The stable id for [chatId] as a published shortcut.
///
/// Derives from [Chat.id] for the same reason the notification group key does:
/// one merged contact is one conversation, so it is one shortcut, and the
/// launcher entry, the bubble and the share target are the same thing seen from
/// three places.
///
/// Sanitised because a shortcut id is written into the launcher's own XML
/// storage, and a raw room id (`!abc:example.org`) carries characters some
/// launchers have historically choked on.
///
/// This must stay byte-identical to `chatShortcutId` in
/// `apps/weft/lib/services/notifications/notification_presentation.dart`, which
/// Phase 03 wrote first. Two derivations of one id is exactly the failure this
/// package exists to prevent — a notification that cannot bubble because it
/// names a shortcut that was published under a different string. The app's copy
/// collapses onto this one when the shortcut service lands.
String shareTargetSlotId(String chatId) =>
    'chat_${chatId.replaceAll(_unsafeIdCharacters, '_')}';

final RegExp _unsafeIdCharacters = RegExp(r'[^A-Za-z0-9_.-]');

/// A one-line name for [title], for the icon caption.
///
/// Prefers cutting at a word boundary — "Alexandra" reads as a person, and
/// "Alexandra Ka…" reads as a bug — and only ellipsizes when the first word is
/// itself too long. Cuts on code points rather than UTF-16 units so a title
/// ending in an emoji cannot be split into a lone surrogate, which some
/// launchers render as a replacement glyph and some refuse outright.
String shortShareLabel(String title, {int maxLength = kMaxShortLabelLength}) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return kUnnamedShareTarget;
  if (trimmed.runes.length <= maxLength) return trimmed;

  final firstWord = trimmed.split(RegExp(r'\s+')).first;
  if (firstWord.isNotEmpty && firstWord.runes.length <= maxLength) {
    return firstWord;
  }
  return '${_truncateRunes(trimmed, maxLength - 1)}…';
}

/// [title] trimmed and capped at [kMaxLongLabelLength].
String longShareLabel(String title, {int maxLength = kMaxLongLabelLength}) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return kUnnamedShareTarget;
  if (trimmed.runes.length <= maxLength) return trimmed;
  return '${_truncateRunes(trimmed, maxLength - 1)}…';
}

String _truncateRunes(String value, int length) =>
    String.fromCharCodes(value.runes.take(length < 0 ? 0 : length));

/// One conversation, published as a share target.
///
/// This is the *shape* of a shortcut, not the shortcut: nothing here resolves an
/// avatar, calls a launcher or writes a file. It exists so Android's
/// `ShortcutInfoCompat`, the iOS extension's picker list and the in-app share
/// sheet are three renderings of one list, rather than three lists that happen
/// to be built from the same chats.
///
/// Equality covers **every field, [rank] included**. That is what makes the
/// publish diff possible: republishing an unchanged slot costs a launcher
/// re-layout, and republishing all of them on every inbox tick makes the share
/// sheet visibly stutter. If two slots compare equal, the platform already has
/// the right one — including in the right position.
@immutable
class ShareTargetSlot {
  const ShareTargetSlot({
    required this.id,
    required this.chatId,
    required this.shortLabel,
    required this.longLabel,
    required this.link,
    required this.networks,
    this.avatarUrl,
    this.isGroup = false,
    this.pinned = false,
    this.rank = 0,
  });

  /// Everything [chat] contributes to a published slot.
  ///
  /// [rank] is the position the ranker put it in, and is passed to the
  /// platform's own ordering (`ShortcutInfoCompat.setRank`) rather than being
  /// implied by list order — a launcher is free to reorder what it is given,
  /// and only an explicit rank survives that.
  factory ShareTargetSlot.forChat(Chat chat, {int rank = 0}) => ShareTargetSlot(
    id: shareTargetSlotId(chat.id),
    chatId: chat.id,
    shortLabel: shortShareLabel(chat.title),
    longLabel: longShareLabel(chat.title),
    link: chatDeepLink(chat.id),
    networks: chat.networks,
    avatarUrl: chat.avatarUrl,
    isGroup: chat.isGroup,
    pinned: chat.pinned,
    rank: rank,
  );

  /// The shortcut id, and the `EXTRA_SHORTCUT_ID` a Direct Share intent carries
  /// back. [chatId] is what that resolves to.
  final String id;

  /// The [Chat.id] this targets. Not derivable from [id] — sanitising is lossy —
  /// which is why both travel.
  final String chatId;

  /// Caption under the icon.
  final String shortLabel;

  /// Name in a list, and the accessibility label.
  final String longLabel;

  /// `weft://chat/<encoded id>`, from [chatDeepLink].
  final String link;

  /// Every network feeding the chat, in stable enum order. Rendered as the
  /// badge on the avatar, and used by the sheet to offer a send network.
  final List<ChatNetwork> networks;

  /// The chat's avatar as an `mxc://` URI, unresolved.
  ///
  /// This package cannot fetch one and must not try. Both publishers resolve it
  /// themselves — Android to a file path it hands `BitmapFactory`, iOS to bytes
  /// in the App Group container — and both fall back to a generated initials
  /// icon when it is null or unreachable.
  final String? avatarUrl;

  final bool isGroup;

  /// Pinned chats sort ahead of everything, so this rides along for the surface
  /// that wants to say why.
  final bool pinned;

  /// Position in the published list, 0 first.
  final int rank;

  ShareTargetSlot copyWith({int? rank}) => ShareTargetSlot(
    id: id,
    chatId: chatId,
    shortLabel: shortLabel,
    longLabel: longLabel,
    link: link,
    networks: networks,
    avatarUrl: avatarUrl,
    isGroup: isGroup,
    pinned: pinned,
    rank: rank ?? this.rank,
  );

  /// The map form crossing the method channel, and the JSON the iOS extension
  /// reads out of the App Group container.
  ///
  /// One shape for both, because they are one contract: the Swift picker and
  /// the Kotlin publisher render the same fields, and a key renamed for one is
  /// a key missing for the other.
  Map<String, Object?> toJson() => {
    'id': id,
    'chatId': chatId,
    'shortLabel': shortLabel,
    'longLabel': longLabel,
    'link': link,
    'networks': [for (final network in networks) network.id],
    'avatarUrl': avatarUrl,
    'isGroup': isGroup,
    'pinned': pinned,
    'rank': rank,
  };

  /// Reads a slot back, or null when the blob is not one.
  ///
  /// Lenient in the same way [ShareStagingCodec] is, and for the same reason:
  /// this list is read by a process that cannot show an error — an extension
  /// that throws on a half-written target file shows the user a share sheet
  /// that crashes on open.
  static ShareTargetSlot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final chatId = raw['chatId'];
    final link = raw['link'];
    if (id is! String || id.isEmpty) return null;
    if (chatId is! String || chatId.isEmpty) return null;

    final longLabel = raw['longLabel'];
    final resolvedLong = longLabel is String && longLabel.isNotEmpty
        ? longLabel
        : kUnnamedShareTarget;
    final shortLabel = raw['shortLabel'];
    final rank = raw['rank'];

    return ShareTargetSlot(
      id: id,
      chatId: chatId,
      shortLabel: shortLabel is String && shortLabel.isNotEmpty
          ? shortLabel
          : shortShareLabel(resolvedLong),
      longLabel: resolvedLong,
      link: link is String && link.isNotEmpty ? link : chatDeepLink(chatId),
      networks: [
        for (final network in (raw['networks'] as List?) ?? const [])
          if (network is String) ChatNetwork.fromId(network),
      ],
      avatarUrl: raw['avatarUrl'] is String ? raw['avatarUrl'] as String : null,
      isGroup: raw['isGroup'] == true,
      pinned: raw['pinned'] == true,
      rank: rank is int ? rank : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShareTargetSlot &&
      other.id == id &&
      other.chatId == chatId &&
      other.shortLabel == shortLabel &&
      other.longLabel == longLabel &&
      other.link == link &&
      other.avatarUrl == avatarUrl &&
      other.isGroup == isGroup &&
      other.pinned == pinned &&
      other.rank == rank &&
      const ListEquality<ChatNetwork>().equals(other.networks, networks);

  @override
  int get hashCode => Object.hash(
    id,
    chatId,
    shortLabel,
    longLabel,
    link,
    avatarUrl,
    isGroup,
    pinned,
    rank,
    const ListEquality<ChatNetwork>().hash(networks),
  );

  @override
  String toString() => 'ShareTargetSlot($id, "$longLabel", rank $rank)';
}
