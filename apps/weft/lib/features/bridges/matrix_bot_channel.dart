import 'dart:async';

import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_bridges/weft_bridges.dart';

/// The chat with a bridge bot, over a real Matrix room.
///
/// What [BridgeCommandClient] types and reads. Messages are sent exactly as
/// given — no Markdown, no `/command` parsing — because what goes in here is a
/// phone number, a code or a token, and the SDK's helpful rewriting of
/// `_underscores_` or a leading slash would hand the bot something the person
/// never typed.
class MatrixBotChannel implements BridgeBotChannel {
  MatrixBotChannel({required sdk.Client client, required this.botUserId})
    : _client = client;

  final sdk.Client _client;
  final String botUserId;

  String? _roomId;
  StreamSubscription<sdk.Event>? _subscription;
  final _messages = StreamController<BotMessage>.broadcast();

  @override
  Future<bool> exists() async => _existingRoomId() != null;

  /// The management chat, when there already is one.
  ///
  /// `m.direct` first, which is where a chat Sennit or another client opened
  /// is recorded; then any joined two-person room with the bot in it, which is
  /// what a bridge-created management room looks like before anyone marked it
  /// as direct.
  String? _existingRoomId() {
    final direct = _client.getDirectChatFromUserId(botUserId);
    if (direct != null) return direct;
    for (final room in _client.rooms) {
      if (room.membership != sdk.Membership.join) continue;
      final members = room.summary.mJoinedMemberCount ?? 0;
      if (members > 2) continue;
      final bot = room.getState(sdk.EventTypes.RoomMember, botUserId);
      if (bot?.content['membership'] == 'join') return room.id;
    }
    return null;
  }

  @override
  Future<void> open() async {
    if (_roomId != null && _client.getRoomById(_roomId!) != null) return;
    final roomId =
        _existingRoomId() ?? await _client.startDirectChat(botUserId);
    // A freshly created chat reaches the local room list with the next sync.
    for (var i = 0; i < 40 && _client.getRoomById(roomId) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _roomId = roomId;
    _listen();
  }

  void _listen() {
    _subscription ??= _client.onTimelineEvent.stream.listen((event) {
      if (event.roomId != _roomId || event.senderId != botUserId) return;
      final message = _toMessage(event);
      if (message != null && !_messages.isClosed) _messages.add(message);
    });
  }

  static BotMessage? _toMessage(sdk.Event event) {
    if (event.type == sdk.EventTypes.Redaction) {
      final redacts = event.redacts ?? event.content['redacts'] as String?;
      return redacts == null
          ? null
          : BotMessage(eventId: event.eventId, redacts: redacts);
    }
    if (event.type != sdk.EventTypes.Message) return null;

    final isEdit = event.relationshipType == sdk.RelationshipTypes.edit;
    final content = isEdit && event.content['m.new_content'] is Map
        ? (event.content['m.new_content'] as Map).cast<String, Object?>()
        : event.content;
    return BotMessage(
      eventId: event.eventId,
      body: content['body'] as String? ?? '',
      formattedBody: content['formatted_body'] as String?,
      isImage: content['msgtype'] == sdk.MessageTypes.Image,
      replaces: isEdit ? event.relationshipEventId : null,
    );
  }

  @override
  Future<void> send(String text) async {
    await open();
    final room = _client.getRoomById(_roomId!);
    if (room == null) {
      throw StateError('The chat with $botUserId is not available.');
    }
    // Listening before sending: a fast bot answers before the send returns.
    _listen();
    await room.sendTextEvent(
      text,
      parseMarkdown: false,
      parseCommands: false,
      addMentions: false,
    );
  }

  @override
  Stream<BotMessage> get messages {
    _listen();
    return _messages.stream;
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _messages.close();
  }
}
