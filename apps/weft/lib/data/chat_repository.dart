import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
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

  /// The conversation [roomId] belongs to, as the inbox has already resolved
  /// it, or null when it has not resolved one yet.
  ///
  /// Synchronous and by room because the notification path asks this question
  /// about an event that has just arrived, from outside the widget tree, and
  /// must get *the* answer rather than a second one: a merged contact's
  /// WhatsApp room and Signal room both return the same `merged:<contactId>`
  /// chat, which is what makes them one notification thread. A closure over
  /// [watchChats] at the call site would be that second answer, and the two
  /// would drift the moment the merge fold changed.
  ///
  /// Null during first sync, and for a room that has just been joined. The
  /// caller's correct response is to stay quiet rather than to invent a key.
  Chat? chatForRoom(String roomId);

  /// Moves whenever a merge or unmerge changes which rooms back which chat.
  ///
  /// An open chat view holds a [MergedTimeline] built for one composition;
  /// when this moves it rebuilds through [timelineFor] instead of showing one
  /// leg of a conversation that just became three.
  int get timelineEpoch => 0;

  /// A merged (or single-source) timeline for one chat.
  ///
  /// Async because a Matrix timeline has to be opened before it can be read;
  /// pretending otherwise would mean handing out sources that are silently
  /// empty for their first few frames.
  Future<MergedTimeline> timelineFor(String chatId);

  /// Chats that exist to *operate* a bridge rather than to talk to a person —
  /// the management DM with `@whatsappbot` and friends.
  ///
  /// Surfaced as ids rather than filtered out of [watchChats]: the bridges
  /// screen still opens these on request, deep links still resolve them, and
  /// only the inbox's default view hides them. An empty set is the correct
  /// answer for every repository without bridges.
  Set<String> get serviceChatIds => const {};

  /// The identity graph backing merge suggestions.
  IdentityGraph get identityGraph;

  /// Best-effort avatar for an arbitrary user — status-ring senders, group
  /// members — who may not be a chat peer with a handle of their own. May
  /// kick off a profile fetch and return null meanwhile; callers rebuild
  /// when the repository does.
  String? avatarUrlFor(String userId, {String? roomId}) => null;

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

  /// Proposes a calendar entry to the conversation.
  ///
  /// Weft peers get the negotiation UI; everyone else sees the readable text
  /// and, in unencrypted rooms, the `.ics` file the entry rides in on.
  Future<void> sendCalendarInvite(
    String chatId, {
    required String title,
    required DateTime start,
    DateTime? end,
    ChatNetwork? via,
  });

  /// Moves an already-sent proposal to a new time, as an `m.replace` edit so
  /// every other client — and every bridge — shows it the way they show any
  /// edited message.
  Future<void> editCalendarInvite(
    String roomId,
    String inviteEventId, {
    required String title,
    required DateTime start,
    DateTime? end,
  }) async {}

  /// Where the other side has read up to, one entry per source room that has
  /// a peer receipt at all: the event it points at and when it was sent.
  List<({String roomId, String eventId, DateTime at})> peerReadUpTo(
    String chatId,
  ) => const [];

  /// Address-book names by phone digits, applied on top of whatever the
  /// bridges call people. Set by the app when the user opts in; an empty map
  /// turns the preference back off.
  void setContactNameOverrides(Map<String, String> namesByPhoneDigits) {}

  /// Opens (or finds) a direct conversation with a Matrix user and returns
  /// its chat id, or null when this repository cannot create rooms.
  Future<String?> createDirectChat(String matrixUserId) async => null;

  /// Creates a named group with [inviteMatrixIds] and returns its chat id.
  Future<String?> createGroupChat(
    String name,
    List<String> inviteMatrixIds,
  ) async => null;

  /// Asks [network]'s bridge bot to open a portal with [identifier] — a
  /// phone number, usually. The portal arrives by sync; true means the ask
  /// was sent, not that the chat exists yet.
  Future<bool> startBridgeChat(ChatNetwork network, String identifier) async =>
      false;

  /// Display names of the people typing in [chatId] right now, the local
  /// user excluded. Bridges relay the remote network's typing state as the
  /// ghost typing, so this is WhatsApp's "typing…" too.
  List<String> typingIn(String chatId) => const [];

  /// Tells the conversation the local user is (or stopped) typing, on the
  /// leg a message would ride.
  Future<void> setTyping(String chatId, {required bool typing}) async {}

  /// The DM partner's presence, when the homeserver (and, for a bridged
  /// contact, the bridge) shares it. Null for groups and unknown peers.
  ({bool online, DateTime? lastActiveAt})? presenceFor(String chatId) => null;

  /// Answers [inviteEventId]'s calendar invitation.
  Future<void> respondCalendarInvite(
    String roomId,
    String inviteEventId, {
    required CalendarReply reply,
    DateTime? proposedStart,
  });

  /// Starts an MSC3381 poll in the conversation.
  Future<void> createPoll(
    String chatId, {
    required String question,
    required List<String> options,
    ChatNetwork? via,
  });

  /// Casts (or changes) the local user's vote on [startEventId]'s poll.
  ///
  /// [roomId] names the leg the poll lives on — a response referencing an
  /// event the target room never saw is a vote nobody counts.
  Future<void> votePoll(
    String roomId,
    String startEventId,
    Set<String> answerIds,
  );

  /// Sends the user's position as an `m.location` event.
  ///
  /// Bridges translate it into the network's own location message, which is
  /// why it is an event of its own rather than a text with a maps link.
  Future<void> sendLocation(
    String chatId, {
    required double latitude,
    required double longitude,
    ChatNetwork? via,
  });

  /// Sends [body] as a rich reply to [replyToEventId].
  ///
  /// The reply rides the leg its *target* lives on, not the chat's send
  /// network: `m.in_reply_to` names an event id, and an event id that is not in
  /// the room the reply lands in is a quote every client in that room — Weft
  /// included — renders as a dangling reference to nothing. [via] therefore
  /// chooses the room only when the target cannot be located at all, which is
  /// the case a fallback exists for rather than the normal path.
  Future<void> sendReply(
    String chatId,
    String body, {
    required String replyToEventId,
    ChatNetwork? via,
  });

  /// Adds the local user's [key] reaction to [eventId].
  ///
  /// Routed to the source room the target event actually lives in, for the same
  /// reason as [sendReply] and more sharply: an annotation sent to a merged
  /// chat's default send network points at an event that room has never heard
  /// of, so the homeserver accepts it and nobody — including the sender — ever
  /// sees a chip.
  Future<void> react(String chatId, String eventId, String key);

  /// Removes the local user's reaction by redacting their own annotation.
  ///
  /// Takes the *annotation's* event id, not the message's: un-reacting is a
  /// redaction of the event the reaction is, and `ReactionTally.localEventId`
  /// carries it for exactly this call. Asking the server for "my reaction with
  /// this key" instead would be a round trip racing the user's second tap.
  Future<void> unreact(String chatId, String reactionEventId);

  /// Replaces [eventId]'s body with [newBody] via `m.replace`.
  ///
  /// Only the original sender's own messages can be edited — the homeserver
  /// will accept a replacement of someone else's event and every well-behaved
  /// client will then ignore it, so the caller checks `isOwn` before offering
  /// the action.
  Future<void> editMessage(String chatId, String eventId, String newBody);

  /// Redacts [eventId]: deletes it for everyone, as far as the server is
  /// concerned. Irreversible, which is why the caller confirms first.
  Future<void> redact(String chatId, String eventId);

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

  /// Where a message's attachment can be fetched from directly, or null when
  /// there is no such place.
  ///
  /// The complement of [attachmentBytes], and deliberately allowed to answer
  /// "nowhere": an *encrypted* attachment's mxc URI serves ciphertext, so a
  /// caller that fetched it would write an unopenable file to the user's disk
  /// with nothing to say it had gone wrong. Null is therefore the correct answer
  /// for every encrypted room, for a redacted or unmapped event, and for demo
  /// mode — and the contract is that a null sends the caller to
  /// [attachmentBytes], which is the one path that works for both room types.
  ///
  /// It exists at all because [attachmentBytes] returns a `Uint8List`: holding a
  /// 200 MB video in memory to write it straight back out is the difference
  /// between saving a film and being killed by the OS for it. A URL can instead
  /// be handed to the background download service, which streams it to disk
  /// outside the app.
  Future<AttachmentLocation?> attachmentLocation(String roomId, String eventId);

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
  /// [durationMs] rides along for the same reason: only the recorder knows it
  /// without decoding the file, and the bubble draws it before download.
  Future<void> sendAttachment(
    String chatId,
    AttachmentSource source, {
    ChatNetwork? via,
    bool isVoiceNote = false,
    int? durationMs,
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

/// A fetchable address for one attachment, with whatever it takes to be let in.
///
/// [headers] is not optional decoration. Matrix v1.11 moved media behind
/// `Authorization: Bearer`, so on any current homeserver the URL alone answers
/// 401 — and the two travel together here precisely so a caller cannot hold one
/// without the other.
class AttachmentLocation {
  const AttachmentLocation({required this.url, this.headers = const {}});

  final Uri url;
  final Map<String, String> headers;

  @override
  String toString() => 'AttachmentLocation($url)';
}

/// Thrown by [ChatRepository.sendAttachment] for a file that will not be sent.
///
/// A rejection is not a failure to be retried — the file is empty, or nameless,
/// or larger than the homeserver accepts, and none of those change by trying
/// again. It therefore never becomes an [UploadTask]: there is nothing for the
/// timeline to show progress for, and a bubble the user could only dismiss would
/// be worse than a message on the composer. [message] is already user-facing and
/// is shown as-is.
class AttachmentRejectedException implements Exception {
  const AttachmentRejectedException(this.rejection);

  final UploadRejection rejection;

  UploadRejectionReason get reason => rejection.reason;

  /// Plain language, fit to put in front of the user unchanged.
  String get message => rejection.message;

  @override
  String toString() => 'AttachmentRejectedException: $message';
}

/// Which of a chat's rooms an outgoing message rides.
///
/// The one resolution both repositories and both send paths share: an explicit
/// [via] wins, then the chat's own [Chat.sendNetwork] (an explicit user choice,
/// else the network of the last inbound message), and a chat that has no source
/// on the chosen network falls back to its first — a merged conversation must
/// still send somewhere when the preferred leg has gone away.
ChatSource sendSourceFor(Chat chat, {ChatNetwork? via}) {
  if (chat.sources.isEmpty) {
    throw StateError('Chat ${chat.id} has no rooms to send to');
  }
  final network = via ?? chat.sendNetwork;
  if (network == null) return chat.sources.first;
  return chat.sourceFor(network) ?? chat.sources.first;
}

/// The uploads in [tasks] whose events may be sent now, in enqueue order.
///
/// `UploadQueue` promises only that uploads *start* in order; two photos
/// uploaded concurrently finish in whatever order the network decides, and
/// sending each event the moment its bytes land would put a twenty-photo share
/// into the room shuffled. Emitting them in order is the sender's job, and this
/// is that rule as a value: everything at the head of the queue that has
/// finished uploading may go, and the first task still in flight stops the line.
///
/// Two deliberate exceptions:
/// - A failed or cancelled task never produces an event, so it is skipped
///   rather than blocking the photos behind it forever.
/// - [blocked] holds tasks whose *event* send already failed. They keep their
///   uri and key material, so they can be re-sent without re-uploading, but they
///   must not be retried in a loop while the rest of the batch waits.
///
/// A task the user retries by hand therefore loses its place in line, which is
/// the honest trade: the alternative is stalling everything picked after it
/// behind a file the server has already refused once.
List<UploadTask> dispatchableUploads(
  List<UploadTask> tasks, {
  Set<String> blocked = const {},
}) {
  final out = <UploadTask>[];
  for (final task in tasks) {
    if (task.state == UploadState.sent) {
      if (!blocked.contains(task.id)) out.add(task);
      continue;
    }
    if (task.isTerminal) continue;
    break;
  }
  return out;
}

/// [ChatRepository.watchUploads] over an [UploadQueue], with [filter] deciding
/// which of its tasks belong to the chat being watched.
///
/// The subscription is opened *before* the current snapshot is delivered, and
/// that ordering is the whole reason this is a function rather than an
/// `async*`. A generator subscribes to what it delegates to only after its
/// first value has been taken, and a share started in that gap — which is
/// exactly what happens when the composer opens the picker and the watcher in
/// the same frame — would never emit its `queued` state at all. The bubble
/// would then appear mid-upload, or not until the first progress report.
Stream<List<UploadTask>> watchUploadQueue(
  UploadQueue queue,
  List<UploadTask> Function(List<UploadTask> tasks) filter,
) {
  late final StreamController<List<UploadTask>> controller;
  StreamSubscription<List<UploadTask>>? subscription;

  controller = StreamController<List<UploadTask>>(
    onListen: () {
      subscription = queue.updates.listen(
        (tasks) => controller.add(filter(tasks)),
        onDone: controller.close,
      );
      controller.add(filter(queue.tasks));
    },
    onCancel: () => subscription?.cancel(),
  );
  return controller.stream;
}

/// The timeline bubble for an upload that has no event yet.
///
/// An in-flight upload is not a message: it has no event id, the homeserver has
/// never heard of it, and it may yet fail. It still has to *render* as one, so
/// the attachment appears in the thread the instant the user picks it rather
/// than a minute later when the bytes land. This builds that stand-in from the
/// task, with a synthetic `local:` event id that cannot collide with a real one
/// and [DeliveryState.sending] until the queue says otherwise.
///
/// [attachmentUrl] is deliberately left null: it is how the timeline asks the
/// repository for bytes by event id, and there is no event to ask about. The
/// progress bubble draws from the [UploadTask] itself.
///
/// The default [timestamp] is `clock.now()` rather than `DateTime.now()` for
/// one reason: a golden of an in-flight upload otherwise carries the wall-clock
/// minute it was regenerated in, and fails every run thereafter. Production
/// never installs a clock, so the two are the same call.
WeftMessage uploadEchoMessage(
  UploadTask task, {
  required ChatNetwork network,
  required String senderId,
  String senderName = 'You',
  DateTime? timestamp,
}) {
  final plan = task.plan;
  return WeftMessage(
    eventId: 'local:${task.id}',
    roomId: task.roomId,
    network: network,
    senderId: senderId,
    senderName: senderName,
    timestamp: timestamp ?? clock.now(),
    kind: plan.kind,
    isOwn: true,
    body: plan.filename,
    // Failed and cancelled both read as failed here: the distinction matters to
    // the retry button, which reads the task, not to the bubble's tick.
    deliveryState: task.isTerminal && task.state != UploadState.sent
        ? DeliveryState.failed
        : DeliveryState.sending,
    durationMs: plan.durationMs,
    mediaWidth: plan.dimensions?.width,
    mediaHeight: plan.dimensions?.height,
    mediaSizeBytes: plan.sizeBytes,
  );
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
