package com.bostrot.weft.call

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.bostrot.weft.R

/// Android's end of `com.bostrot.weft/call`: Telecom, and nothing else.
///
/// A singleton for the same reason [SmsBridge] is one, and the reason is
/// stronger here. A `ConnectionService` is started *by the system*: Telecom
/// binds it when a call is placed, and — once a VoIP push or a background sync
/// reports one — while Weft has no activity and possibly no Flutter engine. The
/// connection needs somewhere to hand an answer that exists whether or not Dart
/// does.
///
/// So the same replay trick: an action arriving with no channel attached is
/// held, and delivered when one is. Unlike SMS there is no queue — only the
/// *last* action matters, because they are all about one call and Weft carries
/// one at a time. A user who presses answer twice has answered once.
///
/// ## Self-managed, not managed
///
/// The phone account is registered with `CAPABILITY_SELF_MANAGED`, which is the
/// difference between Weft appearing in the system dialer's account picker
/// (wrong: Weft does not place telephone calls) and Weft's calls merely being
/// *known* to Telecom so that a cellular call and a Weft call cannot both have
/// the audio at once. Self-managed also means the system draws no incoming-call
/// UI — the app must — which is what [CallNotifications] is for.
@SuppressLint("StaticFieldLeak")
object CallBridge {
    const val CHANNEL = "com.bostrot.weft/call"

    /// The phone account's id. Stable across launches: Telecom keys registered
    /// accounts by it, and a new id every launch would leave a trail of dead
    /// accounts in the system's list.
    private const val ACCOUNT_ID = "weft.calls"

    /// Keys on the `Bundle` a connection is created with.
    const val EXTRA_CALL_ID = "com.bostrot.weft.call.CALL_ID"
    const val EXTRA_DISPLAY_NAME = "com.bostrot.weft.call.DISPLAY_NAME"
    const val EXTRA_VIDEO = "com.bostrot.weft.call.VIDEO"

    private val main = Handler(Looper.getMainLooper())

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    /// The connection Telecom is holding, and the call it belongs to.
    ///
    /// One, not a map — see the class comment. `callId` is kept separately
    /// because it outlives the connection by a moment: a disconnect has to name
    /// the call it ended after the connection has already been destroyed.
    private var connection: WeftConnection? = null
    private var callId: String? = null

    /// An action the user took before Dart was listening — answering from the
    /// lock screen on a cold start. Replayed on attach, exactly as
    /// `MainActivity` replays a cold-start share intent.
    private var pendingAction: Pair<String, Map<String, Any?>>? = null

    /// Wires the channel to [engine]. Called from `MainActivity`.
    fun attach(context: Context, engine: FlutterEngine) {
        appContext = context.applicationContext
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result -> handle(call, result) }
        }
        registerPhoneAccount(context)

        pendingAction?.let { (method, arguments) ->
            pendingAction = null
            main.post { channel?.invokeMethod(method, arguments) }
        }
    }

    /// Drops the engine reference. The connection survives: an activity going
    /// away does not end a call, and Telecom still holds it.
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // -------------------------------------------------------------------------
    // The phone account.
    // -------------------------------------------------------------------------

    fun accountHandle(context: Context): PhoneAccountHandle = PhoneAccountHandle(
        ComponentName(context.applicationContext, WeftConnectionService::class.java),
        ACCOUNT_ID,
    )

    /// Registers Weft as a self-managed calling app.
    ///
    /// Idempotent — registering an account that exists updates it — so this runs
    /// on every attach rather than being tracked, for the same reason
    /// `LocalNotificationSink` creates its channels on every launch: it is also
    /// how a renamed label reaches a device installed a year ago.
    ///
    /// Returns false on the devices that have no Telecom self-managed support at
    /// all (below API 26) and on the ones whose manufacturer removed it. Both are
    /// a call without a system call log, not a call that cannot happen.
    ///
    /// `CAPABILITY_SELF_MANAGED` is marked deprecated from Android 16 in favour
    /// of `androidx.core.telecom`, which is a Jetpack library and a second
    /// dependency. It is still the only way to register a self-managed account
    /// on every API level Weft supports, and the framework path is not removed —
    /// so this is a migration for when the minimum SDK moves, not a bug.
    @Suppress("DEPRECATION")
    fun registerPhoneAccount(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
            ?: return false
        return try {
            val account = PhoneAccount.builder(accountHandle(context), "Weft")
                .setCapabilities(
                    PhoneAccount.CAPABILITY_SELF_MANAGED or
                        PhoneAccount.CAPABILITY_SUPPORTS_VIDEO_CALLING or
                        PhoneAccount.CAPABILITY_VIDEO_CALLING,
                )
                // The scheme Telecom hands back on the address of a connection.
                // `sip` rather than `tel`, because a Matrix id is an address and
                // not a telephone number, and `tel` would put it in front of a
                // dialer that would try to ring it.
                .addSupportedUriScheme(PhoneAccount.SCHEME_SIP)
                .setShortDescription(context.getString(R.string.call_phone_account))
                .build()
            telecom.registerPhoneAccount(account)
            true
        } catch (e: Exception) {
            // A manufacturer ROM that refuses the registration. Logged nowhere
            // the user can see, because there is nothing they could do about it
            // and the call still works.
            false
        }
    }

    // -------------------------------------------------------------------------
    // Dart → Telecom.
    // -------------------------------------------------------------------------

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val context = appContext
        if (context == null) {
            result.success(null)
            return
        }

        when (call.method) {
            "reportIncomingCall" -> {
                val id = args.string("callId")
                if (id == null) {
                    result.error("bad_args", "callId is required", null)
                } else {
                    result.success(
                        report(
                            context,
                            id,
                            handle = args.string("handle") ?: id,
                            displayName = args.string("displayName"),
                            video = args.bool("video") ?: false,
                            incoming = true,
                        ),
                    )
                }
            }

            "reportOutgoingCall" -> {
                val id = args.string("callId")
                if (id == null) {
                    result.error("bad_args", "callId is required", null)
                } else {
                    result.success(
                        report(
                            context,
                            id,
                            handle = args.string("handle") ?: id,
                            displayName = args.string("displayName"),
                            video = args.bool("video") ?: false,
                            incoming = false,
                        ),
                    )
                }
            }

            "reportCallConnected" -> {
                if (args.string("callId") == callId) {
                    connection?.setActive()
                    CallNotifications.dismissIncoming(context)
                }
                result.success(null)
            }

            "reportCallEnded" -> {
                if (args.string("callId") == callId) {
                    disconnect(context, causeFor(args.string("reason")))
                }
                result.success(null)
            }

            "updateCall" -> {
                if (args.string("callId") == callId) {
                    // Telecom has no "the app muted itself" API. `onCallAudioStateChanged`
                    // is how a mute *arrives*; the way one is announced is to set
                    // the audio state, and the connection is the only thing that
                    // can. Hold is different: `setOnHold`/`setActive` do move the
                    // system's own button.
                    connection?.applyLocalState(
                        muted = args.bool("muted"),
                        held = args.bool("held"),
                    )
                }
                result.success(null)
            }

            "setProximityEnabled" -> {
                result.success(ProximityLock.setEnabled(context, args.bool("enabled") ?: false))
            }

            else -> result.notImplemented()
        }
    }

    /// Puts a call in front of Telecom, and returns whether it took it.
    ///
    /// A refusal is not an error. Telecom declines a self-managed call while an
    /// ordinary phone call is in progress, and on Android that is the correct
    /// outcome — but Weft's own state machine has already accepted the invite,
    /// so the refusal is turned straight back into a decline rather than left as
    /// a call ringing in an app the system does not know about.
    private fun report(
        context: Context,
        id: String,
        handle: String,
        displayName: String?,
        video: Boolean,
        incoming: Boolean,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            // No self-managed Telecom. The in-app call surfaces are the whole
            // UI on these devices, which is also what desktop gets.
            if (incoming) CallNotifications.showIncoming(context, id, displayName ?: handle, video)
            return false
        }

        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
            ?: return false
        val account = accountHandle(context)
        callId = id

        val extras = Bundle().apply {
            putString(EXTRA_CALL_ID, id)
            putString(EXTRA_DISPLAY_NAME, displayName)
            putBoolean(EXTRA_VIDEO, video)
        }
        // A `sip:` URI so the address is an address. Telecom shows it in the
        // call log and hands it back on the connection.
        val address = Uri.fromParts(PhoneAccount.SCHEME_SIP, handle, null)

        return try {
            if (incoming) {
                extras.putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, address)
                extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account)
                telecom.addNewIncomingCall(account, extras)
                // Posted regardless of whether the connection materialises: a
                // self-managed app draws its own incoming-call UI, and this is
                // the one that survives the screen being locked. It is dismissed
                // by `reportCallConnected` or by the disconnect.
                CallNotifications.showIncoming(context, id, displayName ?: handle, video)
            } else {
                val outgoing = Bundle().apply {
                    putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account)
                    putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, extras)
                }
                telecom.placeCall(address, outgoing)
            }
            true
        } catch (e: SecurityException) {
            // MANAGE_OWN_CALLS not granted — it is a normal permission, so this
            // means the account registration was refused rather than the user
            // saying no. Fall back to Weft's own UI.
            if (incoming) CallNotifications.showIncoming(context, id, displayName ?: handle, video)
            false
        } catch (e: Exception) {
            if (incoming) CallNotifications.showIncoming(context, id, displayName ?: handle, video)
            false
        }
    }

    private fun causeFor(reason: String?): Int = when (reason) {
        "declined" -> DisconnectCause.REJECTED
        "missed" -> DisconnectCause.MISSED
        "answeredElsewhere" -> DisconnectCause.ANSWERED_ELSEWHERE
        "busy" -> DisconnectCause.BUSY
        "failed" -> DisconnectCause.ERROR
        else -> DisconnectCause.LOCAL
    }

    /// Tears the connection down and takes every surface with it.
    fun disconnect(context: Context, cause: Int) {
        connection?.let {
            it.setDisconnected(DisconnectCause(cause))
            it.destroy()
        }
        connection = null
        callId = null
        CallNotifications.dismissIncoming(context)
        CallForegroundService.stop(context)
        ProximityLock.setEnabled(context, false)
    }

    // -------------------------------------------------------------------------
    // Telecom → Dart.
    // -------------------------------------------------------------------------

    /// Called by [WeftConnectionService] once Telecom has built the connection.
    fun onConnectionCreated(created: WeftConnection) {
        connection = created
        callId = created.callId
    }

    fun onAnswer() = send("onAnswer")

    fun onDecline() = send("onDecline")

    fun onHangUp() = send("onHangUp")

    fun onSetMuted(muted: Boolean) = send("onSetMuted", mapOf("muted" to muted))

    fun onSetHeld(held: Boolean) = send("onSetHeld", mapOf("held" to held))

    /// The system moved the audio — a headset button, or the call screen's own
    /// speaker toggle. Names match `CallAudioRoute` on the Dart side exactly.
    fun onAudioRouteChanged(route: String) = send("onAudioRouteChanged", mapOf("route" to route))

    private fun send(method: String, extra: Map<String, Any?> = emptyMap()) {
        val payload = HashMap<String, Any?>(extra)
        payload["callId"] = callId
        main.post {
            val target = channel
            if (target == null) {
                pendingAction = method to payload
            } else {
                target.invokeMethod(method, payload)
            }
        }
    }

    private fun Map<*, *>.string(key: String): String? = this[key] as? String

    private fun Map<*, *>.bool(key: String): Boolean? = this[key] as? Boolean
}
