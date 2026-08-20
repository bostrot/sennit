import 'package:meta/meta.dart';

/// How one person answered a calendar invitation.
enum CalendarReply { accepted, declined, reschedule }

/// One participant's answer, aggregated onto the invite.
@immutable
class CalendarResponse {
  const CalendarResponse({
    required this.senderId,
    required this.senderName,
    required this.reply,
    this.proposedStart,
  });

  final String senderId;
  final String senderName;
  final CalendarReply reply;

  /// Only for [CalendarReply.reschedule]: the time they suggest instead.
  final DateTime? proposedStart;
}

/// A calendar entry proposed inside a conversation.
///
/// Weft-to-Weft this negotiates: the other side can accept (which opens their
/// calendar), decline, or propose a new time. Everyone else sees the plain
/// message and, in unencrypted rooms, the `.ics` file riding with it.
@immutable
class CalendarInvite {
  const CalendarInvite({
    required this.uid,
    required this.title,
    required this.start,
    this.end,
    this.responses = const [],
  });

  /// Stable across reschedules, so a v2 of the invite supersedes v1.
  final String uid;

  final String title;
  final DateTime start;
  final DateTime? end;

  final List<CalendarResponse> responses;

  CalendarResponse? responseOf(String senderId) {
    for (final response in responses) {
      if (response.senderId == senderId) return response;
    }
    return null;
  }
}
