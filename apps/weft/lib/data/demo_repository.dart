import 'dart:async';
import 'dart:typed_data';

import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

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

  static final DateTime _now = DateTime(2026, 8, 15, 16, 42);

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
          InMemoryTimelineSource(
            roomId: source.roomId,
            network: source.network,
            pageSize: 12,
            history: _historyFor(source, chat.title),
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
      body: plan.filename,
      deliveryState: DeliveryState.sent,
      // The event id, exactly as `mapEvent` writes it: the field is a flag
      // saying "there is a file here", and the bytes are fetched by event id —
      // which is why the slice moves to the same key here.
      attachmentUrl: eventId,
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
    // Michael appears twice with a near-identical name — the scorer should
    // suggest this merge but never make it unattended.
    _handle(
      'michael_wa',
      ChatNetwork.whatsapp,
      'Michael Johnson',
      null,
      dHash: 0x0F0F0F0F0F0F0F0F,
    ),
    _handle(
      'michael_dc',
      ChatNetwork.discord,
      'Michael Johnsen',
      null,
      dHash: 0x0F0F0F0F0F0F0F0E,
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
          '',
          14,
          kind: MessageKind.voice,
          transcript: 'Hey, are we still on for Thursday?',
        ),
      ),
      Chat(
        id: '!sofia_tg_room:example.org',
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
      Chat(
        id: '!james_ig_room:example.org',
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
          'Pushed the new rail animation 🎨',
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
      durationMs: kind == MessageKind.voice ? 8400 : null,
    );
  }

  /// Synthesises a plausible back-and-forth for a room, staggered per network
  /// so a merged chat genuinely interleaves.
  List<WeftMessage> _historyFor(ChatSource source, String title) {
    final seed = source.roomId.hashCode.abs();
    final lines =
        _sampleLines[source.network] ?? _sampleLines[ChatNetwork.matrix]!;
    return [
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
      'Sounds good 👍',
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
    ChatNetwork.instagram: ['Saw your story — congrats!', 'Thank you! 🙏'],
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
