package com.bostrot.weft.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/// `WAP_PUSH_DELIVER` — an MMS has arrived at the carrier.
///
/// The receiver exists for two reasons, and only the first is about MMS at all.
///
/// **Eligibility.** Android will not offer an app the default-SMS role unless
/// it declares this receiver, alongside [SmsReceiver] and
/// [HeadlessSmsSendService] and the four SMS permissions. An app missing any
/// one of them does not appear in the "Default SMS app" picker — with no error,
/// no log line and nothing to debug. So this class is load-bearing whether or
/// not a single MMS is ever retrieved.
///
/// **What actually arrives.** Not the message: a WAP push carrying an
/// `M-Notification.ind` PDU, which says *that* an MMS is waiting and where to
/// fetch it. Retrieving it is a separate HTTP transaction against the carrier's
/// MMSC, over the MMS APN, and the fetched PDU then has to be parsed and
/// written into `content://mms` part by part. Android exposes the transport
/// (`SmsManager.downloadMultimediaMessage`) but **not** the PDU encoder or
/// parser — `com.google.android.mms.pdu` is hidden API, which is why every
/// third-party SMS app on the store vendors a copy of AOSP's version.
///
/// Weft does not vendor it yet, so this receiver **does not download MMS**. It
/// acknowledges the push and tells Dart one arrived, which is enough for the
/// conversation to say so honestly. Received MMS already in the provider — put
/// there by whichever app held the role before — are read and shown normally by
/// `SmsProvider.messages`; it is only *new* ones that stop here.
///
/// This is stated in a comment rather than fixed quietly because the failure is
/// otherwise invisible: an MMS that is never fetched looks exactly like an MMS
/// nobody sent.
class MmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.WAP_PUSH_DELIVER_ACTION) return
        if (intent.type != MMS_MIME_TYPE) return

        val pdu = intent.getByteArrayExtra("data")
        Log.i(TAG, "MMS notification received (${pdu?.size ?: 0} bytes); retrieval not implemented")

        // No provider row is written. A placeholder in `content://mms` would be
        // a message the rest of the phone — and the user's next SMS app —
        // reads as real and can never fill in.
        SmsBridge.deliverMmsPush(
            mapOf(
                "sizeBytes" to (pdu?.size ?: 0),
                "subscriptionId" to intent.getIntExtra("subscription", -1),
                "receivedAt" to System.currentTimeMillis(),
            ),
        )
    }

    private companion object {
        const val TAG = "WeftSms"
        const val MMS_MIME_TYPE = "application/vnd.wap.mms-message"
    }
}
