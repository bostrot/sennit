import Foundation

/// The keys the phone and the watch agree on, spelled once.
///
/// The Swift counterpart of `WeftWearProtocol`, and deliberately the same names
/// in the same order — the two transports are different frameworks solving one
/// problem, and a reader comparing them should not also have to translate the
/// vocabulary.
///
/// The snapshot itself is **not** re-described here. It crosses as the exact
/// string `SnapshotCodec` wrote, parsed by `WeftSnapshotFormat` on the far side.
///
/// It lives in `ios/Shared/` and is **a member of `Runner`, `WeftWatch` and
/// `WeftWatchComplication`**, which is why it imports `Foundation` and nothing
/// else — the same discipline `SnapshotContainer.swift` follows for the same
/// reason. A key spelled twice across a process boundary is not an error
/// anywhere: it is a watch that never updates, and a phone that never hears a
/// reply.
enum WeftWatchProtocol {
  /// The encoded `InboxSnapshot`. Absent whenever the watch surface is off,
  /// because the phone withholds it rather than blanking it.
  static let payloadKey = "payload"

  /// Whether the watch may render it. Its presence is also how "the phone has
  /// published" is told from "it never has", which is the signed-out state.
  static let watchEnabledKey = "watch"

  /// When the phone published, as a `TimeInterval`.
  ///
  /// Not the snapshot's own `generatedAt` — that is inside the payload and is
  /// what staleness is judged against. This exists because
  /// `updateApplicationContext` will not deliver a dictionary equal to the last
  /// one, so an unchanged snapshot's periodic rewrite would be swallowed.
  static let updatedAtKey = "updatedAt"

  static let replyIdKey = "id"
  static let replyChatIdKey = "chatId"
  static let replyBodyKey = "body"

  static let resultSentKey = "sent"
  static let resultFailureKey = "failure"
  static let resultNetworkKey = "network"

  // The same ids `WatchReplyFailure` spells in Dart and `WeftWearProtocol`
  // spells in Kotlin. Only the last is produced on this side, by a process the
  // system woke for a message with no Flutter engine in it.
  static let failureUnknownChat = "unknown_chat"
  static let failureNotSignedIn = "not_signed_in"
  static let failureSendFailed = "send_failed"
  static let failureTimedOut = "timed_out"
  static let failureOverflowed = "overflowed"
  static let failureAppNotRunning = "app_not_running"
}
