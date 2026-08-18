package com.bostrot.weft.sms

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log

/// Hands a message to the radio, and records what came back.
///
/// Sending is three separate events, not one call, and conflating them is how
/// an SMS app comes to show a tick for a message that never left the building:
///
/// 1. the row is written to the provider's **outbox**, which is what the
///    timeline draws as "sending";
/// 2. the *sent* broadcast says the radio accepted it — the row moves to the
///    sent box, or to failed with the reason;
/// 3. the *delivery report*, if the carrier sends one at all, says the handset
///    at the other end received it — the row's `status` column changes and only
///    then has anything been delivered.
///
/// [SmsStatusReceiver] handles 2 and 3. Both are broadcasts because
/// `sendTextMessage` returns `void`: there is no result to await, and a send
/// started from [HeadlessSmsSendService] routinely outlives the process that
/// started it.
object SmsSender {
    private const val TAG = "WeftSms"

    /// Long enough that no plausible clock skew collides two sends, short
    /// enough to stay an `Int` request code.
    private var requestCode = 0

    /// Sends [body] to [address], returning the provider row it wrote.
    ///
    /// Null means the message could not be handed to the radio at all — no
    /// permission, no telephony, a number the platform refuses. It does *not*
    /// mean delivery failed; that answer arrives later, on a broadcast.
    ///
    /// Multipart always, never `sendTextMessage`. A body over one segment sent
    /// as a single message is silently truncated by some stacks and rejected by
    /// others, and `divideMessage` splits on the same septet boundaries
    /// `segmentMessage` counts in `weft_sms` — so what the composer warned
    /// about and what the radio does are the same split.
    fun send(
        context: Context,
        address: String,
        body: String,
        subscriptionId: Int? = null,
        timestampMs: Long = System.currentTimeMillis(),
    ): Map<String, Any?>? {
        val manager = smsManager(context, subscriptionId) ?: run {
            Log.w(TAG, "no SmsManager; device has no telephony")
            return null
        }

        val rowUri = SmsProvider.writeOutbox(context, address, body, timestampMs, subscriptionId)
        val parts = manager.divideMessage(body)

        return try {
            manager.sendMultipartTextMessage(
                address,
                null,
                parts,
                // One PendingIntent per part. The last part's result is the
                // one that decides the message: an earlier part failing takes
                // the whole thing down with it, and a status receiver that
                // moved the row to "sent" on part one would then be
                // overwriting its own failure.
                parts.mapIndexed { index, _ ->
                    statusIntent(context, SmsStatusReceiver.ACTION_SENT, rowUri, index == parts.lastIndex)
                }.let { ArrayList(it) },
                parts.mapIndexed { index, _ ->
                    statusIntent(
                        context,
                        SmsStatusReceiver.ACTION_DELIVERED,
                        rowUri,
                        index == parts.lastIndex,
                    )
                }.let { ArrayList(it) },
            )
            rowUri?.let { SmsProvider.messageAt(context, it) }
        } catch (e: Exception) {
            // The send itself threw — an unroutable address, or the role
            // revoked between the write and the call. The row exists and must
            // not be left claiming to be on its way.
            Log.w(TAG, "send to $address failed", e)
            rowUri?.let {
                SmsProvider.updateType(context, it, Telephony.Sms.MESSAGE_TYPE_FAILED)
                SmsProvider.messageAt(context, it)
            }
        }
    }

    /// The `SmsManager` for [subscriptionId], or the default subscription.
    ///
    /// Dual-SIM is the normal case on a lot of the world's phones, and a reply
    /// that goes out on the other SIM arrives from a number the recipient does
    /// not recognise — and is billed to the wrong account.
    private fun smsManager(context: Context, subscriptionId: Int?): SmsManager? = try {
        val base = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        if (subscriptionId != null && subscriptionId >= 0) {
            base?.createForSubscriptionId(subscriptionId)
        } else {
            base
        }
    } catch (e: Exception) {
        null
    }

    private fun statusIntent(
        context: Context,
        action: String,
        rowUri: Uri?,
        last: Boolean,
    ): PendingIntent {
        val intent = Intent(context, SmsStatusReceiver::class.java).apply {
            this.action = action
            putExtra(SmsStatusReceiver.EXTRA_ROW_URI, rowUri?.toString())
            putExtra(SmsStatusReceiver.EXTRA_LAST_PART, last)
        }
        return PendingIntent.getBroadcast(
            context,
            requestCode++,
            intent,
            // MUTABLE: the system fills in the result code and, for a delivery
            // report, the PDU. An immutable one arrives with neither, which
            // looks exactly like a message that was never acknowledged.
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
    }
}

/// Send outcomes and delivery reports, landing as broadcasts.
///
/// Registered in the manifest rather than at runtime because the process that
/// called `send` is frequently gone by the time the carrier answers — a
/// respond-via-message from the call screen starts a service, sends, and stops
/// itself in under a second, while a delivery report can take minutes.
class SmsStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Only the last part decides the message's state; the earlier ones are
        // received and dropped so that a three-segment message does not report
        // three outcomes for one bubble.
        if (!intent.getBooleanExtra(EXTRA_LAST_PART, true)) return
        val uri = intent.getStringExtra(EXTRA_ROW_URI)?.let(Uri::parse) ?: return

        when (intent.action) {
            ACTION_SENT -> {
                val ok = resultCode == Activity.RESULT_OK
                SmsProvider.updateType(
                    context,
                    uri,
                    if (ok) Telephony.Sms.MESSAGE_TYPE_SENT else Telephony.Sms.MESSAGE_TYPE_FAILED,
                )
            }
            ACTION_DELIVERED -> {
                // A report arrives whether it says delivered or not, and the
                // distinction is in the PDU's status byte. Anything that fails
                // to parse is treated as delivered rather than failed: the
                // report only exists because the network acknowledged the
                // message, and inventing a failure from an unreadable PDU is
                // worse than the missing detail.
                val failed = deliveryFailed(intent)
                SmsProvider.updateStatus(
                    context,
                    uri,
                    if (failed) Telephony.Sms.STATUS_FAILED else Telephony.Sms.STATUS_COMPLETE,
                    failed = failed,
                )
            }
            else -> return
        }

        SmsProvider.messageAt(context, uri)?.let { SmsBridge.deliverStatus(it) }
    }

    private fun deliveryFailed(intent: Intent): Boolean = try {
        val pdu = intent.getByteArrayExtra("pdu")
        val format = intent.getStringExtra("format")
        val message = if (pdu != null) {
            android.telephony.SmsMessage.createFromPdu(pdu, format)
        } else {
            null
        }
        // 3GPP TS 23.040 §9.2.3.15: 0x00–0x1F is success or pending, 0x40 and
        // above is a permanent or temporary failure.
        message != null && message.status >= 0x40
    } catch (e: Exception) {
        false
    }

    companion object {
        const val ACTION_SENT = "com.bostrot.weft.sms.SENT"
        const val ACTION_DELIVERED = "com.bostrot.weft.sms.DELIVERED"
        const val EXTRA_ROW_URI = "rowUri"
        const val EXTRA_LAST_PART = "lastPart"
    }
}
