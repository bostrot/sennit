package com.bostrot.weft.wear

import android.util.Log
import com.bostrot.weft.snapshot.WeftWearProtocol
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

/// Where a reply from a wrist lands on the phone.
///
/// A `WearableListenerService` is started by the system when a message arrives
/// on a path this app declares, whether or not Weft is running. That is the
/// whole reason the reply path is a queue rather than a call: this can be the
/// component that starts the app's process, in which case there is no Flutter
/// engine and no Matrix session yet, and [WeftWatchChannel] answers the watch
/// rather than pretending.
///
/// Only the reply path is handled here. The *snapshot* travels the other way, as
/// a `DataItem` this device puts and the watch observes, so there is nothing
/// inbound about it — see `WeftWearBridge`.
class WeftWearReplyService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != WeftWearProtocol.PATH_REPLY) return
        val raw = try {
            JSONObject(String(event.data, Charsets.UTF_8))
        } catch (e: Exception) {
            // Malformed, and therefore unreportable: the id is one of the
            // things that can be missing, and a result with no id is a result
            // no watch can match to anything. The watch's own timeout is the
            // only mechanism that covers this.
            Log.d("WeftWear", "unreadable reply from ${event.sourceNodeId}")
            return
        }
        WeftWatchChannel.deliver(applicationContext, event.sourceNodeId, raw)
    }
}
