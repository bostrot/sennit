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
      if (event.type == sdk.EventTypes.Encrypted) {
        unawaited(_decryptLater(event));
        return;
      }
      _deliver(event);
    });
  }

  /// Event ids already handed on, because the SDK reports one event more
  /// than once — sent, synced, decrypted — and the bot's answer must be read
  /// once.
  final Set<String> _delivered = {};

  void _deliver(sdk.Event event) {
    if (!_delivered.add(event.eventId)) return;
    final message = _toMessage(event);
    if (message != null && !_messages.isClosed) _messages.add(message);
  }

  /// A bot reply that arrived before its key.
  ///
  /// The chat with a bridge bot is encrypted from its first message, and the
  /// bot's first reply in a new chat routinely beats the key it was encrypted
  /// with: the SDK hands it on still encrypted and never mentions it again.
  /// Read as nothing, that reply was a sign-in that waited for an answer the
  /// bot had already given. So it is tried again while the key arrives.
  Future<void> _decryptLater(sdk.Event event) async {
    final encryption = _client.encryption;
    if (encryption == null) return;
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_messages.isClosed || _delivered.contains(event.eventId)) return;
      final decrypted = await encryption.decryptRoomEvent(event);
      if (decrypted.type != sdk.EventTypes.Encrypted) {
        _deliver(decrypted);
        return;
      }
    }
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
