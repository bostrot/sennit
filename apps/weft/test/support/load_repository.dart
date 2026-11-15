import 'dart:async';

import 'package:weft/data/demo_repository.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

/// A [DemoChatRepository] the size of a heavy real account, for measuring.
///
/// The demo fixtures are eleven conversations of twenty-four messages each,
/// which is the right size for a golden and the wrong one for a stopwatch:
/// nothing that scales with the inbox or with scroll depth costs anything
/// there. This is the same repository at the size the complaints come from —
/// a couple of thousand conversations, a group with thousands of loaded
/// messages and a room full of read receipts — and it behaves the way the
/// Matrix one does where that matters for the frame budget:
///
/// - [tick] re-emits the inbox as a **new list of new [Chat] objects**, which
///   is what `MatrixChatRepository._rebuild` does after every sync, changed or
///   not;
/// - a timeline's `loaded` list is cached and identical between changes, as
///   `MatrixTimelineSource`'s is, rather than copied per read as the in-memory
///   test source's is.
class LoadChatRepository extends DemoChatRepository {
  LoadChatRepository({
    this.chatCount = 2000,
    this.groupMessages = 3000,
    this.groupMembers = 40,
    this.preloaded = 0,
  }) {
    _chats = [_groupChat(), for (var i = 1; i < chatCount; i++) _directChat(i)];
  }

  final int chatCount;
  final int groupMessages;
  final int groupMembers;

  /// How much of the group's history is already loaded when it is opened —
  /// the state a reader is in after scrolling a long way back, without the
  /// scrolling.
  final int preloaded;

  /// The busy group every chat scenario opens.
  static const String groupChatId = '!load_group:example.org';

  static const String _me = '@me:example.org';
  static final DateTime _now = DemoChatRepository.fixtureNow;

  static const List<ChatNetwork> _networks = [
    ChatNetwork.whatsapp,
    ChatNetwork.signal,
    ChatNetwork.telegram,
    ChatNetwork.matrix,
  ];

  static const List<String> _lines = [
    'Morning! Did you get a chance to look at it?',
    'Yes, reviewing now.',
    'Perfect, thanks 🙏',
    'Let me check and get back to you. There are a couple of things in the '
        'second half I am not sure about yet, mostly around the timeline and '
        'who is picking up the follow-ups after Thursday.',
    'https://example.org/docs/plan-q3 has the numbers',
    'ok',
    'Can you provide more details about the timeline? I want to make sure we '
        'are not promising anything before the review.',
    'Sounds good, ship it',
    'Are we still meeting Thursday?',
    'Yes, 14:00 works.',
  ];

  late List<Chat> _chats;
  final _controller = StreamController<List<Chat>>.broadcast();
  int _ticks = 0;

  /// How many times the inbox has been re-emitted.
  int get ticks => _ticks;

  // ------------------------------------------------------------------ inbox

  Chat _directChat(int i) {
    final network = _networks[i % _networks.length];
    final roomId = '!load_$i:example.org';
    return Chat(
      id: roomId,
      title: 'Contact $i ${_surnames[i % _surnames.length]}',
      sources: [
        ChatSource(
          roomId: roomId,
          network: network,
          unread: i % 7 == 0 ? 2 : 0,
        ),
      ],
      unreadCount: i % 7 == 0 ? 2 : 0,
      isGroup: i % 5 == 0,
      pinned: i < 3,
      muted: i % 11 == 0,
      lastMessage: WeftMessage(
        eventId: '\$last_$i',
        roomId: roomId,
        network: network,
        senderId: i.isEven ? _me : '@peer_$i:example.org',
        senderName: i.isEven ? 'You' : 'Contact $i',
        timestamp: _now.subtract(Duration(minutes: i * 7)),
        kind: MessageKind.text,
        isOwn: i.isEven,
        body: _lines[i % _lines.length],
        deliveryState: i.isEven ? DeliveryState.delivered : null,
      ),
    );
  }

  static const List<String> _surnames = [
    'Maven',
    'Okafor',
    'Lindqvist',
    'Tanaka',
    'Silva',
    'Haddad',
  ];

  Chat _groupChat() => Chat(
    id: groupChatId,
    title: 'Load test group',
    sources: const [
      ChatSource(roomId: groupChatId, network: ChatNetwork.whatsapp),
    ],
    isGroup: true,
    pinned: true,
    // Everyone but the local user, which is what the read rule counts.
    participantCount: groupMembers - 1,
    lastMessage: _groupHistory.first,
  );

  /// Re-emits the inbox the way a sync does: every [Chat] rebuilt, and — when
  /// [changeOne] — one conversation actually different.
  void tick({bool changeOne = true}) {
    _ticks++;
    final touched = changeOne ? 3 + (_ticks % 40) : -1;
    _chats = [
      for (var i = 0; i < _chats.length; i++)
        if (i == touched)
          _chats[i].copyWith(
            unreadCount: _chats[i].unreadCount + 1,
            lastMessage: WeftMessage(
              eventId: '\$tick_${_ticks}_$i',
              roomId: _chats[i].id,
              network: _chats[i].sources.first.network,
              senderId: '@peer_$i:example.org',
              senderName: 'Contact $i',
              timestamp: _now.add(Duration(seconds: _ticks)),
              kind: MessageKind.text,
              isOwn: false,
              body: _lines[_ticks % _lines.length],
            ),
          )
        else
          _chats[i].copyWith(),
    ];
    _controller.add(_chats);
  }

  @override
  Stream<List<Chat>> watchChats() async* {
    yield _chats;
    yield* _controller.stream;
  }

  @override
  Chat? chatForRoom(String roomId) =>
      _chats.where((c) => c.roomIds.contains(roomId)).firstOrNull;

  @override
  List<ChatNetwork> get availableNetworks => _networks;

  @override
  Future<void> markRead(String chatId) async {}

  // --------------------------------------------------------------- timeline

  late final List<WeftMessage> _groupHistory = _buildGroupHistory();

  List<WeftMessage> _buildGroupHistory() {
    final out = <WeftMessage>[];
    for (var i = 0; i < groupMessages; i++) {
      // Runs of two or three from one sender, as a real group reads.
      final member = (i ~/ 3) % groupMembers;
      final own = member == 0;
      final reply = i % 9 == 4 && i + 6 < groupMessages;
      out.add(
        WeftMessage(
          eventId: '\$g_$i',
          roomId: groupChatId,
          network: ChatNetwork.whatsapp,
          senderId: own ? _me : '@member_$member:example.org',
          senderName: own
              ? 'You'
              : 'Member $member ${_surnames[member % _surnames.length]}',
          // Newest first: index 0 is the newest message.
          timestamp: _now.subtract(Duration(minutes: i * 3)),
          kind: MessageKind.text,
          isOwn: own,
          body: _lines[i % _lines.length],
          // Every other reply answers something far enough back that it is
          // not loaded when the bubble is first drawn — the unresolved case.
          replyToEventId: reply ? '\$g_${i % 18 == 4 ? i + 6 : i + 900}' : null,
          reactions: i % 6 == 2
              ? [
                  ReactionTally(
                    key: '👍',
                    senderIds: const ['@member_3:example.org', _me],
                    firstReactedAt: _now,
                    byLocalUser: true,
                    localEventId: '\$r_$i',
                  ),
                  ReactionTally(
                    key: '😂',
                    senderIds: const ['@member_5:example.org'],
                    firstReactedAt: _now,
                  ),
                ]
              : const [],
          deliveryState: own ? DeliveryState.delivered : null,
        ),
      );
    }
    return out;
  }

  @override
  Future<MergedTimeline> timelineFor(String chatId) async {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) {
      throw ArgumentError.value(chatId, 'chatId', 'Unknown chat');
    }
    if (chatId == groupChatId) {
      return MergedTimeline(
        sources: [
          _CachedSource(
            roomId: groupChatId,
            network: ChatNetwork.whatsapp,
            history: _groupHistory,
            preloaded: preloaded,
          ),
        ],
      );
    }
    final source = chat.sources.first;
    return MergedTimeline(
      sources: [
        _CachedSource(
          roomId: source.roomId,
          network: source.network,
          history: [
            for (var i = 0; i < 60; i++)
              WeftMessage(
                eventId: '\$${source.roomId}_$i',
                roomId: source.roomId,
                network: source.network,
                senderId: i.isEven ? _me : '@peer:example.org',
                senderName: i.isEven ? 'You' : chat.title,
                timestamp: _now.subtract(Duration(minutes: i * 5)),
                kind: MessageKind.text,
                isOwn: i.isEven,
                body: _lines[i % _lines.length],
                deliveryState: i.isEven ? DeliveryState.delivered : null,
              ),
          ],
        ),
      ],
    );
  }

  /// Conversations somebody is typing in. Changes no [Chat]; a [tick] is what
  /// carries it to the screen, as a sync does.
  final Set<String> typingChats = {};

  @override
  List<String> typingIn(String chatId) =>
      typingChats.contains(chatId) ? const ['Member 1'] : const [];

  /// Moves every member's receipt to the newest message. Changes no [Chat]
  /// and no message, like the receipts it stands for.
  bool everyoneHasRead = false;

  /// One receipt per member, spread over the newest couple of hundred
  /// messages — which is where a live room's receipts are.
  @override
  List<({String roomId, String userId, String eventId, DateTime at})>
  peerReadUpTo(String chatId) {
    if (chatId != groupChatId) return const [];
    return [
      for (var m = 1; m < groupMembers; m++)
        (
          roomId: groupChatId,
          userId: '@member_$m:example.org',
          eventId: everyoneHasRead ? '\$g_0' : '\$g_${(m * 5) % 200}',
          at: _now,
        ),
    ];
  }

  @override
  List<({String roomId, String eventId, DateTime at})> ownReadUpTo(
    String chatId,
  ) => chatId == groupChatId
      ? [(roomId: groupChatId, eventId: '\$g_0', at: _now)]
      : const [];
}

/// A paginated source whose `loaded` list is stable between changes.
class _CachedSource extends TimelineSource {
  _CachedSource({
    required this.roomId,
    required this.network,
    required List<WeftMessage> history,
    int preloaded = 0,
  }) : _history = history,
       _loaded = List.unmodifiable(
         history.sublist(0, preloaded.clamp(0, history.length)),
       );

  @override
  final String roomId;

  @override
  final ChatNetwork network;

  final List<WeftMessage> _history;
  List<WeftMessage> _loaded;

  @override
  List<WeftMessage> get loaded => _loaded;

  @override
  bool get hasMore => _loaded.length < _history.length;

  @override
  Future<int> loadMore({int count = 30}) async {
    final end = (_loaded.length + count).clamp(0, _history.length);
    final added = end - _loaded.length;
    if (added <= 0) return 0;
    // A homeserver round trip is never free; a few milliseconds keeps the
    // pagination loop honest without making the run slow.
    await Future<void>.delayed(const Duration(milliseconds: 4));
    _loaded = List.unmodifiable(_history.sublist(0, end));
    return added;
  }
}
