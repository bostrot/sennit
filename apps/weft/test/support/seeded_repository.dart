import 'package:weft/data/demo_repository.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import 'recording_repository.dart';

/// A chat whose messages the test wrote itself.
///
/// The demo fixtures are a fixed past: plain bodies, no formatting, no links,
/// and nobody but the local user ever reacting. Three things worth asserting at
/// the app layer are invisible in them — what a *formatted* body does inside a
/// real bubble, what a tap on somebody else's reaction chip sends, and what the
/// bubble does with a link whose text is lying about where it goes. This serves
/// an arbitrary history through the real [MergedTimeline], so the widget under
/// test is still the chat view, wired the way the app wires it.
///
/// Extends [RecordingChatRepository] to inherit both the forwarding of the
/// dozen members a chat view touches and the argument recording. The relation
/// actions are recorded but deliberately **not** forwarded: the seeded history
/// is fixed, and the demo repository behind it has never heard of these event
/// ids. Tests here assert what the UI *asked for*; that the ask lands correctly
/// is `message_relations_test.dart`'s question.
class SeededChatRepository extends RecordingChatRepository {
  SeededChatRepository(
    DemoChatRepository super.inner, {
    required this.messages,
    this.chatId = 'seeded:chat',
    this.title = 'Test Chat',
  });

  /// The history, in any order — the sources sort it.
  final List<WeftMessage> messages;

  final String chatId;
  final String title;

  /// One source per distinct room, in the order the messages first name them.
  Chat get chat {
    final sources = <ChatSource>[];
    for (final message in messages) {
      if (sources.any((s) => s.roomId == message.roomId)) continue;
      sources.add(ChatSource(roomId: message.roomId, network: message.network));
    }
    final newest = [...messages]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return Chat(
      id: chatId,
      title: title,
      sources: sources,
      lastMessage: newest.firstOrNull,
    );
  }

  @override
  Stream<List<Chat>> watchChats() => Stream.value([chat]);

  @override
  Chat? chatForRoom(String roomId) =>
      chat.sources.any((s) => s.roomId == roomId) ? chat : null;

  @override
  Future<MergedTimeline> timelineFor(String id) async {
    if (id != chatId) throw ArgumentError.value(id, 'chatId', 'Unknown chat');
    return MergedTimeline(
      sources: [
        for (final source in chat.sources)
          InMemoryTimelineSource(
            roomId: source.roomId,
            network: source.network,
            // Bigger than any seeded history, so one round of pagination
            // exhausts every leg and the watermark stops hiding the oldest
            // message — which in a two-message fixture is most of it.
            pageSize: 200,
            history: messages
                .where((m) => m.roomId == source.roomId)
                .toList(growable: false),
          ),
      ],
    );
  }

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) async =>
      calls.add(RecordedCall('send', body: body));

  @override
  Future<void> sendReply(
    String chatId,
    String body, {
    required String replyToEventId,
    ChatNetwork? via,
  }) async =>
      calls.add(RecordedCall('sendReply', eventId: replyToEventId, body: body));

  @override
  Future<void> react(String chatId, String eventId, String key) async =>
      calls.add(RecordedCall('react', eventId: eventId, key: key));

  @override
  Future<void> unreact(String chatId, String reactionEventId) async =>
      calls.add(RecordedCall('unreact', eventId: reactionEventId));

  @override
  Future<void> editMessage(
    String chatId,
    String eventId,
    String newBody,
  ) async =>
      calls.add(RecordedCall('editMessage', eventId: eventId, body: newBody));

  @override
  Future<void> redact(String chatId, String eventId) async =>
      calls.add(RecordedCall('redact', eventId: eventId));
}

/// A seeded message, with the fields these tests actually vary.
WeftMessage seededMessage({
  required String eventId,
  required String body,
  String roomId = '!seeded:example.org',
  ChatNetwork network = ChatNetwork.telegram,
  String? formattedBody,
  bool isOwn = false,
  String senderName = 'Anna Maven',
  String? senderId,
  DateTime? timestamp,
  int minutesAgo = 0,
  String? replyToEventId,
  List<ReactionTally> reactions = const [],
  DateTime? editedAt,
  List<EditRecord> editHistory = const [],
}) {
  return WeftMessage(
    eventId: eventId,
    roomId: roomId,
    network: network,
    senderId: senderId ?? (isOwn ? '@me:example.org' : '@anna:example.org'),
    senderName: isOwn ? 'You' : senderName,
    timestamp:
        timestamp ??
        DateTime(2026, 8, 18, 14).subtract(Duration(minutes: minutesAgo)),
    kind: MessageKind.text,
    isOwn: isOwn,
    body: body,
    formattedBody: formattedBody,
    replyToEventId: replyToEventId,
    reactions: reactions,
    editedAt: editedAt,
    editHistory: editHistory,
    deliveryState: isOwn ? DeliveryState.read : DeliveryState.sent,
  );
}
