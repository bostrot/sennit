package com.bostrot.weft.wear

import android.content.Context
import android.util.Log
import com.bostrot.weft.snapshot.WeftWearProtocol
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import org.json.JSONObject
import java.util.UUID

/// What became of a reply this watch asked the phone to send.
sealed interface WeftReplyState {
    /// Handed to the Data Layer, no answer yet.
    data object Sending : WeftReplyState

    /// The phone said it sent it. [network] is present only for a merged
    /// conversation, where naming the leg is the difference between a
    /// confirmation and a guess.
    data class Sent(val network: String?) : WeftReplyState

    /// It did not go. [failure] is one of `WeftWearProtocol`'s ids, or null when
    /// the watch itself gave up waiting.
    data class Failed(val failure: String?) : WeftReplyState
}

/// The watch's outgoing replies, and the one place this device can cause a
/// write anywhere.
///
/// **It cannot send a message.** It asks the phone to, over
/// [WeftWearProtocol.PATH_REPLY], and shows the answer. There is no Matrix
/// session on this device, no key material, and no homeserver — this app does
/// not even hold the `INTERNET` permission.
///
/// A process-wide object rather than a view model, because the answer arrives at
/// [WeftWearDataService] — a component the system starts — and the screen that
/// asked may have been swiped away by then. Holding the state here means the
/// wearer who dismissed the reply screen and came back finds out what happened,
/// rather than an empty list and a message they cannot tell was sent.
object WeftWearOutbox {
    private const val TAG = "WeftWear"

    /// How long a reply waits before this side calls it failed.
    ///
    /// Longer than the phone's own two-minute queue, and deliberately: the phone
    /// is allowed to hold a reply while its inbox syncs, and a watch that gave up
    /// first would show "not sent" for a message that then went. Long enough to
    /// cover that, short enough that "sending…" is never the last thing this
    /// screen ever says.
    private val timeoutMillis = 3 * 60 * 1000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _replies = MutableStateFlow<Map<String, WeftReplyState>>(emptyMap())

    /// Every reply this process has sent, by id. Collected by the reply screen.
    val replies: StateFlow<Map<String, WeftReplyState>> = _replies

    /// Asks the phone to send [body] to [chatId], and returns the id to watch.
    ///
    /// The id is minted here rather than on the phone, and it is the whole of
    /// the duplicate protection: `sendMessage` fails when the phone is
    /// unreachable and this retries against every connected node, so a reply
    /// sent at the edge of range can arrive twice. The phone answers a
    /// redelivery with the original result rather than sending a second message
    /// — see `WatchReplyHandler`.
    fun send(context: Context, chatId: String, body: String): String {
        val id = UUID.randomUUID().toString()
        _replies.update { it + (id to WeftReplyState.Sending) }

        val payload = JSONObject()
            .put(WeftWearProtocol.REPLY_ID, id)
            .put(WeftWearProtocol.REPLY_CHAT_ID, chatId)
            .put(WeftWearProtocol.REPLY_BODY, body)
            .toString()
            .toByteArray(Charsets.UTF_8)

        val application = context.applicationContext
        scope.launch {
            val delivered = deliver(application, payload)
            if (!delivered) {
                // Nothing on the other end to hand it to. Reported as the phone
                // not running rather than as a send failure, because no send was
                // attempted and telling the wearer their message failed to send
                // would have them retype it at a phone that never saw it.
                fail(id, WeftWearProtocol.FAILURE_APP_NOT_RUNNING)
                return@launch
            }
            delay(timeoutMillis)
            // Null failure: this side gave up, and it does not know why. The
            // screen says so in those terms rather than inventing a cause.
            if (_replies.value[id] is WeftReplyState.Sending) fail(id, null)
        }
        return id
    }

    /// Applies a result from the phone.
    ///
    /// Ignores an id it does not know: a result for a reply sent by a previous
    /// launch of this app arrives after the map has been rebuilt empty, and
    /// resurrecting it would put a message on screen that nothing is showing.
    fun onResult(raw: JSONObject) {
        val id = raw.optString(WeftWearProtocol.REPLY_ID)
        if (id.isEmpty()) return
        val sent = raw.optBoolean(WeftWearProtocol.RESULT_SENT, false)
        val state = if (sent) {
            WeftReplyState.Sent(
                raw.optString(WeftWearProtocol.RESULT_NETWORK).takeIf { it.isNotEmpty() })
        } else {
            WeftReplyState.Failed(
                raw.optString(WeftWearProtocol.RESULT_FAILURE).takeIf { it.isNotEmpty() })
        }
        _replies.update { if (it.containsKey(id)) it + (id to state) else it }
    }

    /// Sends to every connected node, and reports whether any accepted it.
    ///
    /// Every node rather than a chosen one: a watch's connected-node set is its
    /// phone, and the alternative — a `CapabilityClient` lookup — is a second
    /// round trip before the first one to answer a question with one answer. A
    /// phone that receives it twice is protected by the reply id; a wearer whose
    /// message went nowhere is not protected by anything.
    private suspend fun deliver(context: Context, payload: ByteArray): Boolean {
        return try {
            val nodes = Wearable.getNodeClient(context).connectedNodes.await()
            var any = false
            for (node in nodes) {
                try {
                    Wearable.getMessageClient(context)
                        .sendMessage(node.id, WeftWearProtocol.PATH_REPLY, payload)
                        .await()
                    any = true
                } catch (e: Exception) {
                    Log.d(TAG, "reply did not reach ${node.displayName}: ${e.message}")
                }
            }
            any
        } catch (e: Exception) {
            Log.d(TAG, "no data layer to send a reply over: ${e.message}")
            false
        }
    }

    private fun fail(id: String, failure: String?) {
        _replies.update {
            if (it[id] is WeftReplyState.Sending) it + (id to WeftReplyState.Failed(failure)) else it
        }
    }
}
