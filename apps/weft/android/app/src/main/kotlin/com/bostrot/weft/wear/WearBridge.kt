package com.bostrot.weft.wear

import android.content.Context
import android.util.Log
import com.bostrot.weft.snapshot.SnapshotFormat
import com.bostrot.weft.snapshot.WeftWearProtocol
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable

/// The phone's end of the Wearable Data Layer.
///
/// Everything that leaves this device for a watch goes through here, and it is
/// deliberately the only file in `:app` that links `play-services-wearable`.
/// `WeftSnapshotStore.notifySurfaces` says why it does not do this itself: the
/// Data Layer client is a dependency the home screen widgets have no use for,
/// and a `PutDataRequest` from the store would put it in the one file every
/// Glance provider already reads.
///
/// ## Nothing here fails loudly
///
/// Every call site is a chat-list listener that runs on every message, or a
/// sign-out that must complete. A device with no watch paired, no Play services
/// installed, or a `GoogleApiClient` that cannot connect is the ordinary case on
/// the overwhelming majority of Android phones — it is not an error, and it must
/// not surface as one several times a minute.
object WeftWearBridge {
    private const val TAG = "WeftWear"

    /// Publishes the snapshot to every paired node, or takes it back.
    ///
    /// [watch] false still *publishes*, with the flag off and the payload
    /// dropped. That is the difference between "you may not draw this" and
    /// "there is nothing here", and the watch renders them differently — the
    /// same three-state distinction `InboxSnapshot` draws and for the same
    /// reason. Sending the rows anyway and trusting the watch not to draw them
    /// would be handing a device the conversations its user asked it not to be
    /// given.
    fun publish(context: Context, json: String, watch: Boolean) {
        // Checked here as well as in the store, because this transport has a
        // lower ceiling than the one that already passed: the Data Layer rejects
        // an asset-free `DataItem` over 100 KB outright, and a rejection arrives
        // as a failed `Task` long after the call that caused it.
        if (json.toByteArray(Charsets.UTF_8).size > SnapshotFormat.MAX_PAYLOAD_BYTES) return

        put(context) { map ->
            map.putBoolean(WeftWearProtocol.KEY_WATCH_ENABLED, watch)
            // The payload is withheld rather than blanked when the surface is
            // off, so a watch cannot render rows it was told it may not have
            // even if it ignores the flag. Fail-closed at the transport, not
            // only at the renderer.
            if (watch) map.putString(WeftWearProtocol.KEY_PAYLOAD, json)
        }
    }

    /// Sign-out. Removes the item rather than emptying it.
    ///
    /// An absent item is how the watch tells "nobody is signed in" from "signed
    /// in and switched off", exactly as an absent file does on the phone. See
    /// `InboxSnapshot` for the three states.
    fun clear(context: Context) {
        try {
            Wearable.getDataClient(context.applicationContext)
                .deleteDataItems(
                    android.net.Uri.Builder()
                        .scheme("wear")
                        .path(WeftWearProtocol.PATH_SNAPSHOT)
                        .build()
                )
        } catch (e: Exception) {
            Log.d(TAG, "no data layer to clear: ${e.message}")
        }
    }

    /// Tells a watch what became of a reply.
    ///
    /// Sent to [nodeId] — the node the reply came from — rather than broadcast.
    /// Two watches paired to one phone is unusual and entirely legal, and the
    /// one that did not dictate the message has no business being told it was
    /// sent.
    fun sendReplyResult(context: Context, nodeId: String, payload: ByteArray) {
        try {
            Wearable.getMessageClient(context.applicationContext)
                .sendMessage(nodeId, WeftWearProtocol.PATH_REPLY_RESULT, payload)
                .addOnFailureListener {
                    // The watch has its own timeout for exactly this. Nothing
                    // here can retry usefully: the message was sent, and telling
                    // the user twice that it might not have been is worse than
                    // letting their watch time out once.
                    Log.d(TAG, "reply result did not reach $nodeId: ${it.message}")
                }
        } catch (e: Exception) {
            Log.d(TAG, "no data layer for reply result: ${e.message}")
        }
    }

    /// Puts one `DataMap` at [WeftWearProtocol.PATH_SNAPSHOT].
    ///
    /// `setUrgent`, and it is not decoration: without it the system may hold a
    /// data item for up to half an hour to batch radio use. That is the correct
    /// default for most apps and the wrong one here — the snapshot is already
    /// written only when it *changed*, so every put is a home screen and a wrist
    /// currently showing something that is no longer true.
    private fun put(context: Context, fill: (com.google.android.gms.wearable.DataMap) -> Unit) {
        try {
            val request = PutDataMapRequest.create(WeftWearProtocol.PATH_SNAPSHOT)
            // The Data Layer deduplicates by content: a byte-identical `DataMap`
            // put twice never reaches `onDataChanged` on the watch. That is
            // usually a feature and here it is a trap — `SnapshotWriter` rewrites
            // an unchanged payload every three hours precisely so a surface does
            // not drift into its stale state, and without this stamp that
            // rewrite would be swallowed and the watch would go stale anyway.
            request.dataMap.putLong(WeftWearProtocol.KEY_UPDATED_AT, System.currentTimeMillis())
            fill(request.dataMap)
            Wearable.getDataClient(context.applicationContext)
                .putDataItem(request.asPutDataRequest().setUrgent())
                .addOnFailureListener { Log.d(TAG, "snapshot not published: ${it.message}") }
        } catch (e: Exception) {
            Log.d(TAG, "no data layer to publish to: ${e.message}")
        }
    }
}
