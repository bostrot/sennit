import 'dart:typed_data';

import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

/// Everything the inbox and chat UI need from the world below them.
///
/// The UI is written against this interface rather than against the Matrix SDK,
/// so [DemoChatRepository] can drive the whole app today and the Matrix-backed
/// implementation lands in M1 without the UI changing.
abstract class ChatRepository {
  /// Networks the user actually has bridges configured for.
  List<ChatNetwork> get availableNetworks;

  /// The unified inbox, newest activity first.
  Stream<List<Chat>> watchChats();

  /// A merged (or single-source) timeline for one chat.
  ///
  /// Async because a Matrix timeline has to be opened before it can be read;
  /// pretending otherwise would mean handing out sources that are silently
  /// empty for their first few frames.
  Future<MergedTimeline> timelineFor(String chatId);

  /// The identity graph backing merge suggestions.
  IdentityGraph get identityGraph;

  /// Merge / unmerge / dismiss, routed through the repository rather than the
  /// graph directly so the decision is persisted and the inbox rebuilt in one
  /// step. Mutating [identityGraph] behind the repository's back would leave
  /// the decision lost on restart.
  Future<void> mergeHandles(String handleIdA, String handleIdB);
  Future<void> unmergeHandle(String handleId);
  Future<void> rejectSuggestion(String handleIdA, String handleIdB);

  /// Feeds messages into the search index. Called by the chat view as history
  /// loads, so reading a conversation is what makes it searchable.
  void indexMessages(
    String chatId,
    List<WeftMessage> messages, {
    String chatTitle = '',
  });

  Future<void> send(String chatId, String body, {ChatNetwork? via});

  /// Records the network the user picked for outgoing messages in this chat.
  Future<void> setSendNetwork(String chatId, ChatNetwork network);

  Future<void> markRead(String chatId);

  /// Moves a chat out of the inbox without leaving the room.
  Future<void> setArchived(String chatId, {required bool archived});

  Future<void> setMuted(String chatId, {required bool muted});

  /// Leaves and forgets every room behind the chat. Irreversible: the history
  /// is gone from this account, which is why callers confirm first.
  Future<void> deleteChat(String chatId);

  /// Bytes of a message's attachment, decrypting when the room is encrypted.
  ///
  /// Bytes rather than a URL because an encrypted attachment has no fetchable
  /// URL at all — the ciphertext must be downloaded and unwrapped locally. One
  /// path therefore serves both encrypted and plain rooms.
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  });
}

/// Filters the inbox by the rail's selection.
///
/// Empty [networks] means no filter. A merged chat matches when *any* of its
/// sources match — filtering to Signal should still surface a merged
/// conversation that has a Signal leg, otherwise merging would hide chats.
List<Chat> filterChats(List<Chat> chats, Set<ChatNetwork> networks) {
  if (networks.isEmpty) return chats;
  return chats
      .where((c) => c.networks.any(networks.contains))
      .toList(growable: false);
}

/// Unread totals per network, for the rail badges. A merged chat contributes
/// its unread count to every network it spans, since the user cannot tell which
/// leg the unread messages arrived on until they open it.
Map<ChatNetwork, int> unreadByNetwork(List<Chat> chats) {
  final out = <ChatNetwork, int>{};
  for (final chat in chats) {
    if (chat.unreadCount == 0) continue;
    for (final n in chat.networks) {
      out[n] = (out[n] ?? 0) + chat.unreadCount;
    }
  }
  return out;
}
