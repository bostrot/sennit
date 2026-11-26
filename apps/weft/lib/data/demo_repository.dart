import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_richtext/weft_richtext.dart';

import 'chat_repository.dart';

/// How long the fake transport waits between progress reports.
///
/// Slow enough that the progress bubble is visibly a progress bubble when
/// someone sends a photo in demo mode, and injectable so a test does not spend
/// a real second watching it.
const Duration kDemoUploadTick = Duration(milliseconds: 140);

/// How many times a demo upload reports progress before finishing.
const int kDemoUploadSteps = 6;

/// The size limit demo mode pretends its homeserver advertises.
///
/// A real number rather than 0 ("unknown"), so the rejection path is reachable
/// without a server: dropping a 200 MB video onto a demo chat produces the same
/// plain-language refusal a real one would.
const int kDemoMaxUploadBytes = 100 * 1024 * 1024;

/// An in-memory [ChatRepository] with a realistic multi-network inbox.
///
/// This exists so the UI, the merge behaviour and the golden tests can all be
/// exercised without a homeserver. It is wired in only when the app runs with
/// `--dart-define=WEFT_DEMO=true`; the Matrix-backed repository is the default
/// path once M1 lands.
class DemoChatRepository implements ChatRepository {
  @override
  Future<void> retryFailedSend(String roomId, String eventId) async {}

  @override
  Future<void> discardFailedSend(String roomId, String eventId) async {}

  @override
  Future<void> markUnread(String chatId) async {}

  @override
  Future<void> markUnreadFrom(
    String chatId,
    String roomId,
    String eventId, {
    String? before,
    int count = 1,
  }) async {}

  @override
  Future<String?> createDirectChat(String matrixUserId) async => null;

  @override
  Future<String?> createGroupChat(
    String name,
    List<String> inviteMatrixIds,
  ) async => null;

  @override
  Future<bool> startBridgeChat(ChatNetwork network, String identifier) async =>
      false;

  @override
  List<String> typingIn(String chatId) => const [];

  @override
  Future<void> setTyping(String chatId, {required bool typing}) async {}

  @override
  ({bool online, DateTime? lastActiveAt})? presenceFor(String chatId) => null;

  @override
  Future<void> editCalendarInvite(
    String roomId,
    String inviteEventId, {
    required String title,
    required DateTime start,
    DateTime? end,
  }) async {}

  @override
  List<({String roomId, String userId, String eventId, DateTime at})>
  peerReadUpTo(String chatId) => const [];

  @override
  List<({String roomId, String eventId, DateTime at})> ownReadUpTo(
    String chatId,
  ) {
    // Demo mode has no receipts of its own, so the honest answer is the newest
    // message the fixture user sent: everything up to their own last word has
    // plainly been read, and nothing after it is claimed either way. Empty
    // would read as "no marker", which the thread grouping treats as nothing
    // unread — and then no demo thread ever shows a badge to look at.
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return const [];

    final markers = <({String roomId, String eventId, DateTime at})>[];
    for (final source in chat.sources) {
      WeftMessage? newest;
      for (final message in historyFor(source, chat.title)) {
        if (!message.isOwn) continue;
        if (newest == null || message.timestamp.isAfter(newest.timestamp)) {
          newest = message;
        }
      }
      if (newest != null) {
        markers.add((
          roomId: source.roomId,
          eventId: newest.eventId,
          at: newest.timestamp,
        ));
      }
    }
    return markers;
  }

  @override
  Future<ChatRequestState?> answerChatRequest(
    String chatId,
    ChatRequestAction action,
  ) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0) return null;
    final current = _chats[index].request;
    if (!isPendingRequest(current)) return current;

    final next = applyChatRequestAction(current!, action);
    // Accepting clears the flag outright; the other two leave it set so the
    // inbox can take the row out. Demo mode has no room to leave and no ignore
    // list to write to — [planChatRequest] is what a real repository consults,
    // and asserting the plan is `weft_domain`'s job, not this one's.
    _chats = [..._chats]
      ..[index] = _chats[index].copyWith(
        request: next == ChatRequestState.accepted ? null : next,
      );
    _controller.add(_chats);
    return next;
  }

  @override
  void setDeviceContacts(ContactBook contacts) {}

  @override
  String? avatarUrlFor(String userId, {String? roomId}) => null;

  @override
  int get timelineEpoch => 0;

  @override
  Set<String> get serviceChatIds => const {};

  DemoChatRepository({Duration uploadTick = kDemoUploadTick})
    : _uploadTick = uploadTick {
    _graph = IdentityGraph(handles: _handles, idFactory: _ids());
    // Anna is the showcase: the same person reachable three ways.
    _graph.merge('anna_wa', 'anna_sg');
    _graph.merge('anna_sg', 'anna_tg');
    _chats = _buildChats();
  }

  static String Function() _ids() {
    var n = 0;
    return () => 'contact_${n++}';
  }

  late final IdentityGraph _graph;
  late List<Chat> _chats;
  final _controller = StreamController<List<Chat>>.broadcast();

  final Duration _uploadTick;

  /// Attachments sent in this session, per room, so a demo photo is still in
  /// the thread when the user backs out and opens it again.
  final Map<String, List<WeftMessage>> _localMessages = {};

  /// The bytes of attachments sent in this session, keyed first by upload task
  /// id and then — once the event exists — by event id.
  ///
  /// See [attachmentBytes] for why these are kept and why nothing else is.
  final Map<String, Uint8List> _pendingBytes = {};
  final Map<String, Uint8List> _sentBytes = {};

  /// Relations applied to the fixtures, keyed by the event they are about.
  ///
  /// The fixtures are rebuilt from scratch on every [timelineFor], so a
  /// reaction cannot be written into a message the way a real timeline holds
  /// one — it is kept beside them and folded back in by [_withRelations] each
  /// time the history is asked for. That is also what makes the demo path worth
  /// having here: react, edit, delete and reply all run the *real* aggregation
  /// out of `weft_richtext`, so what a bubble does with no homeserver is what
  /// it does with one.
  final Map<String, List<ReactionEvent>> _reactions = {};
  final Map<String, List<EditEvent>> _edits = {};
  final Set<String> _redacted = {};

  /// Events dropped from this device — what a retention sweep does to a
  /// message it has no standing to redact. Filtered out of [historyFor]
  /// entirely rather than folded in by [_withRelations]: a forgotten message is
  /// not a message in a different state, it is a message that is not there.
  final Set<String> _forgotten = {};

  /// The instant every demo fixture is dated against.
  ///
  /// Public so a golden can put the *clock* at the same instant: a timestamp
  /// fixed against a moving now produces "16:40" today and "8/15/2026" next
  /// week, which is a golden that fails on a Tuesday.
  static final DateTime fixtureNow = DateTime(2026, 8, 15, 16, 42);

  static final DateTime _now = fixtureNow;

  /// The local user, as every demo fixture spells them.
  static const String _localUserId = '@me:example.org';

  @override
  IdentityGraph get identityGraph => _graph;

  @override
  List<ChatNetwork> get availableNetworks => const [
    ChatNetwork.whatsapp,
    ChatNetwork.signal,
    ChatNetwork.telegram,
    ChatNetwork.instagram,
    ChatNetwork.discord,
    ChatNetwork.slack,
    ChatNetwork.matrix,
  ];

  @override
  Stream<List<Chat>> watchChats() async* {
    yield _chats;
    yield* _controller.stream;
  }

  @override
  Chat? chatForRoom(String roomId) =>
      _chats.where((c) => c.roomIds.contains(roomId)).firstOrNull;

  @override
  Future<MergedTimeline> timelineFor(String chatId) async {
    // Same failure contract as the Matrix repository: an unknown id is an
    // ArgumentError, not a bare `firstWhere` StateError, so callers can render
    // one "not in your inbox" state regardless of which backend they're on.
    final chat = _chats.firstWhere(
      (c) => c.id == chatId,
      orElse: () => throw ArgumentError.value(chatId, 'chatId', 'Unknown chat'),
    );
    return MergedTimeline(
      sources: [
        for (final source in chat.sources)
          _RelationsTimelineSource(
            roomId: source.roomId,
            network: source.network,
            pageSize: 12,
            history: historyFor(source, chat.title),
            fold: _withRelations,
            sessionMessages: (roomId) =>
                _localMessages[roomId] ?? const <WeftMessage>[],
          ),
      ],
    );
  }

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0) return;
    final chat = _chats[index];
    final source = sendSourceFor(chat, via: via);
    final network = source.network;

    _chats = [..._chats]
      ..[index] = chat.copyWith(
        lastMessage: WeftMessage(
          eventId: '\$local_${DateTime.now().microsecondsSinceEpoch}',
          roomId: source.roomId,
          network: network,
          senderId: '@me:example.org',
          senderName: 'You',
          timestamp: DateTime.now(),
          kind: MessageKind.text,
          isOwn: true,
          body: body,
          deliveryState: DeliveryState.sent,
        ),
        unreadCount: 0,
      );
    _controller.add(_chats);
  }

  @override
  Future<void> sendCalendarInvite(
    String chatId, {
    required String title,
    required DateTime start,
    DateTime? end,
    ChatNetwork? via,
  }) => send(chatId, '📅 $title', via: via);

  @override
  Future<void> respondCalendarInvite(
    String roomId,
    String inviteEventId, {
    required CalendarReply reply,
    DateTime? proposedStart,
  }) async {}

  @override
  Future<void> createPoll(
    String chatId, {
    required String question,
    required List<String> options,
    ChatNetwork? via,
  }) => send(chatId, 'Poll: $question', via: via);

  @override
  Future<void> votePoll(
    String roomId,
    String startEventId,
    Set<String> answerIds,
  ) async {}

  @override
  Future<void> sendLocation(
    String chatId, {
    required double latitude,
    required double longitude,
    ChatNetwork? via,
  }) => send(chatId, 'Location: geo:$latitude,$longitude', via: via);

  @override
  Future<void> sendReply(
    String chatId,
    String body, {
    required String replyToEventId,
    ChatNetwork? via,
  }) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0) return;
    final chat = _chats[index];

    // The leg the target lives on, exactly as the Matrix repository resolves
    // it: a reply is an answer to one event, and the event is in one room.
    final target = _messageIn(chatId, replyToEventId);
    final roomId = target?.roomId ?? sendSourceFor(chat, via: via).roomId;
    final network = chat.sources
        .firstWhere(
          (s) => s.roomId == roomId,
          orElse: () => sendSourceFor(chat, via: via),
        )
        .network;

    final message = WeftMessage(
      eventId: '\$local_${DateTime.now().microsecondsSinceEpoch}',
      roomId: roomId,
      network: network,
      senderId: _localUserId,
      senderName: 'You',
      timestamp: DateTime.now(),
      kind: MessageKind.text,
      isOwn: true,
      body: body,
      replyToEventId: replyToEventId,
      deliveryState: DeliveryState.sent,
    );

    // Unlike [send], which only moves the inbox preview, a reply is appended to
    // the room's own history: a reply chip with nothing above it to point at is
    // the one thing this path exists to demonstrate.
    _localMessages.putIfAbsent(roomId, () => []).add(message);
    _chats = [..._chats]
      ..[index] = chat.copyWith(lastMessage: message, unreadCount: 0);
    _controller.add(_chats);
  }

  @override
  Future<void> sendThreadReply(
    String chatId,
    String body, {
    required String threadRootId,
    String? replyToEventId,
    String? threadLatestEventId,
  }) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0) return;
    final chat = _chats[index];

    // The root's room, never the chat's send network. A thread relation
    // pointing at an event id the destination room has never heard of is a
    // thread nobody in that room can open — the same rule replies and reactions
    // follow, and sharper here because the thread *is* the destination.
    final root = _messageIn(chatId, threadRootId);
    if (root == null) {
      throw StateError(
        'Cannot reply in thread $threadRootId: it is not in $chatId',
      );
    }
    final network = chat.sources
        .firstWhere(
          (s) => s.roomId == root.roomId,
          orElse: () => sendSourceFor(chat),
        )
        .network;

    final message = WeftMessage(
      eventId: '\$local_${DateTime.now().microsecondsSinceEpoch}',
      roomId: root.roomId,
      network: network,
      senderId: _localUserId,
      senderName: 'You',
      timestamp: DateTime.now(),
      kind: MessageKind.text,
      isOwn: true,
      body: body,
      // Only an explicit answer carries a visible quote. The spec's fallback is
      // for clients that cannot render threads, and demo mode's timeline can —
      // writing it here would show every thread message quoting the one above.
      replyToEventId: replyToEventId,
      threadRootId: threadRootId,
      threadName: root.threadName,
      deliveryState: DeliveryState.sent,
    );

    _localMessages.putIfAbsent(root.roomId, () => []).add(message);
    _chats = [..._chats]
      ..[index] = chat.copyWith(lastMessage: message, unreadCount: 0);
    _controller.add(_chats);
  }

  @override
  Future<void> react(String chatId, String eventId, String key) async {
    final target = _messageIn(chatId, eventId);
    if (target == null) {
      throw StateError('Cannot react to $eventId: it is not in $chatId');
    }
    final annotations = _reactions.putIfAbsent(eventId, () => []);
    // A second annotation with the same key would be one the tally dedupes
    // away and `unreact` cannot reach: one redaction, and the chip comes
    // straight back looking like the tap did nothing.
    final normalised = normaliseReactionKey(key);
    final already = annotations.any(
      (r) =>
          r.senderId == _localUserId &&
          normaliseReactionKey(r.key) == normalised,
    );
    if (already) return;

    annotations.add(
      ReactionEvent(
        eventId: '\$demo_reaction_${_nextRelationId++}',
        // The target's room, never the chat's send network — the rule the
        // Matrix path is written around, kept here so a test can see it
        // without a homeserver.
        roomId: target.roomId,
        senderId: _localUserId,
        targetEventId: eventId,
        key: key,
        timestamp: DateTime.now(),
      ),
    );
    _controller.add(_chats);
  }

  @override
  Future<void> unreact(String chatId, String reactionEventId) async {
    for (final annotations in _reactions.values) {
      annotations.removeWhere((r) => r.eventId == reactionEventId);
    }
    _reactions.removeWhere((_, annotations) => annotations.isEmpty);
    _controller.add(_chats);
  }

  @override
  Future<void> editMessage(
    String chatId,
    String eventId,
    String newBody,
  ) async {
    final target = _messageIn(chatId, eventId);
    if (target == null) {
      throw StateError('Cannot edit $eventId: it is not in $chatId');
    }
    _edits
        .putIfAbsent(eventId, () => [])
        .add(
          EditEvent(
            eventId: '\$demo_edit_${_nextRelationId++}',
            roomId: target.roomId,
            // The original sender, because `applyEdits` rejects an edit from
            // anyone else — and demo mode should not be the one place where
            // that rule appears not to hold.
            senderId: target.senderId,
            targetEventId: eventId,
            body: newBody,
            timestamp: DateTime.now(),
          ),
        );
    _controller.add(_chats);
  }

  @override
  Future<void> redact(String chatId, String eventId) async {
    _redacted.add(eventId);
    _controller.add(_chats);
  }

  @override
  Future<void> forgetLocally(String roomId, String eventId) async {
    _forgotten.add(eventId);
    _controller.add(_chats);
  }

  /// The message [eventId] names, if it is in one of [chatId]'s rooms.
  ///
  /// Fixtures are regenerated per call, so this asks the same builder the
  /// timeline does rather than keeping a second index that could disagree.
  /// Relations are deliberately *not* folded in here: the callers want the
  /// event's room and its original sender, and neither of those is something an
  /// edit or a reaction can change.
  WeftMessage? _messageIn(String chatId, String eventId) {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return null;
    for (final source in chat.sources) {
      for (final message in historyFor(source, chat.title)) {
        if (message.eventId == eventId) return message;
      }
    }
    return null;
  }

  int _nextRelationId = 0;

  /// Folds the session's relations back onto a fixture message.
  ///
  /// Order matters: a redacted message has no history and no tally, and an
  /// edit's own timestamp is what an "edited 14:02" indicator reads.
  WeftMessage _withRelations(WeftMessage message) {
    if (_redacted.contains(message.eventId)) {
      return message.copyWith(redacted: true, body: '');
    }

    var out = message;
    final edits = _edits[message.eventId];
    if (edits != null && edits.isNotEmpty) {
      final resolution = applyEdits(edits, out);
      out = resolution.message.copyWith(editHistory: resolution.history);
    }

    final annotations = _reactions[message.eventId];
    if (annotations != null && annotations.isNotEmpty) {
      out = out.copyWith(
        reactions: aggregateReactions(
          events: annotations,
          // Nothing in demo mode reacts from two handles at once, so identity
          // is identity — the dedupe itself is tested where it lives.
          resolveSender: senderIsIdentity,
          localUserId: _localUserId,
        ),
      );
    }
    return out;
  }

  @override
  Future<void> mergeHandles(String handleIdA, String handleIdB) async {
    _graph.merge(handleIdA, handleIdB);
  }

  @override
  Future<void> unmergeHandle(String handleId) async {
    _graph.unmerge(handleId);
  }

  @override
  Future<void> rejectSuggestion(String handleIdA, String handleIdB) async {
    _graph.reject(handleIdA, handleIdB);
  }

  @override
  Future<void> setArchived(String chatId, {required bool archived}) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0) return;
    _chats = [..._chats]..[index] = _chats[index].copyWith(archived: archived);
    _controller.add(_chats);
  }

  @override
  Future<void> setMuted(String chatId, {required bool muted}) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0) return;
    _chats = [..._chats]..[index] = _chats[index].copyWith(muted: muted);
    _controller.add(_chats);
  }

  @override
  Future<void> deleteChat(String chatId) async {
    _chats = _chats.where((c) => c.id != chatId).toList();
    _controller.add(_chats);
  }

  /// The bytes of a photo *this session sent*, and null for everything else.
  ///
  /// Demo mode has no homeserver, so nothing in the fixture history has bytes
  /// to fetch and null is the honest answer — it routes the bubble down the same
  /// placeholder branch an undecryptable attachment takes, and no pixels are
  /// invented for a message that never carried any.
  ///
  /// A file the user just picked is the one exception, because those bytes
  /// genuinely exist: [sendAttachment] already holds the slice it handed to the
  /// transport. Returning it is what makes the send loop demonstrable end to end
  /// without credentials — pick a photo, watch it upload, see it settle, open it
  /// full screen — which is the whole reason demo mode exists.
  ///
  /// Only kept when the slice **is** the whole file. `AttachmentSource.header`
  /// is capped at 64 KiB, and half a JPEG decodes to a grey band or to nothing
  /// depending on the platform codec: a preview that looks like the file is
  /// corrupt is worse than no preview, so a larger file keeps the placeholder.
  /// The same cap is why this cannot grow without bound.
  ///
  /// [thumbnail] is ignored: a file small enough to be kept here is one
  /// `ThumbnailSpec` would suppress a preview for anyway — a 40 KB photo is its
  /// own thumbnail.
  @override
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  }) async => _sentBytes[eventId];

  /// Always null: demo mode has no homeserver, so there is no URL to fetch from
  /// even for the photo [attachmentBytes] can still hand back. That is the
  /// honest answer rather than a placeholder, and it routes the viewer down its
  /// "no URL, ask for the bytes" branch — which is exactly the branch an
  /// encrypted attachment takes.
  @override
  Future<AttachmentLocation?> attachmentLocation(
    String roomId,
    String eventId,
  ) async => null;

  // --------------------------------------------------------------- send path
  //
  // Demo mode runs the *real* `UploadQueue` over a fake transport rather than
  // faking the queue: the concurrency cap, the retry budget, the progress
  // stream and the ordered event sends are then exactly the ones the Matrix
  // path uses, so a bubble that looks right here looks right there. Only the
  // bytes are pretend.

  UploadQueue? _queue;
  StreamSubscription<List<UploadTask>>? _uploadSub;
  final Set<String> _dispatching = {};
  int _nextUploadId = 0;

  UploadQueue get _uploads {
    final existing = _queue;
    if (existing != null) return existing;

    final queue = UploadQueue(
      transport: _DemoUploadTransport(tick: _uploadTick),
    );
    _uploadSub = queue.updates.listen(_onUploadsChanged);
    return _queue = queue;
  }

  @override
  Future<void> sendAttachment(
    String chatId,
    AttachmentSource source, {
    ChatNetwork? via,
    bool isVoiceNote = false,
    int? durationMs,
    String? caption,
  }) async {
    // An unknown id is an ArgumentError here rather than the silent return the
    // other demo mutators take: losing a file is not the same as failing to
    // mute a chat that has gone.
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0) {
      throw ArgumentError.value(chatId, 'chatId', 'Unknown chat');
    }
    final chatSource = sendSourceFor(_chats[index], via: via);

    final decision = planUpload(
      source,
      // No demo room is encrypted: the fake transport has no key material to
      // produce, and `toEventContent` would rightly refuse the mismatch.
      encrypted: false,
      maxUploadBytes: kDemoMaxUploadBytes,
      isVoiceNote: isVoiceNote,
      durationMs: durationMs,
      caption: caption,
    );
    if (decision is UploadRejection) {
      throw AttachmentRejectedException(decision);
    }

    final id = 'upload-${_nextUploadId++}';
    // Kept only when the slice is the entire file — see [attachmentBytes].
    if (source.header.length == source.sizeBytes) {
      _pendingBytes[id] = source.header;
    }

    _uploads.enqueue(
      decision as UploadPlan,
      roomId: chatSource.roomId,
      id: id,
      // The header slice, which demo mode already holds, stands in for the file:
      // reading the real thing would put I/O in the one repository that exists
      // so the UI can be driven without any.
      loadPayload: () async => UploadPayload(bytes: source.header),
    );
  }

  void _onUploadsChanged(List<UploadTask> tasks) {
    for (final roomId in {for (final task in tasks) task.roomId}) {
      _dispatchRoom(roomId);
    }
  }

  /// Turns each finished upload into a message, oldest first — the same
  /// ordering promise the Matrix repository keeps.
  void _dispatchRoom(String roomId) {
    if (!_dispatching.add(roomId)) return;
    try {
      for (final task in dispatchableUploads(_uploads.tasksFor(roomId))) {
        _appendSentAttachment(task);
        _uploads.remove(task.id);
      }
    } finally {
      _dispatching.remove(roomId);
    }
  }

  void _appendSentAttachment(UploadTask task) {
    final index = _chats.indexWhere((c) => c.roomIds.contains(task.roomId));
    if (index < 0) return;

    final chat = _chats[index];
    final network = chat.sources
        .firstWhere((s) => s.roomId == task.roomId)
        .network;
    final plan = task.plan;
    final eventId = '\$demo_${task.id}';
    final message = WeftMessage(
      eventId: eventId,
      roomId: task.roomId,
      network: network,
      senderId: '@me:example.org',
      senderName: 'You',
      timestamp: DateTime.now(),
      kind: plan.kind,
      isOwn: true,
      // The same split `toEventContent` writes and `mapEvent` reads back: the
      // caption is the body and the name moves aside, or the name is the body
      // and there is no separate name at all. Fabricating it any other way
      // would make demo mode the one place a caption renders differently.
      body: plan.caption ?? plan.filename,
      deliveryState: DeliveryState.sent,
      // The event id, exactly as `mapEvent` writes it: the field is a flag
      // saying "there is a file here", and the bytes are fetched by event id —
      // which is why the slice moves to the same key here.
      attachmentUrl: eventId,
      attachmentName: plan.caption == null ? null : plan.filename,
      durationMs: plan.durationMs,
      mediaWidth: plan.dimensions?.width,
      mediaHeight: plan.dimensions?.height,
      mediaSizeBytes: plan.sizeBytes,
    );

    final bytes = _pendingBytes.remove(task.id);
    if (bytes != null) _sentBytes[eventId] = bytes;

    _localMessages.putIfAbsent(task.roomId, () => []).add(message);
    _chats = [..._chats]
      ..[index] = chat.copyWith(lastMessage: message, unreadCount: 0);
    _controller.add(_chats);
  }

  @override
  Stream<List<UploadTask>> watchUploads(String chatId) =>
      watchUploadQueue(_uploads, (tasks) => _uploadsForChat(chatId, tasks));

  List<UploadTask> _uploadsForChat(String chatId, List<UploadTask> tasks) {
    final index = _chats.indexWhere((c) => c.id == chatId);
    // An unmerged chat's id is its room id, which is what keeps this answering
    // for a chat that is not in the fixture list.
    final rooms = index < 0 ? [chatId] : _chats[index].roomIds;
    return [
      for (final task in tasks)
        if (rooms.contains(task.roomId)) task,
    ];
  }

  @override
  Future<void> retryUpload(String taskId) async => _uploads.retry(taskId);

  @override
  Future<void> cancelUpload(String taskId) async {
    // A cancelled upload never becomes an event, so its slice has nothing left
    // to be keyed by.
    _pendingBytes.remove(taskId);
    _uploads.cancel(taskId);
  }

  /// Releases the queue's stream and anything still in flight.
  Future<void> dispose() async {
    await _uploadSub?.cancel();
    await _queue?.dispose();
    await _controller.close();
  }

  @override
  void indexMessages(
    String chatId,
    List<WeftMessage> messages, {
    String chatTitle = '',
  }) {
    // Demo mode has no search index.
  }

  @override
  Future<void> setSendNetwork(String chatId, ChatNetwork network) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0) return;
    _chats = [..._chats]
      ..[index] = _chats[index].copyWith(preferredSendNetwork: network);
    _controller.add(_chats);
  }

  @override
  Future<void> markRead(String chatId) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0 || _chats[index].unreadCount == 0) return;
    _chats = [..._chats]..[index] = _chats[index].copyWith(unreadCount: 0);
    _controller.add(_chats);
  }

  // ---------------------------------------------------------------- fixtures

  static final List<NetworkHandle> _handles = [
    _handle('anna_wa', ChatNetwork.whatsapp, 'Anna Maven', '+4915112345678'),
    _handle('anna_sg', ChatNetwork.signal, 'Anna Maven', '+4915112345678'),
    _handle('anna_tg', ChatNetwork.telegram, 'Anna M.', '+4915112345678'),
    _handle('konrad_wa', ChatNetwork.whatsapp, 'Konrad Majewski', null),
    _handle('sofia_tg', ChatNetwork.telegram, 'Sofia Martinez', null),
    _handle('james_ig', ChatNetwork.instagram, 'Dr. James Anderson', null),
    _handle('isabella_tg', ChatNetwork.telegram, 'Isabella Garcia', null),
    _handle('david_wa', ChatNetwork.whatsapp, 'Prof. David Wilson', null),
    // Michael appears twice with the identical name — the exact signal a
    // suggestion needs since resemblance alone stopped opening one. The demo
    // scorer runs without auto-merge, so it stays a suggestion to exercise.
    // The hashes stay under 2^53, which is all the browser build's integers
    // can hold exactly; one bit apart either way.
    _handle(
      'michael_wa',
      ChatNetwork.whatsapp,
      'Michael Johnson',
      null,
      dHash: 0x000F0F0F0F0F0F0F,
    ),
    _handle(
      'michael_dc',
      ChatNetwork.discord,
      'Michael Johnson',
      null,
      dHash: 0x000F0F0F0F0F0F0E,
    ),
    _handle('alex_sl', ChatNetwork.slack, 'Alexandra Thompson', null),
    _handle('emma_sg', ChatNetwork.signal, 'Emma Robinson', null),
  ];

  static NetworkHandle _handle(
    String id,
    ChatNetwork network,
    String name,
    String? phone, {
    int? dHash,
  }) {
    return NetworkHandle(
      id: id,
      network: network,
      remoteId: phone ?? id,
      matrixUserId: '@${network.id}_$id:example.org',
      roomId: '!${id}_room:example.org',
      displayName: name,
      phoneE164: phone,
      avatarDHash: dHash,
    );
  }

  List<Chat> _buildChats() {
    return [
      Chat(
        id: 'merged:anna',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Anna Maven',
        contactId: _graph.contactIdOf('anna_wa'),
        sources: const [
          ChatSource(
            roomId: '!anna_wa_room:example.org',
            network: ChatNetwork.whatsapp,
          ),
          ChatSource(
            roomId: '!anna_sg_room:example.org',
            network: ChatNetwork.signal,
          ),
          ChatSource(
            roomId: '!anna_tg_room:example.org',
            network: ChatNetwork.telegram,
          ),
        ],
        unreadCount: 3,
        pinned: true,
        lastMessage: _msg(
          '!anna_sg_room:example.org',
          ChatNetwork.signal,
          'Anna Maven',
          'Can you send the clinical trial summary?',
          2,
        ),
      ),
      Chat(
        id: '!konrad_wa_room:example.org',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Konrad Majewski',
        sources: const [
          ChatSource(
            roomId: '!konrad_wa_room:example.org',
            network: ChatNetwork.whatsapp,
          ),
        ],
        unreadCount: 1,
        lastMessage: _msg(
          '!konrad_wa_room:example.org',
          ChatNetwork.whatsapp,
          'Konrad Majewski',
          'Hey, are we still on for Thursday?',
          14,
        ),
      ),
      Chat(
        id: '!sofia_tg_room:example.org',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Sofia Martinez',
        sources: const [
          ChatSource(
            roomId: '!sofia_tg_room:example.org',
            network: ChatNetwork.telegram,
          ),
        ],
        lastMessage: _msg(
          '!sofia_tg_room:example.org',
          ChatNetwork.telegram,
          'You',
          "Let me know when it's done",
          90,
          isOwn: true,
          delivery: DeliveryState.read,
        ),
      ),
      // A stranger, held out of the inbox until the user answers. One, not
      // several: the requests row exists to be noticed and a demo inbox with a
      // queue of them would misrepresent how often this actually happens.
      Chat(
        id: '!unknown_sg_room:example.org',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: '+1 555 0143',
        sources: const [
          ChatSource(
            roomId: '!unknown_sg_room:example.org',
            network: ChatNetwork.signal,
          ),
        ],
        request: ChatRequestState.pending,
        unreadCount: 1,
        lastMessage: _msg(
          '!unknown_sg_room:example.org',
          ChatNetwork.signal,
          '+1 555 0143',
          'Hi, is this the right number for Sam?',
          38,
        ),
      ),
      Chat(
        id: '!james_ig_room:example.org',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Dr. James Anderson',
        sources: const [
          ChatSource(
            roomId: '!james_ig_room:example.org',
            network: ChatNetwork.instagram,
          ),
        ],
        muted: true,
        lastMessage: _msg(
          '!james_ig_room:example.org',
          ChatNetwork.instagram,
          'Dr. James Anderson',
          'We have to talk about the results',
          1450,
        ),
      ),
      Chat(
        id: '!isabella_tg_room:example.org',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Isabella Garcia',
        sources: const [
          ChatSource(
            roomId: '!isabella_tg_room:example.org',
            network: ChatNetwork.telegram,
          ),
        ],
        unreadCount: 12,
        lastMessage: _msg(
          '!isabella_tg_room:example.org',
          ChatNetwork.telegram,
          'Isabella Garcia',
          'Hi! I have a short message to convey',
          2880,
        ),
      ),
      Chat(
        id: 'merged:michael',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Michael Johnson',
        sources: const [
          ChatSource(
            roomId: '!michael_wa_room:example.org',
            network: ChatNetwork.whatsapp,
          ),
          ChatSource(
            roomId: '!michael_dc_room:example.org',
            network: ChatNetwork.discord,
          ),
        ],
        lastMessage: _msg(
          '!michael_dc_room:example.org',
          ChatNetwork.discord,
          'Michael Johnson',
          "Here's a brief note for you",
          4320,
        ),
      ),
      Chat(
        id: '!david_wa_room:example.org',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Prof. David Wilson',
        sources: const [
          ChatSource(
            roomId: '!david_wa_room:example.org',
            network: ChatNetwork.whatsapp,
          ),
        ],
        lastMessage: _msg(
          '!david_wa_room:example.org',
          ChatNetwork.whatsapp,
          'Prof. David Wilson',
          'Greetings! Just a quick word from me',
          5760,
        ),
      ),
      Chat(
        id: '!alex_sl_room:example.org',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Alexandra Thompson',
        sources: const [
          ChatSource(
            roomId: '!alex_sl_room:example.org',
            network: ChatNetwork.slack,
          ),
        ],
        lastMessage: _msg(
          '!alex_sl_room:example.org',
          ChatNetwork.slack,
          'Alexandra Thompson',
          'Hey there! Just wanted to share a',
          7200,
        ),
      ),
      Chat(
        id: '!emma_sg_room:example.org',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Emma Robinson',
        sources: const [
          ChatSource(
            roomId: '!emma_sg_room:example.org',
            network: ChatNetwork.signal,
          ),
        ],
        lastMessage: _msg(
          '!emma_sg_room:example.org',
          ChatNetwork.signal,
          'Emma Robinson',
          'Hey! I wanted to drop a quick line',
          8640,
        ),
      ),
      Chat(
        id: '!design_room:example.org',
        // l10n-ignore: demo fixture, never shipped to a real inbox.
        title: 'Design Team',
        isGroup: true,
        sources: const [
          ChatSource(
            roomId: '!design_room:example.org',
            network: ChatNetwork.matrix,
          ),
        ],
        unreadCount: 5,
        lastMessage: _msg(
          '!design_room:example.org',
          ChatNetwork.matrix,
          'Priya',
          'Pushed the new rail animation',
          35,
        ),
      ),
    ];
  }

  static WeftMessage _msg(
    String roomId,
    ChatNetwork network,
    String sender,
    String body,
    int minutesAgo, {
    bool isOwn = false,
    MessageKind kind = MessageKind.text,
    String? transcript,
    DeliveryState? delivery,
    String? threadRootId,
    String? threadName,
  }) {
    return WeftMessage(
      eventId: '\$${roomId}_$minutesAgo',
      roomId: roomId,
      network: network,
      senderId: isOwn ? '@me:example.org' : '@peer:example.org',
      senderName: sender,
      timestamp: _now.subtract(Duration(minutes: minutesAgo)),
      kind: kind,
      isOwn: isOwn,
      body: body,
      transcript: transcript,
      deliveryState: delivery,
      threadRootId: threadRootId,
      threadName: threadName,
      durationMs: kind == MessageKind.voice ? 8400 : null,
    );
  }

  /// The Telegram room that carries a forum topic, so the thread surfaces are
  /// reachable without a homeserver.
  ///
  /// One room rather than all of them: threads are the exception in a real
  /// inbox and a demo where every conversation had one would misrepresent both
  /// the feature and the ordinary case. The route walk opens this room by name.
  static const String kThreadRoomId = '!isabella_tg_room:example.org';

  /// That room's title, so a test can open it by name rather than by position.
  // l10n-ignore: demo fixture, never shipped to a real inbox.
  static const String kThreadChatTitle = 'Isabella Garcia';

  /// The topic's opening message, which the indicator hangs under.
  static const String kThreadRootEventId = '\$!isabella_tg_room:example.org_44';

  /// A Telegram forum topic: a root, and three replies inside it.
  ///
  /// Named "Deploy" because a topic's *name* is the thing the bridge carries
  /// that a plain Matrix thread does not, and an unnamed one here would leave
  /// the interesting half of `threadTitle` undemonstrated.
  static List<WeftMessage> _forumTopic() =>
      const [
            (
              44,
              'Isabella Garcia',
              'Anyone free to look at the deploy?',
              false,
              null,
            ),
            (
              40,
              'Isabella Garcia',
              'It fell over on the migration step',
              false,
              true,
            ),
            (36, 'You', 'Looking now', true, true),
            (32, 'Isabella Garcia', 'Thank you!', false, true),
          ]
          .map((row) {
            final (minutesAgo, sender, body, isOwn, inThread) = row;
            return _msg(
              kThreadRoomId,
              ChatNetwork.telegram,
              sender,
              body,
              minutesAgo,
              isOwn: isOwn,
              delivery: isOwn ? DeliveryState.delivered : null,
              threadRootId: inThread == null ? null : kThreadRootEventId,
              threadName: 'Deploy',
            );
          })
          .toList(growable: false);

  /// Synthesises a plausible back-and-forth for a room, staggered per network
  /// so a merged chat genuinely interleaves.
  /// Synthesised history for one room.
  ///
  /// `@protected` and overridable rather than private, because a subclass that
  /// replaces the *timeline* and not this is a repository that disagrees with
  /// itself: `timelineFor` would hand over one set of messages while
  /// `_messageIn` — which is what a reply, a reaction and a thread send all
  /// resolve their target through — walked another and found nothing.
  @protected
  @visibleForOverriding
  List<WeftMessage> historyFor(ChatSource source, String title) {
    final seed = source.roomId.hashCode.abs();
    final lines =
        _sampleLines[source.network] ?? _sampleLines[ChatNetwork.matrix]!;
    final history = [
      if (source.roomId == kThreadRoomId) ..._forumTopic(),
      // Anything sent this session comes first: the fixtures are a fixed past,
      // and an attachment the user just sent belongs on top of it.
      ..._localMessages[source.roomId] ?? const <WeftMessage>[],
      for (var i = 0; i < 24; i++)
        _msg(
          source.roomId,
          source.network,
          i.isEven ? title : 'You',
          lines[(seed + i) % lines.length],
          (i * 37 + seed % 19) + 2,
          isOwn: i.isOdd,
          delivery: i.isOdd ? DeliveryState.read : null,
        ),
    ];
    if (_forgotten.isEmpty) return history;
    return history
        .where((m) => !_forgotten.contains(m.eventId))
        .toList(growable: false);
  }

  static const Map<ChatNetwork, List<String>> _sampleLines = {
    ChatNetwork.whatsapp: [
      'Morning! Did you get a chance to look at it?',
      'Yes, reviewing now.',
      'Perfect, thanks.',
      'Let me check and get back to you.',
    ],
    ChatNetwork.signal: [
      'Sending the details over here instead.',
      'Got it, thanks for switching.',
      'Can you provide more details about the timeline?',
      'That does sound promising.',
    ],
    ChatNetwork.telegram: [
      'Quick update from my side.',
      'Sounds good, ship it',
      'Are we still meeting Thursday?',
      'Yes, 14:00 works.',
    ],
    ChatNetwork.discord: [
      'Dropped the files in the channel.',
      'Thanks, grabbing them now.',
      'Ping me if anything looks off.',
    ],
    ChatNetwork.slack: [
      'Shared the deck with the team.',
      'Appreciate it.',
      'Following up on the action items.',
    ],
    ChatNetwork.instagram: ['Saw your story — congrats!', 'Thank you!'],
    ChatNetwork.matrix: [
      'Pushed a fix for the timeline watermark.',
      'Nice, tests green?',
      'All 54 passing.',
    ],
  };
}

/// An [AttachmentTransport] that moves no bytes and takes its time about it.
///
/// The delay is the point rather than an artefact: a transport that returned a
/// URI immediately would render the progress bubble for a single frame, so the
/// one state the attachment UI exists to show would never be seen in demo mode
/// or in a golden. It is a [Timer] under the hood and touches no I/O, so a test
/// with `Duration.zero` runs it in microseconds.
class _DemoUploadTransport implements AttachmentTransport {
  _DemoUploadTransport({required this.tick});

  final Duration tick;
  final Set<String> _cancelled = {};

  @override
  String get id => 'demo';

  @override
  String get displayName => 'Demo';

  @override
  Future<String> upload(
    List<int> bytes, {
    required String mimeType,
    required String uploadId,
    void Function(int sent, int total)? onProgress,
  }) async {
    // A retry reuses the task id, so a stale flag would abort the new attempt
    // before it started — the same rule the Matrix transport follows.
    _cancelled.remove(uploadId);

    final total = bytes.isEmpty ? 1 : bytes.length;
    for (var step = 1; step <= kDemoUploadSteps; step++) {
      await Future<void>.delayed(tick);
      if (_cancelled.contains(uploadId)) {
        throw const AttachmentTransportException(
          'This upload was cancelled.',
          retryable: false,
        );
      }
      onProgress?.call(total * step ~/ kDemoUploadSteps, total);
    }

    // Derived from the id rather than random, so the same demo send produces
    // the same URI on every run and a golden cannot flake on it.
    return 'mxc://demo.weft/${uploadId.replaceAll(RegExp('[^a-zA-Z0-9]'), '')}';
  }

  @override
  void cancel(String uploadId) => _cancelled.add(uploadId);

  @override
  void dispose() => _cancelled.clear();
}

/// An [InMemoryTimelineSource] that reads the session back in on every access.
///
/// The base class snapshots its history at construction, which is right for a
/// fixture and wrong for everything the user does to one. The demo repository
/// keeps relations beside the messages rather than inside them, so a reaction
/// sent while the chat is open is in the map and — with a snapshot — never on
/// the screen; a reply sent while it is open is in `_localMessages` and equally
/// invisible until the chat is closed and opened again.
///
/// Both are resolved on read instead. [fold] applies the relations and
/// [sessionMessages] supplies what this session has sent, deduplicated against
/// what the snapshot already holds. That is the behaviour a real timeline gets
/// for free: a Matrix reaction, edit, redaction and reply are all themselves
/// events, and every one of them moves the timeline the Matrix source wraps.
class _RelationsTimelineSource extends InMemoryTimelineSource {
  _RelationsTimelineSource({
    required super.roomId,
    required super.network,
    required super.history,
    required this.fold,
    required this.sessionMessages,
    super.pageSize,
  });

  final WeftMessage Function(WeftMessage message) fold;

  /// What this session has sent into [roomId], oldest first.
  final List<WeftMessage> Function(String roomId) sessionMessages;

  @override
  List<WeftMessage> get loaded {
    final settled = super.loaded;
    // A message sent before the timeline was opened is already in the snapshot
    // and paginates in normally; only the ones sent since need prepending, and
    // only until pagination reaches them.
    final known = {for (final message in settled) message.eventId};
    return [
      for (final message in sessionMessages(roomId).reversed)
        if (!known.contains(message.eventId)) fold(message),
      ...settled.map(fold),
    ];
  }
}
