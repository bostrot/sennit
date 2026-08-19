package com.bostrot.weft.wear

import android.content.Context
import android.content.SharedPreferences
import com.bostrot.weft.snapshot.SnapshotFormat
import com.bostrot.weft.snapshot.WeftWearProtocol
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.tasks.await

/// Where the snapshot lives on the watch.
///
/// A `SharedPreferences` file, for the same reason the phone uses one:
/// [WeftWearTileService] and [WeftWearComplicationService] are woken by the
/// system with a bare `Context` and no app state, and this is the cheapest
/// durable thing such a process can read. Querying the Data Layer from a tile
/// request instead would mean an asynchronous round trip inside a callback the
/// system times out.
///
/// It is a **cache of the `DataItem`, not a second source of truth.** The phone
/// owns the payload; [WeftWearDataService] writes here when one arrives and
/// [sync] backfills on the one occasion no change event will ever fire — the
/// first launch after installing this app onto a watch already paired to a phone
/// that published before it existed.
object WeftWearStore {
    /// Named for what it holds rather than for the app. Public because the app
    /// observes it directly: a `SharedPreferences` change listener is how a
    /// foreground screen finds out that a system-started service has just
    /// written a new snapshot into it.
    const val PREFS_NAME = "weft_snapshot"

    /// The encoded `InboxSnapshot`, exactly as `SnapshotCodec` produced it.
    ///
    /// Absent whenever the watch surface is switched off, because the phone
    /// withholds it rather than blanking it — see `WeftWearBridge.publish`. So a
    /// payload here is a payload this device was allowed to be given.
    private const val KEY_PAYLOAD = "payload"

    /// Whether this device may render it. Its *presence* is also how "there is
    /// an item" is told from "there is none", which is the signed-out state.
    private const val KEY_WATCH = "watch"

    /// Stores what arrived.
    ///
    /// `commit`, not `apply`: the caller is a `WearableListenerService` whose
    /// next act is to wake a tile and a complication that read this file, and an
    /// `apply` writing on a background thread would have them render the
    /// previous snapshot roughly as often as the new one. The same call the
    /// phone's store makes, for the same reason.
    fun store(context: Context, payload: String?, watchEnabled: Boolean) {
        val editor = prefs(context).edit().putBoolean(KEY_WATCH, watchEnabled)
        if (payload == null) editor.remove(KEY_PAYLOAD) else editor.putString(KEY_PAYLOAD, payload)
        editor.commit()
    }

    /// Sign-out on the phone, or an item deleted.
    ///
    /// Removes the flag as well as the payload, which is what makes this
    /// distinguishable from "switched off": an absent flag is an absent item is
    /// nobody signed in. See `InboxSnapshot` for the three states and
    /// [WeftWearState] for the five this side draws.
    fun clear(context: Context) {
        prefs(context).edit().clear().commit()
    }

    fun payload(context: Context): String? = prefs(context).getString(KEY_PAYLOAD, null)

    /// Whether the phone has published anything to this watch at all.
    fun hasItem(context: Context): Boolean = prefs(context).contains(KEY_WATCH)

    /// Whether this device may draw. Fail-closed, like every other read of this
    /// gate on either platform.
    fun watchEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_WATCH, false)

    /// Reads the current `DataItem` straight from the Data Layer.
    ///
    /// The backfill, and the one call here that is not a file read.
    /// `onDataChanged` fires on a *change*, and installing this app is not one —
    /// a watch paired to a phone that published an hour ago has the item sitting
    /// in the Data Layer and would otherwise show its signed-out state until the
    /// phone's next write, which can be three hours away.
    ///
    /// Answers rather than throwing: no Play services, no paired phone, and a
    /// watch that has never been connected are all ordinary, and all of them
    /// leave the cache exactly as it was.
    suspend fun sync(context: Context): Boolean {
        return try {
            val uri = android.net.Uri.Builder()
                .scheme("wear")
                .path(WeftWearProtocol.PATH_SNAPSHOT)
                .build()
            val items = Wearable.getDataClient(context.applicationContext)
                .getDataItems(uri)
                .await()
            var found = false
            try {
                for (item in items) {
                    val map = DataMapItem.fromDataItem(item).dataMap
                    val enabled = map.getBoolean(WeftWearProtocol.KEY_WATCH_ENABLED, false)
                    store(context, map.getString(WeftWearProtocol.KEY_PAYLOAD), enabled)
                    found = true
                }
            } finally {
                // `DataItemBuffer` holds a native buffer and leaks it otherwise.
                // The one piece of Data Layer bookkeeping this app cannot skip.
                items.release()
            }
            // No item is a real answer, not a failed read: the phone deletes on
            // sign-out, and the watch has to stop showing conversations for an
            // account nobody is signed into.
            if (!found) clear(context)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}

/// What a watch surface has to draw, decided once so the app, the tile and the
/// complication decide it the same way.
///
/// The five states `WeftWidgetState` has, case for case, on both other
/// platforms. Three hand-written renderers of one payload is already two more
/// than anyone wants; three that disagreed about *which* states exist would be
/// worse than any of them.
///
/// The fifth — a payload present and this surface not allowed to draw it — is
/// reached differently here than on a home screen and means the same thing
/// inverted: a **widgets-only user**, whose phone published the item with the
/// flag off and no rows in it.
sealed interface WeftWearState {
    /// No item at all. The phone deletes on sign-out, so this is "nobody is
    /// signed in on the phone" rather than "nothing has happened yet".
    data object SignedOut : WeftWearState

    /// There is an item and this watch may not draw it.
    data object SwitchedOff : WeftWearState

    /// There is a payload and it cannot be presented as current: stale past
    /// `kSnapshotStaleAfter`, or unreadable. One state deliberately — a
    /// twelve-hour-old snapshot and a half-written one are the same fact to the
    /// person reading them, and the sentence for both is the phase brief's own:
    /// *open Weft on your phone*.
    data object Unavailable : WeftWearState

    /// Worth drawing. `rows` may still be empty, which the content renders
    /// rather than treating as an error.
    data class Ready(
        override val snapshot: com.bostrot.weft.snapshot.InboxSnapshot,
    ) : WeftWearState

    /// The snapshot when there is one worth drawing, null otherwise.
    ///
    /// On the interface rather than only on [Ready] so that every renderer here
    /// reads one property instead of each writing its own `as? Ready`. Narrowed
    /// to non-null by [Ready], which is what lets the reply screen look a row up
    /// without a cast.
    val snapshot: com.bostrot.weft.snapshot.InboxSnapshot?
        get() = null

    /// The unread total this state may show, which is zero for every state that
    /// is not [Ready].
    ///
    /// Explicit rather than implied, for the reason the Swift mirror gives: the
    /// complication's entire content is this number, and "the number when we
    /// have one" is the sort of rule that gets re-derived at a call site as a
    /// sum over the visible rows — which is wrong, because `totalUnread` counts
    /// the conversations past the row cap too.
    val totalUnread: Int get() = snapshot?.totalUnread ?: 0

    companion object {
        /// Reads the cache and decides.
        ///
        /// [nowMillis] is passed rather than read, so "is this stale" is a
        /// question a test can ask without waiting twelve hours.
        ///
        /// The order is the whole of the privacy behaviour and it is fail-closed
        /// at every step: no item loses to nothing, the surface flag is
        /// consulted *before* the payload is looked at, and an unreadable
        /// payload never reaches a renderer.
        fun read(context: Context, nowMillis: Long): WeftWearState {
            if (!WeftWearStore.hasItem(context)) return SignedOut
            if (!WeftWearStore.watchEnabled(context)) return SwitchedOff
            val raw = WeftWearStore.payload(context) ?: return SwitchedOff
            val snapshot = SnapshotFormat.decode(raw) ?: return Unavailable
            if (!snapshot.enabled) return SwitchedOff
            if (snapshot.isStaleAt(nowMillis)) return Unavailable
            return Ready(snapshot)
        }
    }
}
