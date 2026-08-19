package com.bostrot.weft.snapshot

/// Everything the phone and the watch have to agree on, spelled once.
///
/// Compiled into `:app` and into `:wear` from this one file, for the reason
/// `SnapshotPayload.kt` is: they are two APKs that ship separately and neither
/// is a library for the other, so the alternative to sharing the *source* is two
/// copies of a set of string literals that nothing checks against each other. A
/// Data Layer path that differs by a character is not an error anywhere — it is
/// a watch that never updates, and a phone that never hears a reply.
///
/// The snapshot itself is **not** re-described here. It crosses as the exact
/// bytes `SnapshotCodec` wrote, parsed by [SnapshotFormat] on the far side, for
/// the same reason it crosses the App Group and the `SharedPreferences` file
/// unparsed: there is one encoder, and a second description of its shape is a
/// second thing to keep in step.
object WeftWearProtocol {
    // MARK: - Phone → watch: the snapshot

    /// The `DataItem` path carrying the payload.
    ///
    /// A `DataItem` rather than a message, and that is the whole design of this
    /// direction. The Data Layer *syncs* an item: it is stored on both nodes, it
    /// survives the watch being out of range, and a watch that reconnects after
    /// an hour is handed the current value without the phone doing anything. A
    /// message is fire-and-forget and fails silently when the watch is away —
    /// which for a surface whose entire content is "what does the inbox look
    /// like" would mean a watch showing yesterday with no way to know it.
    ///
    /// Leading slash required: `putDataItem` rejects a path without one.
    const val PATH_SNAPSHOT = "/weft/snapshot"

    /// The encoded `InboxSnapshot`, as a string inside the `DataMap`.
    const val KEY_PAYLOAD = "payload"

    /// Whether the watch companion may render [KEY_PAYLOAD].
    ///
    /// Travels *with* the payload here rather than beside it, which is the one
    /// place this diverges from the phone's own container. On the phone the two
    /// surface flags are separate `SharedPreferences` keys because a widget
    /// provider reads them without reading the payload; over the Data Layer
    /// there is one item and splitting it into two would let a watch see them
    /// arrive out of order — permission to draw landing before or after the
    /// content it governs. The home-screen flag is not sent at all: it is not
    /// this device's business.
    const val KEY_WATCH_ENABLED = "watch"

    /// When the phone put this item, in epoch milliseconds.
    ///
    /// Not the snapshot's own `generatedAt` — that is inside the payload and is
    /// what staleness is judged against. This exists because the Data Layer
    /// deduplicates by *content*: putting a byte-identical `DataMap` twice is a
    /// no-op that never reaches `onDataChanged`, so a snapshot whose rows have
    /// not changed would silently stop refreshing the watch. See `WeftWearBridge`.
    const val KEY_UPDATED_AT = "updatedAt"

    // MARK: - Watch → phone: a reply

    /// `MessageClient` path for a reply leaving the wrist.
    ///
    /// A message and not a `DataItem`, inverting the choice above, because the
    /// properties invert with the direction. A reply is an *event* — it happens
    /// once, it must not be replayed onto a new node, and a phone out of range
    /// is a fact the user needs to hear about now rather than a state to sync
    /// later. `WeftWearProtocol` sends it and the watch shows it as pending
    /// until a result arrives on [PATH_REPLY_RESULT].
    const val PATH_REPLY = "/weft/reply"

    /// `MessageClient` path for what became of one.
    const val PATH_REPLY_RESULT = "/weft/reply-result"

    /// The watch's idempotency key. Required; a reply without one is refused
    /// rather than guessed at, on both platforms.
    const val REPLY_ID = "id"

    /// `Chat.id`, exactly as the snapshot row carried it.
    const val REPLY_CHAT_ID = "chatId"

    /// What the user dictated or tapped.
    const val REPLY_BODY = "body"

    /// True when the message went.
    const val RESULT_SENT = "sent"

    /// One of the `FAILURE_*` ids below, present only when [RESULT_SENT] is
    /// false.
    const val RESULT_FAILURE = "failure"

    /// `ChatNetwork.id` for a merged conversation, so the watch can say which
    /// leg it went out on. Absent when there was no choice to make.
    const val RESULT_NETWORK = "network"

    // MARK: - Failures
    //
    // The same ids `WatchReplyFailure` spells in Dart. Four of the five are
    // produced there; [FAILURE_APP_NOT_RUNNING] is produced on this side, by a
    // `WearableListenerService` that woke the app's *process* without waking a
    // Flutter engine, which is a state Dart cannot report on because Dart is not
    // there. A watch must render an id it does not recognise rather than
    // dropping it — this list will grow and watches are updated late.

    const val FAILURE_UNKNOWN_CHAT = "unknown_chat"
    const val FAILURE_NOT_SIGNED_IN = "not_signed_in"
    const val FAILURE_SEND_FAILED = "send_failed"
    const val FAILURE_TIMED_OUT = "timed_out"
    const val FAILURE_OVERFLOWED = "overflowed"
    const val FAILURE_APP_NOT_RUNNING = "app_not_running"
}
