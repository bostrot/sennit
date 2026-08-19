package com.bostrot.weft.call

import android.os.Build
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.annotation.RequiresApi

/// The service Telecom binds to build a [WeftConnection].
///
/// Thin on purpose. Everything it does is unpack the `Bundle` that
/// `CallBridge.report` packed and hand back a connection, because *this is the
/// class the system may start on its own*: Telecom binds it when a call is
/// placed, which on the incoming path can happen with no activity and no Flutter
/// engine in the process. Any decision made here would be a decision made
/// somewhere Dart cannot see, and the phase's rule is that all three platforms
/// drive one state machine.
///
/// Which is also why a connection whose call id is missing is refused rather
/// than invented: a connection with no call id is one nothing can ever answer,
/// and leaving it ringing is worse than not offering it.
@RequiresApi(Build.VERSION_CODES.O)
class WeftConnectionService : ConnectionService() {

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection? = create(request, incoming = true)

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection? = create(request, incoming = false)

    /// Telecom refused the call — an ordinary phone call is in progress, or the
    /// account is not permitted right now.
    ///
    /// Dart is told rather than left waiting: its state machine has already
    /// accepted the invite and is ringing, and the far end is entitled to a
    /// `m.call.reject` with a reason rather than an invite that times out.
    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        CallNotifications.dismissIncoming(applicationContext)
        CallBridge.onDecline()
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        CallBridge.onHangUp()
    }

    private fun create(request: ConnectionRequest?, incoming: Boolean): Connection? {
        val extras = callExtras(request, incoming) ?: return refuse()
        val callId = extras.getString(CallBridge.EXTRA_CALL_ID) ?: return refuse()

        val connection = WeftConnection(
            context = applicationContext,
            callId = callId,
            displayName = extras.getString(CallBridge.EXTRA_DISPLAY_NAME),
            video = extras.getBoolean(CallBridge.EXTRA_VIDEO, false),
        )
        connection.setAddress(request?.address, TelecomManager.PRESENTATION_ALLOWED)
        CallBridge.onConnectionCreated(connection)
        connection.start(incoming)
        return connection
    }

    /// The bundle the bridge packed, from wherever this direction puts it.
    ///
    /// Telecom hands an incoming call's extras back on the request directly, and
    /// an outgoing call's nested under `EXTRA_OUTGOING_CALL_EXTRAS` — the same
    /// `Bundle` in two places, which is a genuine asymmetry of the API rather
    /// than something either side chose.
    private fun callExtras(request: ConnectionRequest?, incoming: Boolean): Bundle? {
        val extras = request?.extras ?: return null
        if (incoming) return extras
        return extras.getBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS) ?: extras
    }

    private fun refuse(): Connection = Connection.createFailedConnection(
        DisconnectCause(DisconnectCause.ERROR),
    )
}
