import 'dart:typed_data';

import 'package:weft_attachments/weft_attachments.dart';
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

  /// Sends [source] as an attachment, uploading it first.
  ///
  /// Takes an [AttachmentSource] — a name, a size and a header slice — rather
  /// than a path or a full byte array because *what this file is* is decided in
  /// `weft_attachments`, not here: the sniffed mime type, the msgtype, whether
  /// a thumbnail is worth generating, and the one that renders as a broken
  /// attachment on every other client when it is wrong — whether the mxc URI
  /// belongs under `url` or under `file.url`. The repository supplies only the
  /// two things that package deliberately cannot know: transport to a
  /// homeserver, and which room of a merged chat [via] resolves to.
  ///
  /// Completes when the upload has been *accepted*, not when the bytes have
  /// landed. Sharing twenty photos would otherwise leave the caller awaiting
  /// twenty uploads in series; progress is watched through [watchUploads]
  /// instead.
  ///
  /// [isVoiceNote] is the recorder's assertion and is only meaningful for
  /// audio — it is what separates [MessageKind.voice] from [MessageKind.audio].
  Future<void> sendAttachment(
    String chatId,
    AttachmentSource source, {
    ChatNetwork? via,
    bool isVoiceNote = false,
  });

  /// Uploads in flight, and recently finished ones, for this chat.
  ///
  /// A stream of its own rather than part of [timelineFor] because an upload is
  /// not a message yet: it has no event id, it can fail and be retried, and it
  /// has to be renderable before the homeserver has heard of it at all. The
  /// timeline draws these above the settled messages and drops each task once
  /// its real event arrives.
  Stream<List<UploadTask>> watchUploads(String chatId);

  /// Tries a failed or cancelled upload again, with a fresh attempt budget.
  ///
  /// Keyed by [UploadTask.id] rather than by chat because the retry button
  /// lives on one failed bubble in a chat that may hold several. The queue
  /// still holds that task's plan, which is what spares the user picking the
  /// file a second time.
  Future<void> retryUpload(String taskId);

  /// Abandons an upload. Best-effort against a socket already on the wire, but
  /// immediate from the user's point of view: a late success is discarded
  /// rather than resurrecting the task.
  Future<void> cancelUpload(String taskId);
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
