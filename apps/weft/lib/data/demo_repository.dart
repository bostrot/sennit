import 'dart:async';
import 'dart:typed_data';

import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import 'chat_repository.dart';

/// An in-memory [ChatRepository] with a realistic multi-network inbox.
///
/// This exists so the UI, the merge behaviour and the golden tests can all be
/// exercised without a homeserver. It is wired in only when the app runs with
/// `--dart-define=WEFT_DEMO=true`; the Matrix-backed repository is the default
/// path once M1 lands.
class DemoChatRepository implements ChatRepository {
  DemoChatRepository() {
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
    final network = via ?? chat.sendNetwork ?? ChatNetwork.matrix;
    final source = chat.sourceFor(network) ?? chat.sources.first;

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

  @override
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  }) async => null;

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
