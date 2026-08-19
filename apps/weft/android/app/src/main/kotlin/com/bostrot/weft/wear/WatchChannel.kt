package com.bostrot.weft.wear

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.bostrot.weft.snapshot.WeftWearProtocol
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/// Android's end of `com.bostrot.weft/watch`.
///
/// The counterpart of `WeftWatchChannel` in `ios/Runner/WatchChannel.swift` —
/// same channel name, same three methods, a `MessageClient` instead of a
/// `WCSession`. The Dart side (`WeftWatchBridge`) does not branch on platform.
///
/// ## Why this holds static state, when `WeftSnapshotChannel` does not
///
/// The snapshot channel is called *by* Dart and answers. This one is called by a
/// watch, from a `WearableListenerService` the system started — a different
/// component, with no reference to the engine, at a moment the app did not
/// choose. Something has to hold the answer to "is there a Dart handler alive to
/// give this to", and the alternative to a static is asking the service to find
/// the engine, which means an engine cache, a name for it, and a second lifetime
/// to get wrong.
///
/// Held as a nullable rather than a list: there is one engine, and a second
/// registration replaces the first, which is what happens when the activity is
/// recreated.
object WeftWatchChannel {
    const val CHANNEL = "com.bostrot.weft/watch"

    private var channel: MethodChannel? = null

    /// The node a reply arrived from, by reply id, so its result can be sent
    /// back to the watch that asked rather than to every paired one.
    ///
    /// Bounded, and by the same reasoning as Dart's `_handled` queue: this is a
    /// lookup for the seconds between a reply and its result, not a record.
    private val origins = LinkedHashMap<String, String>()

    private const val ORIGIN_MEMORY = 64

    private val main = Handler(Looper.getMainLooper())

    fun register(context: Context, engine: FlutterEngine) {
        val application = context.applicationContext
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "reportReply" -> {
                    reportReply(application, call.argument<String>("id"), call)
                    result.success(null)
                }
                // Sign-out. The Dart side has already failed back everything it
                // was holding; this only drops the origins, so a reply that
                // arrives afterwards is answered as "the app is not running" —
                // which, for the purpose of sending a message, it is not.
                "stopWatch" -> {
                    origins.clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        this.channel = channel
    }

    /// Hands a reply to Dart, or answers the watch when there is nobody to hand
    /// it to.
    ///
    /// Called from [WeftWearReplyService], which the system may have started
    /// without an activity and therefore without an engine. Answering
    /// [WeftWearProtocol.FAILURE_APP_NOT_RUNNING] there is the honest reply: the
    /// message genuinely was not sent, the watch says so, and the user opens
    /// Weft. The alternative — starting an engine and a Matrix session from a
    /// background broadcast to send one line of text — is a cost the user pays
    /// on every reply for a case they can resolve in a tap.
    fun deliver(context: Context, nodeId: String, reply: JSONObject) {
        val id = reply.optString(WeftWearProtocol.REPLY_ID)
        val chatId = reply.optString(WeftWearProtocol.REPLY_CHAT_ID)
        val body = reply.optString(WeftWearProtocol.REPLY_BODY)
        // Refused rather than guessed at, the same three fields Dart's
        // `WatchReply.fromJson` requires. A reply with no id cannot even be
        // reported on.
        if (id.isEmpty() || chatId.isEmpty() || body.isBlank()) return

        val channel = this.channel
        if (channel == null) {
            sendResult(context, nodeId, id, sent = false,
                failure = WeftWearProtocol.FAILURE_APP_NOT_RUNNING, network = null)
            return
        }

        remember(id, nodeId)
        // `MethodChannel` is main-thread only, and `onMessageReceived` is not on
        // it. Posting rather than blocking: the service's callback returning is
        // what lets the system release the wake lock it started us under.
        main.post {
            channel.invokeMethod(
                "onWatchReply",
                mapOf(
                    WeftWearProtocol.REPLY_ID to id,
                    WeftWearProtocol.REPLY_CHAT_ID to chatId,
                    WeftWearProtocol.REPLY_BODY to body,
                )
            )
        }
    }

    private fun reportReply(context: Context, id: String?, call: io.flutter.plugin.common.MethodCall) {
        if (id.isNullOrEmpty()) return
        val nodeId = origins.remove(id) ?: return
        sendResult(
            context,
            nodeId,
            id,
            sent = call.argument<Boolean>(WeftWearProtocol.RESULT_SENT) ?: false,
            failure = call.argument<String>(WeftWearProtocol.RESULT_FAILURE),
            network = call.argument<String>(WeftWearProtocol.RESULT_NETWORK),
        )
    }

    private fun sendResult(
        context: Context,
        nodeId: String,
        id: String,
        sent: Boolean,
        failure: String?,
        network: String?,
    ) {
        val payload = JSONObject()
        payload.put(WeftWearProtocol.REPLY_ID, id)
        payload.put(WeftWearProtocol.RESULT_SENT, sent)
        if (failure != null) payload.put(WeftWearProtocol.RESULT_FAILURE, failure)
        if (network != null) payload.put(WeftWearProtocol.RESULT_NETWORK, network)
        WeftWearBridge.sendReplyResult(
            context, nodeId, payload.toString().toByteArray(Charsets.UTF_8))
    }

    private fun remember(id: String, nodeId: String) {
        origins[id] = nodeId
        while (origins.size > ORIGIN_MEMORY) {
            val oldest = origins.keys.firstOrNull() ?: break
            origins.remove(oldest)
        }
    }
}
