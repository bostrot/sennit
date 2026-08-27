import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'message.dart';
import 'network.dart';

/// One room feeding a chat, on one network.
@immutable
class ChatSource {
  const ChatSource({
    required this.roomId,
    required this.network,
    this.handleId,
    this.muted = false,
    this.unread = 0,
  });

  final String roomId;
  final ChatNetwork network;
  final String? handleId;
  final bool muted;

  /// Unread messages on *this* leg.
  ///
  /// A merged conversation sums its legs into one badge, which is what the
  /// inbox row shows and the right answer there. The rail asks a different
  /// question — which networks have something waiting — and answering it from
  /// the sum lit up every network a merged contact spans, so one WhatsApp
  /// message marked Signal, Telegram and Instagram unread as well.
  final int unread;

  @override
  bool operator ==(Object other) =>
      other is ChatSource && other.roomId == roomId;

  @override
  int get hashCode => roomId.hashCode;
}

/// A conversation as the user sees it in the inbox.
///
/// A plain chat has exactly one source. A merged chat has several, one per
/// network, and is otherwise identical — the inbox and timeline never branch on
/// which it is.
@immutable
class Chat {
  const Chat({
    required this.id,
    required this.title,
    required this.sources,
    this.contactId,
    this.avatarUrl,
    this.lastMessage,
    this.unreadCount = 0,
    this.isGroup = false,
    this.pinned = false,
    this.archived = false,
    this.muted = false,
    ChatNetwork? preferredSendNetwork,
  }) : _preferredSendNetwork = preferredSendNetwork;

  /// Room id for a single-source chat; `merged:<contactId>` for a merged one.
  final String id;

  final String title;
  final List<ChatSource> sources;

  /// The unified contact this chat belongs to, when it is a DM.
  final String? contactId;

  final String? avatarUrl;
  final WeftMessage? lastMessage;
  final int unreadCount;
  final bool isGroup;
  final bool pinned;
  final bool archived;
  final bool muted;

  final ChatNetwork? _preferredSendNetwork;

  bool get isMerged => sources.length > 1;

  /// Networks feeding this chat, in stable enum order.
  List<ChatNetwork> get networks {
    final seen = sources.map((s) => s.network).toSet();
    return ChatNetwork.values.where(seen.contains).toList(growable: false);
  }

  /// Which network an outgoing message rides.
  ///
  /// An explicit user choice always wins. Otherwise it defaults to the network
  /// of the last inbound message — replying on whichever app they actually used
  /// is nearly always what's wanted. Falls back to the first source so this is
  /// never null for a chat that has any source at all.
  ChatNetwork? get sendNetwork {
    if (_preferredSendNetwork != null &&
        sources.any((s) => s.network == _preferredSendNetwork)) {
      return _preferredSendNetwork;
    }
    final last = lastMessage;
    if (last != null &&
        !last.isOwn &&
        sources.any((s) => s.network == last.network)) {
      return last.network;
    }
    return sources.firstOrNull?.network;
  }

  /// True when [sendNetwork] came from an explicit user choice rather than
  /// being inferred, so the UI can show the chip as pinned.
  bool get hasExplicitSendNetwork =>
      _preferredSendNetwork != null &&
      sources.any((s) => s.network == _preferredSendNetwork);

  ChatSource? sourceFor(ChatNetwork network) =>
      sources.firstWhereOrNull((s) => s.network == network);

  List<String> get roomIds =>
      sources.map((s) => s.roomId).toList(growable: false);

  Chat copyWith({
    String? title,
    List<ChatSource>? sources,
    String? avatarUrl,
    WeftMessage? lastMessage,
    int? unreadCount,
    bool? pinned,
    bool? archived,
    bool? muted,
    Object? preferredSendNetwork = _sentinel,
  }) {
    return Chat(
      id: id,
      title: title ?? this.title,
      sources: sources ?? this.sources,
      contactId: contactId,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      lastMessage: lastMessage ?? this.lastMessage,
      unreadCount: unreadCount ?? this.unreadCount,
      isGroup: isGroup,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      muted: muted ?? this.muted,
      preferredSendNetwork: identical(preferredSendNetwork, _sentinel)
          ? _preferredSendNetwork
          : preferredSendNetwork as ChatNetwork?,
    );
  }

  static const Object _sentinel = Object();

  @override
  bool operator ==(Object other) => other is Chat && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Chat($id, "$title", ${sources.length} sources)';
}
