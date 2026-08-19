package com.bostrot.weft.widget

import android.content.Context
import com.bostrot.weft.snapshot.InboxSnapshot
import com.bostrot.weft.snapshot.SnapshotFormat

/// What a widget has to draw, decided once so both widgets decide it the same
/// way.
///
/// `InboxSnapshot`'s doc names three states a surface must tell apart — signed
/// out, switched off, nothing to show — and the codec adds a fourth by making
/// staleness a first-class fact. This is those four, plus the one the Dart side
/// cannot have: **the payload exists and the home screen is not allowed to read
/// it**, which is a watch-only user. All five are rendered, none is blank.
///
/// Deciding this outside the composables is not tidiness. `provideGlance` is a
/// suspend function that may run before the app has ever launched, on a bare
/// `Context` handed over by the system, and the file read belongs there rather
/// than inside a recomposition that the system may run several times for
/// several widget sizes.
sealed interface WeftWidgetState {
    /// No payload at all. The writer deletes it on logout, so this means
    /// "nobody is signed in" rather than "nothing has happened yet".
    data object SignedOut : WeftWidgetState

    /// Signed in, and the home screen may not draw.
    ///
    /// Two ways to get here and one message, because they are one fact to the
    /// person looking at the widget: the payload says
    /// [InboxSnapshot.enabled] false (both surfaces off in Settings), or the
    /// payload is fine but [WeftSnapshotStore.widgetsEnabled] is false (the
    /// watch is on and the home screen is not). Either way the honest thing is
    /// to say so and name the setting, rather than show a sign-in prompt to
    /// someone who is already signed in.
    data object SwitchedOff : WeftWidgetState

    /// There is a payload and it cannot be presented as current.
    ///
    /// Stale past `kSnapshotStaleAfter`, or unreadable. Deliberately one state:
    /// a twelve-hour-old snapshot and a half-written one are both "these counts
    /// are not the truth", and there is nothing a home screen can offer for
    /// either except the same sentence.
    data object Unavailable : WeftWidgetState

    /// A snapshot worth drawing. [InboxSnapshot.rows] may still be empty — an
    /// inbox with no conversations, or one whose every conversation is on an
    /// excluded network — and that is a state the content renders, not an error.
    data class Ready(val snapshot: InboxSnapshot) : WeftWidgetState

    companion object {
        /// Reads the shared container and decides.
        ///
        /// [nowMillis] is passed rather than read so that "is this stale" is a
        /// question that can be asked without waiting twelve hours, the same
        /// reason `buildSnapshot` takes a `now`.
        ///
        /// The order of the checks is the whole of the privacy behaviour, and it
        /// runs fail-closed at every step: no payload loses to nothing, an
        /// unreadable payload never reaches a renderer, and the surface flag is
        /// consulted *before* the rows are looked at rather than after.
        fun read(context: Context, nowMillis: Long): WeftWidgetState {
            val raw = WeftSnapshotStore.payload(context) ?: return SignedOut
            if (!WeftSnapshotStore.widgetsEnabled(context)) return SwitchedOff

            val snapshot = SnapshotFormat.decode(raw) ?: return Unavailable
            if (!snapshot.enabled) return SwitchedOff
            if (snapshot.isStaleAt(nowMillis)) return Unavailable
            return Ready(snapshot)
        }
    }
}
