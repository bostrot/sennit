package com.bostrot.weft.widget

import org.json.JSONObject

/// Kotlin's reader for the payload `SnapshotCodec` writes.
///
/// The Dart side (`packages/weft_snapshot/lib/src/codec.dart`) is the only
/// writer of this format and says so: *"the key names are a cross-language
/// contract. `WeftWidget.swift` and the Glance provider parse this JSON by hand
/// with no Dart on their side of it, so renaming a key here is a silent break
/// there."* This file is that hand-written parser. Every key it reads is spelled
/// once, at the top, so the contract is greppable from this side too.
///
/// ## Why there is no Kotlin encoder
///
/// A widget renders and a widget taps. It never writes the payload back — the
/// snapshot is regenerated from the inbox, not edited — which is also why the
/// Dart codec carries no `extras` round-trip. Unknown keys are ignored here for
/// the same reason: nothing is lost by ignoring them.
///
/// ## Every decode is total
///
/// Same rule as `SnapshotCodec.decode`, and it matters more on this side. The
/// writer is a host app the system can suspend between the first byte of the
/// file and the last; the reader is a `GlanceAppWidget` the OS stops scheduling
/// if it throws, which the user sees as a blank rectangle they eventually
/// delete. So a payload that cannot be read is dropped and the widget falls to
/// [WeftWidgetState.Unavailable] — a state it needs anyway, for a phone that has
/// not been unlocked all day.
object SnapshotFormat {
    /// The version this reader understands. Mirrors `kSnapshotFormatVersion`.
    ///
    /// Load-bearing here, unlike `kStagedShareFormatVersion` on the share path:
    /// a widget process is started and kept by the system on its own schedule
    /// and can be held across an app update, so a reader older than its writer
    /// is the ordinary case. See [InboxSnapshot.isFutureVersion] for what is
    /// done about it, which is degrade rather than refuse.
    const val VERSION = 1

    /// Mirrors `kSnapshotStaleAfter` (12 hours).
    const val STALE_AFTER_MILLIS = 12L * 60 * 60 * 1000

    /// Mirrors `kUnreadBadgeCap`, and it is the one number on this side that
    /// genuinely had to be restated.
    ///
    /// A row's badge arrives pre-formatted as `SnapshotRow.unreadLabel`
    /// precisely so this rule lives in Dart. [InboxSnapshot.totalUnread] does
    /// not: it is a count, not a label, because the Lock Screen accessory and
    /// the watch complication want the number. So the compact tile is the one
    /// renderer that has to apply the cap itself — see [unreadLabel].
    const val UNREAD_BADGE_CAP = 99

    /// [count] as a badge reads it, capped the way `WeftUnreadBadge` caps it.
    fun unreadLabel(count: Int): String =
        if (count > UNREAD_BADGE_CAP) "$UNREAD_BADGE_CAP+" else count.coerceAtLeast(0).toString()

    // The wire contract. One `const` per key so a rename on the Dart side shows
    // up here as a diff rather than as an empty widget.
    private const val KEY_VERSION = "version"
    private const val KEY_GENERATED_AT = "generatedAt"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_TOTAL_UNREAD = "totalUnread"
    private const val KEY_PALETTE = "palette"
    private const val KEY_ROWS = "rows"

    private const val ROW_ID = "id"
    private const val ROW_TITLE = "title"
    private const val ROW_LINK = "link"
    private const val ROW_UNREAD = "unread"
    private const val ROW_UNREAD_LABEL = "unreadLabel"
    private const val ROW_NETWORKS = "networks"
    private const val ROW_MERGED = "merged"
    private const val ROW_PREVIEW = "preview"
    private const val ROW_SENDER = "sender"
    private const val ROW_TIMESTAMP = "timestamp"

    /// Mirrors `kRedactedRowTitle`, for a row that arrives without a title.
    ///
    /// The Dart side already substitutes this when
    /// `SnapshotPolicy.includeSenderNames` is off, so reaching this constant
    /// here means a malformed row rather than a redacted one. It is the same
    /// word either way: a row that renders as an empty line is worse than one
    /// that admits it has no name.
    const val REDACTED_TITLE = "Conversation"

    /// [raw] as a snapshot, or null when it is not a usable one.
    ///
    /// Refused, in every case without throwing: null or blank input; anything
    /// past [WeftSnapshotStore.MAX_PAYLOAD_BYTES], which is what a partially
    /// overwritten file looks like from here; anything the JSON parser rejects,
    /// which is what a write killed partway through looks like. Everything else
    /// degrades — see the field comments below.
    fun decode(raw: String?): InboxSnapshot? {
        if (raw.isNullOrBlank()) return null
        // The same two-step guard `SnapshotCodec.decode` uses, and for the same
        // reason: a UTF-16 code unit is never worth less than one UTF-8 byte, so
        // a string longer than the cap is over it whatever it contains, and the
        // cheap check avoids encoding a payload that is absurd rather than
        // merely too big.
        if (raw.length > WeftSnapshotStore.MAX_PAYLOAD_BYTES) return null
        if (raw.toByteArray(Charsets.UTF_8).size > WeftSnapshotStore.MAX_PAYLOAD_BYTES) return null

        val root = try {
            JSONObject(raw)
        } catch (e: Exception) {
            return null
        }

        val rows = mutableListOf<SnapshotRow>()
        val rawRows = root.optJSONArray(KEY_ROWS)
        if (rawRows != null) {
            for (index in 0 until rawRows.length()) {
                // Rows are skipped individually rather than taking the payload
                // with them: fifteen conversations and one unreadable row is a
                // widget, and no widget is not.
                decodeRow(rawRows.optJSONObject(index))?.let(rows::add)
            }
        }

        return InboxSnapshot(
            // A missing version reads as ours rather than as zero — zero would
            // be indistinguishable from a build older than the format, which
            // has never existed.
            version = root.optInt(KEY_VERSION, VERSION).takeIf { it > 0 } ?: VERSION,
            // A missing timestamp reads as the epoch, which makes the snapshot
            // maximally stale and sends the widget to its "open Weft on your
            // phone" state. That is the right answer for a payload that cannot
            // say when it was written.
            generatedAtMillis = root.optLong(KEY_GENERATED_AT, 0L),
            // A missing flag reads as enabled, because the switched-off payload
            // is the one that states it.
            enabled = root.optBoolean(KEY_ENABLED, true),
            // Falls back to the visible rows rather than to zero: a widget that
            // says "0 unread" while showing rows carrying unread counts is
            // wrong in a way the user reads as messages having been marked read.
            totalUnread = root.optInt(KEY_TOTAL_UNREAD, -1)
                .takeIf { it >= 0 }
                ?: rows.sumOf { it.unreadCount },
            palette = decodePalette(root.optJSONObject(KEY_PALETTE)),
            rows = rows,
        )
    }

    private fun decodeRow(raw: JSONObject?): SnapshotRow? {
        if (raw == null) return null
        // Usable means it has an id: without one the row cannot be tapped, and
        // a row that renders but does nothing is worse than a row that is not
        // there. The link is what a tap actually uses, so a row missing *that*
        // is dropped too — unlike Dart's `SnapshotRow.fromJson`, which can call
        // `chatDeepLink` to rebuild it. This side deliberately cannot: the
        // percent-encoding is `chatDeepLink`'s to own, and a second Kotlin
        // implementation of it is exactly the "link that differs by one escape"
        // that comment warns about.
        val id = raw.optString(ROW_ID).takeIf { it.isNotEmpty() } ?: return null
        val link = raw.optString(ROW_LINK).takeIf { it.isNotEmpty() } ?: return null

        val networks = mutableListOf<String>()
        val rawNetworks = raw.optJSONArray(ROW_NETWORKS)
        if (rawNetworks != null) {
            for (index in 0 until rawNetworks.length()) {
                val network = rawNetworks.optString(index)
                if (network.isNotEmpty()) networks.add(network)
            }
        }

        val unread = raw.optInt(ROW_UNREAD, 0).coerceAtLeast(0)
        return SnapshotRow(
            chatId = id,
            title = raw.optString(ROW_TITLE).takeIf { it.isNotEmpty() } ?: REDACTED_TITLE,
            link = link,
            unreadCount = unread,
            // Formatted in Dart (`SnapshotRow.unreadLabel`) so the `99+` cap is
            // written once rather than once per platform. The local fallback is
            // for a payload that predates the field, not a second rule.
            unreadLabel = raw.optString(ROW_UNREAD_LABEL).takeIf { it.isNotEmpty() }
                ?: unread.toString(),
            networks = networks,
            isMerged = raw.optBoolean(ROW_MERGED, networks.size > 1),
            preview = raw.optString(ROW_PREVIEW).takeIf { it.isNotEmpty() },
            senderName = raw.optString(ROW_SENDER).takeIf { it.isNotEmpty() },
            timestampMillis = raw.optLong(ROW_TIMESTAMP, 0L).takeIf { it > 0L },
        )
    }

    /// `ChatNetwork.id` → `0xAARRGGBB`.
    ///
    /// **Read as `Long` and narrowed, never as `Int`.** An opaque brand colour
    /// has the alpha byte set, so `0xFF25D366` is 4 280 818 534 — half a billion
    /// past `Int.MAX_VALUE`. `optInt` on that returns the *fallback*, silently,
    /// and every network glyph in the widget comes out the same default grey.
    /// The narrowing back to `Int` is the well-defined two's-complement one that
    /// `android.graphics.Color` and Compose's `Color(Int)` both expect.
    private fun decodePalette(raw: JSONObject?): Map<String, Int> {
        if (raw == null) return emptyMap()
        val palette = mutableMapOf<String, Int>()
        for (key in raw.keys()) {
            val value = raw.opt(key)
            if (value is Number) palette[key] = value.toLong().toInt()
        }
        return palette
    }
}

/// One conversation, as a home screen is allowed to see it.
///
/// The Kotlin mirror of `SnapshotRow`. Everything here has already been through
/// `SnapshotPolicy` on the phone; there is no second filter on this side and
/// there cannot be one, because this process has no session, no database and no
/// way to ask.
data class SnapshotRow(
    /// `Chat.id` — a room id, or `merged:<contactId>`. Never re-derived from
    /// anything: the app has already answered "which conversation is this".
    val chatId: String,
    /// What the row is labelled, or [SnapshotFormat.REDACTED_TITLE] when the
    /// policy withheld it.
    val title: String,
    /// `weft://chat/<encoded id>`, exactly as `chatDeepLink` produced it.
    ///
    /// A request, not a promise. A merged chat reverts to a plain room id when
    /// one of its legs is left, and this process may hold the payload for hours
    /// afterwards — so the link can name a conversation that no longer exists.
    /// It is handed to the existing `ACTION_VIEW` path rather than to anything
    /// new precisely because that path already tolerates an id it cannot
    /// resolve.
    val link: String,
    val unreadCount: Int,
    /// The badge text, capped at `99+` by the writer.
    val unreadLabel: String,
    /// `ChatNetwork.id` strings, in the stable enum order Dart wrote them in, so
    /// the glyph strip renders the same way round on every refresh.
    val networks: List<String>,
    val isMerged: Boolean,
    val preview: String?,
    val senderName: String?,
    val timestampMillis: Long?,
)

/// The whole of what left the encrypted store for a home screen.
data class InboxSnapshot(
    val version: Int,
    val generatedAtMillis: Long,
    val enabled: Boolean,
    /// Unread across every conversation the policy allowed — *including* the
    /// ones past the row cap, which is why the compact tile shows this rather
    /// than a sum over [rows].
    val totalUnread: Int,
    val palette: Map<String, Int>,
    /// In the order the inbox gave them. Not re-sorted here, on either side: a
    /// widget with a different top three than the app it companions is a bug the
    /// user reads as the app being wrong about their messages.
    val rows: List<SnapshotRow>,
) {
    /// True when the payload came from a build newer than this reader.
    ///
    /// Not an error and not a refusal. An unread count and a chat id mean the
    /// same thing in every version this format will ever have; refusing them
    /// would cost the user a working widget to protect them from a field that
    /// might be spelled differently.
    val isFutureVersion: Boolean get() = version > SnapshotFormat.VERSION

    fun isStaleAt(nowMillis: Long): Boolean =
        nowMillis - generatedAtMillis > SnapshotFormat.STALE_AFTER_MILLIS
}
