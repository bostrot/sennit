package com.bostrot.weft.sms

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// `com.bostrot.weft/sms` — the one seam between Android's SMS stack and Dart.
///
/// A singleton, unlike the intents channel that lives on `MainActivity`, and
/// for a reason that is the whole difficulty of this feature: a received SMS
/// arrives at a `BroadcastReceiver`, which has no activity, may run while Weft
/// is in the background, and can be the thing that *starts* the process in the
/// first place. The receiver needs somewhere to hand a message that exists
/// whether or not a Flutter engine does.
///
/// So messages are queued when nothing is attached, and Dart drains the queue
/// with `getPending` once it is listening — the same replay `MainActivity` does
/// for a cold-start share intent. The queue is a latency optimisation, not the
/// system of record: every message was written to the system provider before it
/// got here, so a process killed between the two is a message Dart re-reads on
/// its next pass rather than one that is lost.
object SmsBridge {
    private const val CHANNEL = "com.bostrot.weft/sms"

    /// Past this many queued messages the oldest are dropped.
    ///
    /// The queue only grows while Dart is not listening, and it is backed by
    /// the provider, so a bound trades a replay nobody would notice against an
    /// unbounded list in a process that may run for days.
    private const val MAX_PENDING = 100

    private val main = Handler(Looper.getMainLooper())
    private val pending = mutableListOf<Map<String, Any?>>()

    private var channel: MethodChannel? = null
    private var activity: Activity? = null

    /// Held while the role dialog is up: the answer is an activity result, and
    /// the Dart call that asked for it is still waiting.
    private var roleRequest: MethodChannel.Result? = null

    /// Wires the channel to [engine] and remembers [host] for the role request.
    fun attach(host: Activity, engine: FlutterEngine) {
        activity = host
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result -> handle(host, call.method, call.arguments, result) }
        }
    }

    /// Drops the engine references. The queue survives — the activity going
    /// away does not stop messages arriving.
    ///
    /// A pending role request is answered *before* the activity reference goes,
    /// and answered with the truth. The old code sent `false` here, which is how
    /// a granted role came back as "Nothing changed": the role dialog is a
    /// system activity on top of ours, and an activity destroyed underneath it —
    /// "don't keep activities", a low-memory device — reached this line while
    /// the user was still deciding. [SmsRole.outcomeFor] asks the system who
    /// holds the role instead, and falls back to `interrupted` rather than to a
    /// decline the user never made.
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        val waiting = roleRequest
        roleRequest = null
        waiting?.success(SmsRole.outcomeFor(activity, SmsRole.Outcome.INTERRUPTED))
        activity = null
    }

    /// Forwards a received message, or queues it when Dart is not listening.
    fun deliverReceived(message: Map<String, Any?>) = deliver("onSmsReceived", message)

    /// Forwards the arrival of an MMS Weft cannot yet download.
    ///
    /// Queued like a received message: it is the same kind of event — something
    /// reached the device while Dart may not have been listening — and the
    /// conversation is entitled to say an MMS arrived even though its contents
    /// are not retrievable. See [MmsReceiver] for why they are not.
    fun deliverMmsPush(push: Map<String, Any?>) = deliver("onMmsPush", push)

    /// Forwards a send outcome or delivery report.
    ///
    /// Never queued. The provider row has already been updated, so a status
    /// that misses the channel is re-read with the message rather than replayed
    /// on its own — and a queued *status* for a message Dart has not seen yet
    /// would arrive as an update to nothing.
    fun deliverStatus(message: Map<String, Any?>) {
        main.post { channel?.invokeMethod("onSmsStatus", message) }
    }

    private fun deliver(method: String, message: Map<String, Any?>) {
        main.post {
            val target = channel
            if (target == null) {
                if (pending.size >= MAX_PENDING) pending.removeAt(0)
                // Tagged with the method it would have been sent as, so a
                // replay is indistinguishable from a live delivery on the Dart
                // side — a queue that flattened the two would turn an MMS
                // notification into a text with no body.
                pending += mapOf("event" to method, "payload" to message)
            } else {
                target.invokeMethod(method, message)
            }
        }
    }

    /// Completes a pending `requestRole` with the user's answer.
    ///
    /// Called from `MainActivity.onActivityResult`. Returns whether the result
    /// belonged to this bridge, so the activity can pass on anything else.
    ///
    /// The dialog's own result code is not consulted. It reports whether the
    /// *dialog* completed, not what the system did with it, and the two
    /// disagree often enough to matter — a user who was already the default
    /// gets a cancelled result. The only honest answer is to ask the system who
    /// holds the role now, which is what [SmsRole.outcomeFor] does; a "no" that
    /// got this far is a decline, because the dialog was shown.
    fun onRoleResult(requestCode: Int): Boolean {
        if (requestCode != SmsRole.REQUEST_CODE) return false
        val waiting = roleRequest ?: return true
        roleRequest = null
        waiting.success(SmsRole.outcomeFor(activity, SmsRole.Outcome.DENIED))
        return true
    }

    private fun handle(
        context: Context,
        method: String,
        arguments: Any?,
        result: MethodChannel.Result,
    ) {
        val args = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        when (method) {
            "getStatus" -> result.success(SmsRole.status(context))

            // Answers with an [SmsRole.Outcome] string rather than a boolean.
            // Which of the four "not granted" answers this is decides what the
            // screen says, and a boolean could only ever say the one wrong
            // thing — see the phase-05 diagnosis note.
            "requestRole" -> {
                val host = activity
                if (host == null) {
                    // No activity to raise a dialog from. The user was not
                    // asked, so this is not a decline.
                    result.success(SmsRole.Outcome.UNAVAILABLE)
                    return
                }
                if (SmsRole.isDefault(host)) {
                    result.success(SmsRole.Outcome.GRANTED)
                    return
                }
                // A second request while a dialog is already up is answered
                // rather than left hanging: two futures waiting on one
                // activity result is a deadlock for whichever loses. The loser
                // is told it was superseded, not that it was refused.
                roleRequest?.success(SmsRole.Outcome.SUPERSEDED)
                roleRequest = result
                if (!SmsRole.request(host)) {
                    roleRequest = null
                    result.success(SmsRole.Outcome.UNAVAILABLE)
                }
            }

            "openDefaultAppSettings" ->
                result.success(SmsRole.openDefaultAppSettings(activity ?: context))

            "getThreads" -> result.success(
                SmsProvider.threads(context, args.int("limit") ?: SmsProvider.DEFAULT_LIMIT),
            )

            "getMessages" -> {
                val threadId = args.string("threadId")
                if (threadId == null) {
                    result.error("bad_args", "threadId is required", null)
                } else {
                    result.success(
                        SmsProvider.messages(
                            context,
                            threadId,
                            args.int("limit") ?: SmsProvider.DEFAULT_LIMIT,
                        ),
                    )
                }
            }

            "sendMessage" -> {
                val address = args.string("address")
                val body = args.string("body")
                if (address == null || body == null) {
                    result.error("bad_args", "address and body are required", null)
                } else if (!SmsRole.isDefault(context)) {
                    // Sending is possible without the role — SEND_SMS alone
                    // allows it — but the sent copy would never be written and
                    // the conversation would show one side of itself. Refusing
                    // is the honest failure.
                    result.error("not_default", "Sennit is not the default SMS app", null)
                } else {
                    result.success(
                        SmsSender.send(context, address, body, args.int("subscriptionId")),
                    )
                }
            }

            "markThreadRead" -> {
                val threadId = args.string("threadId")
                if (threadId == null) {
                    result.error("bad_args", "threadId is required", null)
                } else {
                    result.success(SmsProvider.markThreadRead(context, threadId))
                }
            }

            "getPending" -> {
                val drained = pending.toList()
                pending.clear()
                result.success(drained)
            }

            else -> result.notImplemented()
        }
    }

    private fun Map<*, *>.string(key: String): String? = this[key] as? String

    private fun Map<*, *>.int(key: String): Int? = (this[key] as? Number)?.toInt()
}
