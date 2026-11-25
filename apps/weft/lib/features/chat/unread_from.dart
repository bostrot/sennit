import 'package:weft_domain/weft_domain.dart';

/// What marking a conversation unread from [from] means in [loaded]: the
/// message just before it on the same leg, where the read marker goes back
/// to, and how many messages from [from] on are someone else's — the badge.
///
/// Same room only, because a read marker is per room: in a merged chat the
/// message before [from] may have come in on another network. The user's own
/// messages are not counted — nobody has unread what they wrote — but [from]
/// itself always is, so the badge never reads zero after the user asked for
/// one.
({String? before, int count}) unreadFromPlan(
  Iterable<WeftMessage> loaded,
  WeftMessage from,
) {
  WeftMessage? before;
  var count = 0;
  for (final m in loaded) {
    if (m.roomId != from.roomId || m.eventId == from.eventId) continue;
    if (m.timestamp.isBefore(from.timestamp)) {
      if (before == null || m.timestamp.isAfter(before.timestamp)) before = m;
    } else if (!m.isOwn && !m.redacted) {
      count++;
    }
  }
  return (before: before?.eventId, count: count + 1);
}
