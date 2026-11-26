import 'package:weft_domain/weft_domain.dart';

/// Finding and joining a Matrix room by the id or alias a link carried.
///
/// A narrow interface rather than two more methods on `ChatRepository`, for
/// the reason `AutoReplyTransport` gives: only a real Matrix account can join
/// a room, and every fake of the wider interface would otherwise have to
/// pretend to. `MatrixChatRepository` implements it; anywhere else a room
/// link opens only rooms the inbox already has.
abstract interface class RoomJoiner {
  /// The conversation [roomIdOrAlias] belongs to when the user is already in
  /// that room, or null. `!id:server` or `#alias:server`.
  Chat? chatForRoomLink(String roomIdOrAlias);

  /// Joins the room [roomIdOrAlias] names, through [via] when the link said
  /// where it lives, and returns its chat id. Throws when the server refuses.
  Future<String> joinRoom(String roomIdOrAlias, {List<String> via = const []});
}
