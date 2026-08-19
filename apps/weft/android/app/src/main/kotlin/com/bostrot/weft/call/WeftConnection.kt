package com.bostrot.weft.call

import android.content.Context
import android.os.Build
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.DisconnectCause
import androidx.annotation.RequiresApi

/// One Weft call, as Telecom sees it.
///
/// Every override here is a *system* surface for something Weft's own call
/// screen also offers — the lock screen's answer button, the notification's
/// decline, a headset's hook switch, the car's hold. None of them do the work:
/// each forwards to [CallBridge], which forwards to Dart, which drives
/// `CallStateMachine`. That indirection is the phase's own constraint and the
/// reason for it is that a call answered from a car dashboard and a call
/// answered from the app must reach the *same* machine, or the two disagree
/// about whether an `m.call.answer` has been sent.
///
/// The only things this class decides for itself are what it tells Telecom back:
/// a connection that never calls `setActive` leaves a call ringing in the system
/// forever, and one that calls it early puts a running duration on a call with
/// no media.
@RequiresApi(Build.VERSION_CODES.O)
class WeftConnection(
    private val context: Context,
    val callId: String,
    private val displayName: String?,
    private val video: Boolean,
) : Connection() {

    init {
        connectionCapabilities = CAPABILITY_MUTE or CAPABILITY_HOLD or CAPABILITY_SUPPORT_HOLD
        audioModeIsVoip = true
        setCallerDisplayName(displayName ?: callId, TelecomPresentation.ALLOWED)
        // `setInitializing` rather than `setActive`: the call exists but nothing
        // has been answered. `setRinging`/`setDialing` follow from the service,
        // which is the only place that knows which direction it is.
        setInitializing()
    }

    /// Whether the far end has been answered, so a disconnect knows whether it
    /// is a hangup or a decline. Telecom's `onDisconnect` is the same callback
    /// for both.
    private var answered = false

    override fun onShowIncomingCallUi() {
        // Self-managed calls draw their own. The notification is posted from
        // `CallBridge.report` rather than here because this callback only fires
        // when the screen is on and unlocked — the locked case, which is the
        // case that matters, never reaches it.
        CallNotifications.showIncoming(context, callId, displayName ?: callId, video)
    }

    override fun onAnswer() {
        answered = true
        setActive()
        CallNotifications.dismissIncoming(context)
        CallForegroundService.start(context, displayName ?: callId, video)
        CallBridge.onAnswer()
    }

    /// The video-aware overload, which is what Telecom actually calls on a
    /// self-managed connection. `videoState` is ignored on purpose: whether the
    /// call carries video was decided by the offer and is already on the
    /// session; a system answer button carries no opinion about the camera, and
    /// letting it set one would turn "answer" into "answer with video" on
    /// hardware that happens to report `BIDIRECTIONAL`.
    @Deprecated("Overrides a member deprecated in the framework", ReplaceWith("onAnswer()"))
    override fun onAnswer(videoState: Int) = onAnswer()

    override fun onReject() {
        CallNotifications.dismissIncoming(context)
        CallBridge.onDecline()
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
    }

    override fun onDisconnect() {
        // One callback, two events on the wire. A call that was never answered
        // is `m.call.reject` and shows as "declined" in Element; one that was is
        // `m.call.hangup` and shows as "call ended". Only this flag distinguishes
        // them, because Telecom does not.
        if (answered) CallBridge.onHangUp() else CallBridge.onDecline()
        CallNotifications.dismissIncoming(context)
        CallForegroundService.stop(context)
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
    }

    override fun onAbort() = onDisconnect()

    override fun onHold() {
        setOnHold()
        CallBridge.onSetHeld(true)
    }

    override fun onUnhold() {
        setActive()
        CallBridge.onSetHeld(false)
    }

    /// Mute and route, from the system side: a headset's own mute button, the
    /// car's speaker toggle, a Bluetooth device connecting mid-call.
    ///
    /// Deprecated from Android 12 in favour of `onCallEndpointChanged`, which
    /// does not exist below it — so this remains the only callback that fires on
    /// every API level Weft supports. The successor reports the same two facts.
    @Deprecated("Overrides a member deprecated in the framework")
    @Suppress("DEPRECATION")
    override fun onCallAudioStateChanged(state: CallAudioState) {
        CallBridge.onSetMuted(state.isMuted)
        CallBridge.onAudioRouteChanged(routeName(state.route))
    }

    /// Marks the call as ringing, and starts the foreground service for an
    /// outgoing one.
    fun start(incoming: Boolean) {
        if (incoming) {
            setRinging()
        } else {
            setDialing()
            answered = true
            CallForegroundService.start(context, displayName ?: callId, video)
        }
    }

    /// Moves the system's own buttons to match a change made inside Weft.
    ///
    /// Mute is deliberately not forwarded. Telecom's mute is a property of the
    /// *audio state*, which only the in-call service owns; a self-managed
    /// connection can read it and cannot set it. Weft's own mute therefore lives
    /// in the app and in WebRTC, and the system's mute button remains an input
    /// rather than a mirror — which is honest, and better than a button that
    /// looks synchronised and is not.
    fun applyLocalState(muted: Boolean?, held: Boolean?) {
        if (held == null) return
        if (held) setOnHold() else setActive()
    }

    private fun routeName(route: Int): String = when (route) {
        CallAudioState.ROUTE_BLUETOOTH -> "bluetooth"
        CallAudioState.ROUTE_WIRED_HEADSET -> "wiredHeadset"
        CallAudioState.ROUTE_SPEAKER -> "speaker"
        else -> "earpiece"
    }

    /// Telecom's presentation constants live on `TelecomManager` on some API
    /// levels and on `Connection` on others; naming the one value used keeps the
    /// difference in a single place.
    private object TelecomPresentation {
        const val ALLOWED = android.telecom.TelecomManager.PRESENTATION_ALLOWED
    }
}
