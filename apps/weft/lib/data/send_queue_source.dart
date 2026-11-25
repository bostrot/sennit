import 'package:weft_domain/weft_domain.dart';

/// Why each failed message did not leave, for the bubble and its menu.
///
/// Not a member of [ChatRepository], for the same reason as
/// `AutoReplyTransport`: only the Matrix repository has a queue to report on,
/// and every fake that implements the interface would have to grow one. Where
/// the repository is not one of these, nothing failed for a reason worth
/// naming and the bubble says "Not sent", as before.
abstract interface class SendQueueSource {
  /// The failures right now, by the failed local echo's event id.
  Map<String, SendFailure> get sendFailures;

  /// [sendFailures] each time it changes.
  Stream<Map<String, SendFailure>> get sendFailureChanges;
}
