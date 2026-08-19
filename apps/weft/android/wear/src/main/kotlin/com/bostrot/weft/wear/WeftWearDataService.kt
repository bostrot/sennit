package com.bostrot.weft.wear

import android.content.ComponentName
import android.content.Context
import android.util.Log
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import com.bostrot.weft.snapshot.WeftWearProtocol
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

/// Everything that arrives on this watch from the phone.
///
/// Two paths and two shapes, and the shapes are the reason there are two:
///
/// * **The snapshot** is a `DataItem`, because it is *state*. It is stored on
///   both nodes, it survives the watch being out of range, and a watch that
///   reconnects after an hour is handed the current value with the phone doing
///   nothing. That is what a companion surface needs: the question it answers is
///   "what does the inbox look like", and the answer is always current or
///   knowably stale.
/// * **A reply result** is a message, because it is an *event*. It happens once,
///   it must not be replayed onto a node that reconnects tomorrow, and a phone
///   out of range is a fact the wearer needs now rather than a state to sync
///   later.
///
/// Started by the system whether or not the app is running, which is the point:
/// a snapshot that lands while the watch face is up must reach the tile and the
/// complication without anyone opening anything.
class WeftWearDataService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        var touched = false
        for (event in events) {
            if (event.dataItem.uri.path != WeftWearProtocol.PATH_SNAPSHOT) continue
            when (event.type) {
                DataEvent.TYPE_CHANGED -> {
                    val map = DataMapItem.fromDataItem(event.dataItem).dataMap
                    WeftWearStore.store(
                        applicationContext,
                        // Absent whenever the phone withheld it, which is what
                        // "the watch surface is off" looks like on the wire. The
                        // flag is stored either way, because the difference
                        // between "off" and "no item" is a different sentence on
                        // screen.
                        map.getString(WeftWearProtocol.KEY_PAYLOAD),
                        map.getBoolean(WeftWearProtocol.KEY_WATCH_ENABLED, false),
                    )
                    touched = true
                }
                // Sign-out on the phone. The item is deleted rather than
                // emptied, so this branch is the signed-out state arriving.
                DataEvent.TYPE_DELETED -> {
                    WeftWearStore.clear(applicationContext)
                    touched = true
                }
            }
        }
        if (touched) refreshSurfaces(applicationContext)
    }

    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != WeftWearProtocol.PATH_REPLY_RESULT) return
        val raw = try {
            JSONObject(String(event.data, Charsets.UTF_8))
        } catch (e: Exception) {
            // Unmatchable: the id is one of the things that can be missing, and
            // a result with no id belongs to no reply. The outbox's own timeout
            // is what covers this, which is the only mechanism that can.
            Log.d(TAG, "unreadable reply result from ${event.sourceNodeId}")
            return
        }
        WeftWearOutbox.onResult(raw)
    }

    companion object {
        private const val TAG = "WeftWear"

        /// Redraws the two surfaces that are not the app.
        ///
        /// The tile and the complication are drawn by the system, not by this
        /// process, and neither notices a `SharedPreferences` write. The app
        /// itself is not poked: it re-reads on resume and observes the store
        /// while it is up, and waking a foreground Compose hierarchy from a
        /// broadcast is how a watch app acquires a second, racier source of
        /// truth.
        ///
        /// Both are wrapped, because both are optional in a way that is easy to
        /// forget: a watch with no Weft tile placed and no Weft complication on
        /// its face is the normal state of a freshly installed app, and neither
        /// requester is required to be polite about being asked.
        fun refreshSurfaces(context: Context) {
            try {
                androidx.wear.tiles.TileService.getUpdater(context)
                    .requestUpdate(WeftWearTileService::class.java)
            } catch (e: Exception) {
                Log.d(TAG, "no tile to update: ${e.message}")
            }
            try {
                ComplicationDataSourceUpdateRequester
                    .create(
                        context,
                        ComponentName(context, WeftWearComplicationService::class.java),
                    )
                    .requestUpdateAll()
            } catch (e: Exception) {
                Log.d(TAG, "no complication to update: ${e.message}")
            }
        }
    }
}
