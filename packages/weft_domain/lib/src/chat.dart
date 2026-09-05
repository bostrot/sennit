import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'message.dart';
import 'network.dart';
import 'request.dart';

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
    this.request,
    this.participantCount,
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

  /// Where this conversation stands as a chat *request*, or null — the normal
  /// case — for a conversation that was never one.
  ///
  /// Null rather than a `none` member of [ChatRequestState] so that the
  /// ordinary path stays the default: `chat.request == null` is what almost
  /// every chat is, and a value everything had to compare against `none` would
  /// make the rare case the one the code is written around.
  final ChatRequestState? request;

  /// How many people are in this conversation *besides* the user, or null when
  /// the membership is not known.
  ///
  /// Carried for one purpose: the group read semantic. Blue ticks mean everyone
  /// has read it, and "everyone" is a number — without it a client holding one
  /// receipt cannot tell one reader out of one from one out of nine, and the
  /// honest answer is then to stop at delivered. See [resolveDeliveryState].
  ///
  /// Null is the normal state for a bridged group whose membership the bridge
  /// has not backfilled, and is not an error. It costs a mark that would have
  /// been wrong as often as it was right.
  final int? participantCount;

  /// How many people have to have read a message before it counts as read.
  ///
  /// [participantCount] when the membership is known, and **1 for a chat that is
  /// not a group** whatever the membership says — that is what "not a group"
  /// means, and a DM whose summary has not arrived would otherwise lose its blue
  /// ticks for no reason a user could name.
  ///
  /// Null only for a group whose size is genuinely unknown, where
  /// [resolveDeliveryState] stops at delivered rather than guessing: one receipt
  /// out of nine looks exactly like one out of one.
  int? get peerCount => participantCount ?? (isGroup ? null : 1);

  /// Whether this conversation is still waiting for the user to answer it.
  ///
  /// The inbox holds these out of the main list; the notification rules treat
  /// them differently; and nothing here sends a read receipt. See
  /// [ChatRequestPlan.markRead] for why that last one is the load-bearing part.
  bool get isPendingRequest => request == ChatRequestState.pending;

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
    Object? request = _sentinel,
    int? participantCount,
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
      // A sentinel rather than `??`, because clearing it is what accepting a
      // request *is*: an accepted conversation is an ordinary one, and a null
      // that meant "leave it alone" would leave the row in the requests
      // section for ever.
      request: identical(request, _sentinel)
          ? this.request
          : request as ChatRequestState?,
      participantCount: participantCount ?? this.participantCount,
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
