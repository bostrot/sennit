package com.bostrot.weft.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/// `SMS_DELIVER` — a received text, delivered to the default app and no one
/// else.
///
/// Two obligations, in this order, and the order is the point:
///
/// 1. **Write it to the system provider.** No other app on the device will.
///    `SMS_DELIVER` is not `SMS_RECEIVED` — the read-only broadcast every app
///    gets — and nothing in the platform stores the message on the default
///    app's behalf. Skipping this write does not lose the message from *Weft*;
///    it loses it from the phone.
/// 2. **Tell Dart**, so the thread updates while the app is open. Best-effort:
///    Flutter may not be running, and [SmsBridge] queues for that case, but a
///    process that dies before Dart attaches is a message re-read from the
///    provider rather than one that never happened.
///
/// A multipart message arrives here as several PDUs in one intent, already
/// reassembled by the platform in the sense that they all turn up together —
/// but not concatenated. Joining them is this receiver's job, and a receiver
/// that reads only `messages[0]` shows the first 153 characters of a long text
/// and drops the rest.
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return

        val parts = try {
            Telephony.Sms.Intents.getMessagesFromIntent(intent)
        } catch (e: Exception) {
            Log.w(TAG, "unreadable SMS_DELIVER payload", e)
            null
        } ?: return
        if (parts.isEmpty()) return

        val first = parts.first()
        val address = first.displayOriginatingAddress ?: first.originatingAddress ?: return
        val body = parts.joinToString("") { it.displayMessageBody ?: it.messageBody ?: "" }
        // The network's timestamp, not this device's: a message held by the
        // carrier while the phone was off is ordered by when it was sent, which
        // is the order the conversation actually happened in.
        val timestamp = first.timestampMillis.takeIf { it > 0 } ?: System.currentTimeMillis()
        val subscriptionId = intent.getIntExtra("subscription", -1).takeIf { it >= 0 }

        val row = SmsProvider.writeInbox(context, address, body, timestamp, subscriptionId)
        if (row == null) {
            Log.w(TAG, "received a message that could not be stored")
            return
        }
        SmsBridge.deliverReceived(row)
    }

    private companion object {
        const val TAG = "WeftSms"
    }
}
