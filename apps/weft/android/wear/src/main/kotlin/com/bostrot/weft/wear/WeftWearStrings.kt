package com.bostrot.weft.wear

import android.content.Context
import com.bostrot.weft.snapshot.WeftWearProtocol

/// The sentences every empty state and every reply outcome is made of.
///
/// Resources rather than literals, unlike the Swift side — this is an Android
/// app with an `R` class, and reaching for one here costs nothing. What it
/// shares with the Swift side is the rule: the wording is kept word-for-word
/// identical to the phone widgets' `res/values/strings.xml` wherever the fact is
/// the same one, so that a user with a widget and a watch is never told two
/// different things about a single switch.
object WeftWearStrings {
    /// The headline and detail for a state, or null when the state has rows to
    /// draw instead.
    ///
    /// A pair rather than two functions, because the one thing that must not
    /// happen is a headline about the watch being off over a body explaining
    /// staleness.
    fun emptyState(context: Context, state: WeftWearState): Pair<String, String> = when (state) {
        WeftWearState.SignedOut ->
            context.getString(R.string.signed_out_title) to
                context.getString(R.string.signed_out_body)
        WeftWearState.SwitchedOff ->
            context.getString(R.string.disabled_title) to
                context.getString(R.string.disabled_body)
        WeftWearState.Unavailable ->
            context.getString(R.string.stale_title) to context.getString(R.string.stale_body)
        // Enabled, with no rows: an empty inbox, or one whose every conversation
        // is on an excluded network. Not an error, and phrased so it does not
        // read as one.
        is WeftWearState.Ready ->
            context.getString(R.string.empty_title) to context.getString(R.string.empty_body)
    }

    /// What a failed reply says.
    ///
    /// **Falls back rather than switching exhaustively**, which is the one place
    /// this file is defensive on purpose. The failure ids are a contract shared
    /// with a phone app that updates on its own schedule; a watch is updated
    /// late and sometimes never, so an id this build has not heard of has to
    /// render as "Not sent" rather than as an empty line or a crash.
    fun replyFailure(context: Context, failure: String?): String = when (failure) {
        WeftWearProtocol.FAILURE_UNKNOWN_CHAT ->
            context.getString(R.string.reply_failed_unknown_chat)
        WeftWearProtocol.FAILURE_NOT_SIGNED_IN ->
            context.getString(R.string.reply_failed_not_signed_in)
        WeftWearProtocol.FAILURE_SEND_FAILED ->
            context.getString(R.string.reply_failed_send_failed)
        WeftWearProtocol.FAILURE_TIMED_OUT ->
            context.getString(R.string.reply_failed_timed_out)
        WeftWearProtocol.FAILURE_OVERFLOWED ->
            context.getString(R.string.reply_failed_overflowed)
        WeftWearProtocol.FAILURE_APP_NOT_RUNNING ->
            context.getString(R.string.reply_failed_app_not_running)
        else -> context.getString(R.string.reply_failed)
    }

    /// `3 unread messages`, pluralised. The one place a plural is formed on this
    /// device.
    fun unreadCount(context: Context, count: Int): String =
        context.resources.getQuantityString(R.plurals.unread_count, count, count)

    /// The canned replies, in the order they are offered.
    ///
    /// Read from resources rather than held as literals so the list is one thing
    /// a translator would touch, and ordered by how often a watch is the wrong
    /// device to have a conversation on: the two that end one come first.
    fun cannedReplies(context: Context): List<String> = listOf(
        context.getString(R.string.canned_yes),
        context.getString(R.string.canned_no),
        context.getString(R.string.canned_on_my_way),
        context.getString(R.string.canned_thanks),
        context.getString(R.string.canned_cant_talk),
        context.getString(R.string.canned_call_later),
    )
}
