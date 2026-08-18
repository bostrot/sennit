package com.bostrot.weft.sms

import android.app.Service
import android.content.Intent
import android.net.Uri
import android.os.IBinder
import android.telephony.TelephonyManager
import android.util.Log

/// "Respond via message" — the quick reply on the incoming-call screen.
///
/// Required of the default SMS app: without this service declared, Weft is not
/// eligible for the role, and the dialer's message button has nowhere to go.
///
/// Headless is the whole design. This is started by the *dialer*, while a call
/// is ringing, often over a locked screen, and frequently with Weft not running
/// at all. Starting a Flutter engine to send eight words would take longer than
/// the call rings and would need the user to unlock first — so the send happens
/// entirely in Kotlin, through the same [SmsSender] the app uses, and the
/// message lands in the system provider where Dart will read it the next time
/// it looks. That path is not a shortcut around the app's own send; it is the
/// same write, reached without an engine.
///
/// The service stops itself as soon as the send is handed to the radio.
/// Delivery arrives later on a broadcast, which [SmsStatusReceiver] handles in
/// whatever process is alive by then.
class HeadlessSmsSendService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            handle(intent)
        } catch (e: Exception) {
            // A crash here is a crash on the call screen, in another app's
            // task. There is nothing to show the user and nothing to retry.
            Log.w(TAG, "respond-via-message failed", e)
        }
        stopSelf(startId)
        return START_NOT_STICKY
    }

    private fun handle(intent: Intent?) {
        if (intent?.action != TelephonyManager.ACTION_RESPOND_VIA_MESSAGE) return

        val body = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        if (body.isNullOrEmpty()) return

        for (address in recipients(intent.data)) {
            SmsSender.send(this, address, body)
        }
    }

    /// The numbers behind `sms:`, `smsto:`, `mms:` or `mmsto:`.
    ///
    /// The dialer may pass several, separated by `;` or `,`, and writes them
    /// into the URI's opaque part — `sms:+441234567890`, not `sms://…` — so
    /// `Uri.host` is null here and `schemeSpecificPart` is the only field that
    /// holds anything. An empty list is a normal outcome for a malformed intent
    /// and sends nothing rather than throwing.
    private fun recipients(data: Uri?): List<String> {
        val raw = data?.schemeSpecificPart ?: return emptyList()
        return raw.split(';', ',')
            .map { Uri.decode(it).trim() }
            .filter { it.isNotEmpty() }
    }

    private companion object {
        const val TAG = "WeftSms"
    }
}
