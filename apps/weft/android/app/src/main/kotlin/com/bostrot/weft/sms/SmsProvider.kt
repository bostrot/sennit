package com.bostrot.weft.sms

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.Telephony
import android.telephony.PhoneNumberUtils
import android.telephony.TelephonyManager
import android.util.Log
import java.util.Locale

/// The system SMS/MMS provider, read and written.
///
/// Weft keeps no SMS database of its own, and that is not a shortcut. The
/// default SMS app is the *only* app on the device that writes to
/// `content://sms` — every other messaging app, every backup tool and whatever
/// the user switches to next reads what this object wrote. A default app that
/// kept its messages privately would make the user's SMS history vanish for the
/// rest of the phone, and the loss would only surface the day they switched
/// away.
///
/// Everything here is a `ContentResolver` call and a cursor turned into a map.
/// No decisions: whether an address is a person, what a body costs to send and
/// how a row's type and status become a delivery state all live in
/// `packages/weft_sms`, in pure Dart, tested without a device. The map keys
/// below are that package's field names and are the whole contract between the
/// two sides — `sms_platform.dart` decodes them into `SmsMessage`/`SmsThread`.
object SmsProvider {
    private const val TAG = "WeftSms"

    /// How many rows a read returns unless the caller says otherwise.
    ///
    /// A thread with ten years of messages exists, and the whole of it does not
    /// need to cross a method channel to draw a screenful.
    const val DEFAULT_LIMIT = 200

    /// `content://mms-sms/canonical-addresses` — the numbers a thread's
    /// `recipient_ids` point into. Not exposed as a constant by `Telephony`.
    private val CANONICAL_ADDRESSES: Uri = Uri.parse("content://mms-sms/canonical-addresses")

    /// The `addr` sub-table of one MMS: `content://mms/<id>/addr`.
    private const val MMS_ADDR_PATH = "addr"

    /// `PduHeaders.FROM` — the address type meaning "the sender".
    private const val MMS_ADDRESS_TYPE_FROM = 137

    /// The SMIL layout part every MMS carries, which is not an attachment.
    private const val MMS_SMIL_TYPE = "application/smil"

    // --- Reads -------------------------------------------------------------

    /// Conversations, most recently active first.
    ///
    /// Read from the `simple=true` view of `content://mms-sms/conversations`,
    /// which unifies SMS and MMS into one row per thread — the alternative is
    /// two queries and a merge that gets the ordering wrong whenever a thread's
    /// last message is an MMS.
    fun threads(context: Context, limit: Int = DEFAULT_LIMIT): List<Map<String, Any?>> {
        val uri = Telephony.Threads.CONTENT_URI.buildUpon()
            .appendQueryParameter("simple", "true")
            .build()
        val addresses = canonicalAddresses(context)
        val unread = unreadCounts(context)
        val region = deviceRegion(context)
        val threads = mutableListOf<Map<String, Any?>>()

        query(
            context,
            uri,
            null,
            null,
            null,
            "${Telephony.Threads.DATE} DESC",
        )?.use { cursor ->
            while (cursor.moveToNext() && threads.size < limit) {
                val id = cursor.longOrNull(Telephony.Threads._ID) ?: continue
                val recipients = cursor.stringOrNull(Telephony.Threads.RECIPIENT_IDS)
                    ?.trim()
                    ?.split(" ")
                    ?.mapNotNull { addresses[it] }
                    ?: emptyList()
                threads += mapOf(
                    "id" to id.toString(),
                    "addresses" to recipients,
                    "e164" to e164Of(recipients, region),
                    "snippet" to cursor.stringOrNull(Telephony.Threads.SNIPPET),
                    "unreadCount" to (unread[id.toString()] ?: 0),
                    "lastMessageAt" to cursor.longOrNull(Telephony.Threads.DATE),
                    // The provider has no archive column in the simple view;
                    // archiving is Weft's own state, kept where the rest of a
                    // chat's local state is.
                    "archived" to false,
                )
            }
        }
        return threads
    }

    /// Every message in [threadId], oldest first, SMS and MMS interleaved.
    fun messages(
        context: Context,
        threadId: String,
        limit: Int = DEFAULT_LIMIT,
    ): List<Map<String, Any?>> {
        val rows = mutableListOf<Map<String, Any?>>()
        rows += smsRows(context, threadId, limit)
        rows += mmsRows(context, threadId, limit)
        rows.sortBy { it["timestamp"] as? Long ?: 0L }
        // Trimmed from the *front*: when a thread has more messages than the
        // limit, the wanted end is the recent one.
        return if (rows.size > limit) rows.subList(rows.size - limit, rows.size) else rows
    }

    /// The one message at [uri], or null if it has been deleted since.
    ///
    /// What a send hands back, so the row Dart shows is the row the provider
    /// actually stored rather than a hopeful reconstruction of it.
    fun messageAt(context: Context, uri: Uri): Map<String, Any?>? {
        return query(context, uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) smsRow(cursor) else null
        }
    }

    // --- Writes ------------------------------------------------------------

    /// Stores a received message, returning its row.
    ///
    /// The obligation the role carries. Called from [SmsReceiver] before
    /// anything is forwarded to Dart, because Flutter may not be running and a
    /// message that reached the device must survive that.
    fun writeInbox(
        context: Context,
        address: String,
        body: String,
        timestampMs: Long,
        subscriptionId: Int? = null,
    ): Map<String, Any?>? {
        val uri = insert(
            context,
            Telephony.Sms.Inbox.CONTENT_URI,
            address,
            body,
            timestampMs,
            Telephony.Sms.MESSAGE_TYPE_INBOX,
            read = false,
            subscriptionId = subscriptionId,
        ) ?: return null
        return messageAt(context, uri)
    }

    /// Stores a message on its way out, returning the row's URI.
    ///
    /// The outbox, not the sent folder, and the difference is visible to the
    /// user: `MESSAGE_TYPE_OUTBOX` is what `smsDeliveryState` reads as
    /// [DeliveryState.sending]. The row is moved to `MESSAGE_TYPE_SENT` by
    /// [SmsStatusReceiver] when the radio confirms it left, and to
    /// `MESSAGE_TYPE_FAILED` when it did not — so a message that never made it
    /// off the device cannot sit in the thread wearing a tick.
    ///
    /// A URI rather than a row because the caller's next move is to update it.
    fun writeOutbox(
        context: Context,
        address: String,
        body: String,
        timestampMs: Long,
        subscriptionId: Int? = null,
    ): Uri? = insert(
        context,
        Telephony.Sms.CONTENT_URI,
        address,
        body,
        timestampMs,
        Telephony.Sms.MESSAGE_TYPE_OUTBOX,
        read = true,
        subscriptionId = subscriptionId,
    )

    /// Moves the message at [uri] into another box — sent, or failed.
    fun updateType(context: Context, uri: Uri, type: Int): Boolean {
        val values = ContentValues().apply { put(Telephony.Sms.TYPE, type) }
        return try {
            context.contentResolver.update(uri, values, null, null) > 0
        } catch (e: Exception) {
            Log.w(TAG, "could not move $uri to type $type", e)
            false
        }
    }

    /// Records what a delivery report said about the message at [uri].
    ///
    /// [status] is a `Telephony.Sms.STATUS_*` value; `smsDeliveryState` in
    /// `weft_sms` is what turns it into ticks.
    fun updateStatus(context: Context, uri: Uri, status: Int, failed: Boolean = false): Boolean {
        val values = ContentValues().apply {
            put(Telephony.Sms.STATUS, status)
            if (failed) put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_FAILED)
        }
        return try {
            context.contentResolver.update(uri, values, null, null) > 0
        } catch (e: Exception) {
            Log.w(TAG, "could not update status for $uri", e)
            false
        }
    }

    /// Marks every message in [threadId] read, returning how many changed.
    ///
    /// Provider state, not Weft's: the unread badge in the *system* — and in
    /// whatever SMS app the user opens next — is this column.
    fun markThreadRead(context: Context, threadId: String): Int {
        val values = ContentValues().apply {
            put(Telephony.Sms.READ, 1)
            put(Telephony.Sms.SEEN, 1)
        }
        return try {
            context.contentResolver.update(
                Telephony.Sms.CONTENT_URI,
                values,
                "${Telephony.Sms.THREAD_ID} = ? AND ${Telephony.Sms.READ} = 0",
                arrayOf(threadId),
            )
        } catch (e: Exception) {
            Log.w(TAG, "could not mark thread $threadId read", e)
            0
        }
    }

    // --- Internals ---------------------------------------------------------

    private fun insert(
        context: Context,
        target: Uri,
        address: String,
        body: String,
        timestampMs: Long,
        type: Int,
        read: Boolean,
        subscriptionId: Int?,
    ): Uri? {
        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, timestampMs)
            put(Telephony.Sms.DATE_SENT, timestampMs)
            put(Telephony.Sms.TYPE, type)
            put(Telephony.Sms.READ, if (read) 1 else 0)
            put(Telephony.Sms.SEEN, if (read) 1 else 0)
            subscriptionId?.let { put(Telephony.Sms.SUBSCRIPTION_ID, it) }
        }
        return try {
            context.contentResolver.insert(target, values)
        } catch (e: Exception) {
            // Not fatal and not silent: this is what happens when Weft has lost
            // the role between the broadcast and the write, and the message is
            // still worth showing even if it could not be stored.
            Log.w(TAG, "could not write to $target", e)
            null
        }
    }

    /// The country national-format numbers on this phone were dialled in.
    ///
    /// The SIM's first, because that is the network the number was typed for;
    /// then the network the phone is on; then the locale, which is a guess
    /// but only ever used to *format* a number, never to merge one.
    private fun deviceRegion(context: Context): String? {
        val telephony = context.getSystemService(TelephonyManager::class.java)
        return listOfNotNull(
            telephony?.simCountryIso,
            telephony?.networkCountryIso,
            Locale.getDefault().country,
        ).firstOrNull { it.isNotBlank() }?.uppercase(Locale.ROOT)
    }

    /// Each address Android's libphonenumber can read as a full number, in
    /// E.164. Alphanumeric senders and short codes are left out.
    private fun e164Of(addresses: List<String>, region: String?): Map<String, String> {
        if (region == null) return emptyMap()
        val out = mutableMapOf<String, String>()
        for (address in addresses) {
            val digits = address.count { it.isDigit() }
            if (digits < 7) continue
            val e164 = try {
                PhoneNumberUtils.formatNumberToE164(address, region)
            } catch (error: RuntimeException) {
                null
            }
            if (e164 != null) out[address] = e164
        }
        return out
    }

    /// `canonical_address._id` → the number it holds.
    ///
    /// A thread stores `recipient_ids`, not addresses — space-separated keys
    /// into this table. One query builds the whole map because the alternative
    /// is a query per participant per thread.
    private fun canonicalAddresses(context: Context): Map<String, String> {
        val out = mutableMapOf<String, String>()
        query(context, CANONICAL_ADDRESSES, null, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.stringOrNull("_id") ?: continue
                val address = cursor.stringOrNull("address") ?: continue
                if (address.isNotBlank()) out[id] = address
            }
        }
        return out
    }

    /// thread id → how many received messages in it are unread.
    ///
    /// One query over the unread rows, counted here. The simple conversations
    /// view carries a `read` *flag*, which cannot say "four unread" — and a
    /// per-thread count query would be one round trip per row on screen.
    private fun unreadCounts(context: Context): Map<String, Int> {
        val out = mutableMapOf<String, Int>()
        query(
            context,
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms.THREAD_ID),
            "${Telephony.Sms.READ} = 0 AND ${Telephony.Sms.TYPE} = ?",
            arrayOf(Telephony.Sms.MESSAGE_TYPE_INBOX.toString()),
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.longOrNull(Telephony.Sms.THREAD_ID)?.toString() ?: continue
                out[id] = (out[id] ?: 0) + 1
            }
        }
        return out
    }

    private fun smsRows(context: Context, threadId: String, limit: Int): List<Map<String, Any?>> {
        val rows = mutableListOf<Map<String, Any?>>()
        query(
            context,
            Telephony.Sms.CONTENT_URI,
            null,
            "${Telephony.Sms.THREAD_ID} = ?",
            arrayOf(threadId),
            "${Telephony.Sms.DATE} DESC LIMIT $limit",
        )?.use { cursor ->
            while (cursor.moveToNext()) rows += smsRow(cursor)
        }
        return rows
    }

    private fun smsRow(cursor: Cursor): Map<String, Any?> = mapOf(
        "id" to (cursor.longOrNull(Telephony.Sms._ID)?.toString() ?: ""),
        "threadId" to (cursor.longOrNull(Telephony.Sms.THREAD_ID)?.toString() ?: ""),
        "address" to (cursor.stringOrNull(Telephony.Sms.ADDRESS) ?: ""),
        "body" to (cursor.stringOrNull(Telephony.Sms.BODY) ?: ""),
        "subject" to cursor.stringOrNull(Telephony.Sms.SUBJECT),
        "timestamp" to (cursor.longOrNull(Telephony.Sms.DATE) ?: 0L),
        "type" to (cursor.intOrNull(Telephony.Sms.TYPE) ?: Telephony.Sms.MESSAGE_TYPE_INBOX),
        // -1, not 0: `STATUS_NONE` is "no delivery report was asked for", and
        // 0 is `STATUS_COMPLETE`, i.e. "it was delivered". A missing column
        // must not become a tick nobody earned.
        "status" to (cursor.intOrNull(Telephony.Sms.STATUS) ?: Telephony.Sms.STATUS_NONE),
        "read" to ((cursor.intOrNull(Telephony.Sms.READ) ?: 0) != 0),
    )

    /// MMS rows for [threadId], each with its text folded in and its first real
    /// part named.
    ///
    /// Three sub-queries per message — parts for the body and the attachment,
    /// `addr` for the sender — which is why the limit matters. An MMS carries
    /// its text as a *part*, not a column, so a body read from the message row
    /// alone is always empty.
    private fun mmsRows(context: Context, threadId: String, limit: Int): List<Map<String, Any?>> {
        val rows = mutableListOf<Map<String, Any?>>()
        query(
            context,
            Telephony.Mms.CONTENT_URI,
            null,
            "${Telephony.Mms.THREAD_ID} = ?",
            arrayOf(threadId),
            "${Telephony.Mms.DATE} DESC LIMIT $limit",
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.longOrNull(Telephony.Mms._ID) ?: continue
                val box = cursor.intOrNull(Telephony.Mms.MESSAGE_BOX)
                    ?: Telephony.Mms.MESSAGE_BOX_INBOX
                val outgoing = box == Telephony.Mms.MESSAGE_BOX_SENT ||
                    box == Telephony.Mms.MESSAGE_BOX_OUTBOX
                val parts = mmsParts(context, id)
                rows += mapOf(
                    "id" to "mms-$id",
                    "threadId" to threadId,
                    "address" to (mmsSender(context, id) ?: ""),
                    "body" to parts.text,
                    "subject" to cursor.stringOrNull(Telephony.Mms.SUBJECT),
                    // The one unit mismatch in the provider: `sms.date` is
                    // milliseconds and `mms.date` is seconds. Interleaving the
                    // two without this multiply sorts every MMS to 1970.
                    "timestamp" to ((cursor.longOrNull(Telephony.Mms.DATE) ?: 0L) * 1000L),
                    "type" to if (outgoing) {
                        Telephony.Sms.MESSAGE_TYPE_SENT
                    } else {
                        Telephony.Sms.MESSAGE_TYPE_INBOX
                    },
                    "status" to Telephony.Sms.STATUS_NONE,
                    "read" to ((cursor.intOrNull(Telephony.Mms.READ) ?: 0) != 0),
                    "attachmentUri" to parts.attachmentUri,
                    "attachmentMimeType" to parts.attachmentMimeType,
                    "attachmentSizeBytes" to parts.attachmentSizeBytes,
                )
            }
        }
        return rows
    }

    private class MmsParts(
        val text: String,
        val attachmentUri: String?,
        val attachmentMimeType: String?,
        val attachmentSizeBytes: Int?,
    )

    private fun mmsParts(context: Context, messageId: Long): MmsParts {
        val text = StringBuilder()
        var attachmentUri: String? = null
        var attachmentMimeType: String? = null
        var attachmentSize: Int? = null

        query(
            context,
            Uri.parse("content://mms/part"),
            null,
            "mid = ?",
            arrayOf(messageId.toString()),
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val partId = cursor.longOrNull("_id") ?: continue
                val type = cursor.stringOrNull("ct") ?: continue
                when {
                    type == "text/plain" -> {
                        val body = cursor.stringOrNull("text")
                        if (!body.isNullOrEmpty()) {
                            if (text.isNotEmpty()) text.append('\n')
                            text.append(body)
                        }
                    }
                    // SMIL is the layout, not content — a slideshow's timing,
                    // which no one wants rendered as an attachment.
                    type == MMS_SMIL_TYPE -> Unit
                    attachmentUri == null -> {
                        attachmentUri = "content://mms/part/$partId"
                        attachmentMimeType = type
                        attachmentSize = partSize(context, partId)
                    }
                }
            }
        }
        return MmsParts(text.toString(), attachmentUri, attachmentMimeType, attachmentSize)
    }

    /// Bytes behind an MMS part, or null when the provider will not say.
    ///
    /// There is no size column: the length is the file descriptor's. Null is a
    /// normal answer and means "unknown", which is a different decision from
    /// "empty" everywhere it is read.
    private fun partSize(context: Context, partId: Long): Int? = try {
        context.contentResolver
            .openFileDescriptor(Uri.parse("content://mms/part/$partId"), "r")
            ?.use { it.statSize.coerceAtMost(Int.MAX_VALUE.toLong()).toInt() }
    } catch (e: Exception) {
        null
    }

    /// The number an MMS came from.
    ///
    /// The `addr` sub-table holds every party including this device; type 137
    /// (`PduHeaders.FROM`) is the one that is not us.
    private fun mmsSender(context: Context, messageId: Long): String? {
        val uri = ContentUris.withAppendedId(Telephony.Mms.CONTENT_URI, messageId)
            .buildUpon()
            .appendPath(MMS_ADDR_PATH)
            .build()
        return query(
            context,
            uri,
            null,
            "type = ?",
            arrayOf(MMS_ADDRESS_TYPE_FROM.toString()),
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.stringOrNull("address") else null
        }
    }

    /// Every read goes through here so that one missing permission is an empty
    /// list rather than a crash.
    ///
    /// Weft is expected to run without the role — the SMS network is then
    /// simply absent — and the transition into and out of it is not atomic from
    /// this side: a read can be in flight when the user hands the role to
    /// another app, and the `SecurityException` that follows is a normal event,
    /// not a bug.
    private fun query(
        context: Context,
        uri: Uri,
        projection: Array<String>?,
        selection: String?,
        selectionArgs: Array<String>?,
        sortOrder: String?,
    ): Cursor? = try {
        context.contentResolver.query(uri, projection, selection, selectionArgs, sortOrder)
    } catch (e: SecurityException) {
        Log.i(TAG, "no permission to read $uri")
        null
    } catch (e: Exception) {
        Log.w(TAG, "could not read $uri", e)
        null
    }

    private fun Cursor.stringOrNull(column: String): String? {
        val index = getColumnIndex(column)
        return if (index < 0 || isNull(index)) null else getString(index)
    }

    private fun Cursor.longOrNull(column: String): Long? {
        val index = getColumnIndex(column)
        return if (index < 0 || isNull(index)) null else getLong(index)
    }

    private fun Cursor.intOrNull(column: String): Int? {
        val index = getColumnIndex(column)
        return if (index < 0 || isNull(index)) null else getInt(index)
    }
}
