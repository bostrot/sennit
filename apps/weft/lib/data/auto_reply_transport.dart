import 'package:weft_domain/weft_domain.dart';

/// The one send that must not mark a conversation read.
///
/// Deliberately **not** a method on [ChatRepository], and deliberately not a
/// flag on its `send`. Everything on that interface is something a person did:
/// a tap, a Return, a share sheet. This is the one send nobody performed, it
/// has a different postcondition — the badge is still there afterwards — and
/// the twelve fakes that `implements ChatRepository` would each have to grow an
/// implementation of a method whose whole point is a guarantee a fake cannot
/// make.
///
/// A narrow interface instead: `MatrixChatRepository` implements it, the
/// auto-reply service is written against it, and nothing in `features/` can
/// reach it by accident. In demo mode there is no implementation and the
/// feature stays dormant, which is the same shape every other endpoint-backed
/// feature has.
abstract interface class AutoReplyTransport {
  /// Sends [body] into [chatId] as a machine-written reply and leaves the
  /// conversation exactly as unread as it was.
  ///
  /// Three promises, and the whole feature rests on them:
  ///
  /// 1. **No read receipt.** Nothing here calls `markRead`, `setReadMarker` or
  ///    the SMS provider's mark-read. The sender is told nothing.
  /// 2. **No local read.** Sending moves a room's newest event past every
  ///    receipt it holds, and `isReadLocally` reads that as "the user has seen
  ///    this" — so the unread state is captured before the send and re-asserted
  ///    after it, through the MSC2867 flag that syncs to the account's other
  ///    devices.
  /// 3. **Marked as machine-written**, with the `com.bostrot.weft.auto_reply`
  ///    key, so the transcript can say so and another Sennit will not answer it.
  ///    The key rides Matrix only; an SMS or bridged leg carries the words and
  ///    nothing else.
  ///
  /// Returns the event id the homeserver gave the reply, or null for a
  /// transport that has none — SMS. Throws for a chat that cannot be replied
  /// to at all, which the caller reports rather than retries.
  Future<String?> sendAutoReply(String chatId, String body, {ChatNetwork? via});
}
