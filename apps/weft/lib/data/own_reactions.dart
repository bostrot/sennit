/// The user's own reactions this device has seen, per room, for
/// `Chat.reactedUpTo`.
///
/// Kept by reaction event id, so taking a reaction back — a redaction naming
/// that id — removes exactly it and leaves the others standing. Only the
/// newest few per room are kept: what "answered" asks is whether the user
/// reacted to the *latest* thing said, and a reaction on a message from last
/// month never answers anything again.
class OwnReactionLog {
  OwnReactionLog([Map<String, Map<String, DateTime>> rooms = const {}]) {
    for (final MapEntry(:key, :value) in rooms.entries) {
      _rooms[key] = {...value};
    }
  }

  /// How many reactions are kept per room.
  static const int perRoom = 8;

  /// Room id → reaction event id → when the message it is on was sent.
  final Map<String, Map<String, DateTime>> _rooms = {};

  /// Records [reactionId], on a message sent at [targetAt]. False when it was
  /// already known, or too old to be kept.
  bool record(String roomId, String reactionId, DateTime targetAt) {
    final room = _rooms.putIfAbsent(roomId, () => {});
    if (room[reactionId] == targetAt) return false;
    room[reactionId] = targetAt;
    if (room.length > perRoom) {
      final oldest = room.entries
          .reduce((a, b) => a.value.isAfter(b.value) ? b : a)
          .key;
      room.remove(oldest);
      if (oldest == reactionId) return false;
    }
    return true;
  }

  /// Forgets [eventId] when it is one of the user's reactions in [roomId].
  /// False when it was not.
  bool redact(String roomId, String eventId) {
    final room = _rooms[roomId];
    if (room == null || room.remove(eventId) == null) return false;
    if (room.isEmpty) _rooms.remove(roomId);
    return true;
  }

  /// When the newest message the user still has a reaction on in [roomId]
  /// was sent, or null.
  DateTime? reactedUpTo(String roomId) {
    final room = _rooms[roomId];
    if (room == null || room.isEmpty) return null;
    return room.values.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  Map<String, Object?> toJson() => {
    for (final MapEntry(key: roomId, value: room) in _rooms.entries)
      roomId: {
        for (final MapEntry(:key, :value) in room.entries)
          key: value.toUtc().millisecondsSinceEpoch,
      },
  };

  /// Reads a log back, skipping anything malformed. Never throws.
  static OwnReactionLog fromJson(Object? json) {
    if (json is! Map) return OwnReactionLog();
    return OwnReactionLog({
      for (final MapEntry(key: roomId, value: room) in json.entries)
        if (roomId is String && room is Map)
          roomId: {
            for (final MapEntry(:key, :value) in room.entries)
              if (key is String && value is int)
                key: DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
          },
    });
  }
}

/// The message a timeline event reacts to, when it is one of the user's own
/// reactions; null for anything else.
///
/// [isOwn] says whether a sender is the user. The relation is read from
/// `m.relates_to`, which stays in the clear in an encrypted room, so a
/// reaction counts whether or not this device could decrypt it. A local echo
/// — an id that is not a server's `$` id yet — is not one: the synced copy
/// follows under its real id, which is the one a later redaction names.
String? ownReactionTarget({
  required String type,
  required String eventId,
  required String senderId,
  required Map<String, Object?> content,
  required bool Function(String senderId) isOwn,
}) {
  if (type != 'm.reaction' && type != 'm.room.encrypted') return null;
  if (!eventId.startsWith(r'$') || !isOwn(senderId)) return null;
  final relates = content['m.relates_to'];
  if (relates is! Map || relates['rel_type'] != 'm.annotation') return null;
  final target = relates['event_id'];
  return target is String ? target : null;
}
