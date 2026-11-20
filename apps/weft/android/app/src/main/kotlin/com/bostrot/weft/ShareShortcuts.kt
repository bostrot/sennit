package com.bostrot.weft

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import android.net.Uri
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import kotlin.math.abs
import kotlin.math.min

/// Publishes conversations as launcher shortcuts, which is what makes them
/// Direct Share targets and what lets their notifications bubble.
///
/// One mechanism, two callers. Phase 03 needed a *single* shortcut published
/// just before a notification named it — `ShortcutManagerCompat` will not honour
/// a `shortcutId` for a shortcut that does not exist yet — and wrote that inline
/// in `MainActivity`. Direct Share needs the *set*: the top conversations, in
/// rank order, refreshed as the inbox moves, with the ones that fell off removed.
/// Both are the same `ShortcutInfoCompat` with the same id, so they are the same
/// code; a shortcut published by one and republished by the other must be
/// indistinguishable, or a conversation loses its bubble the moment it also
/// becomes a share target.
///
/// What this object does *not* do is decide which conversations, in what order,
/// or what a slot is called. That is `ShareTargetRanker` and `ShareTargetSlot` in
/// `packages/weft_share`, tested without a device. Everything here is a platform
/// call or a bitmap.
object ShareShortcuts {
    /// Marks a shortcut as a conversation: what puts it in the shade's
    /// conversation section and lets its notifications bubble.
    const val CONVERSATION_CATEGORY = "android.shortcut.conversation"

    /// The share-target category from `res/xml/shortcuts.xml`.
    ///
    /// This string is the whole of Direct Share's contract. A shortcut is
    /// offered in another app's share sheet only when its categories intersect
    /// the categories of a `<share-target>` whose `<data>` matches what is being
    /// shared — so this constant and the `<category>` line in that XML are one
    /// value written twice, and a typo in either produces an app that shares
    /// fine and simply never appears as a person.
    const val SHARE_CATEGORY = "com.bostrot.weft.category.SHARE_TARGET"

    /// What the voice assistant reads off a conversation shortcut.
    ///
    /// Google's assistant (Gemini, and Assistant before it) learns who can be
    /// messaged in an app from the shortcuts the app pushes: a shortcut bound
    /// to `actions.intent.SEND_MESSAGE` is a conversation the user writes to,
    /// one bound to `RECEIVE_MESSAGE` a conversation that wrote to the user.
    /// That is the whole of what "Hey Google, send a message to Anna on
    /// Sennit" needs to resolve "Anna" — the same binding Signal publishes.
    /// The ids are App Actions built-in intents; they need no declaration in
    /// `shortcuts.xml` to be bound, only to be *invoked* (see the
    /// `CREATE_MESSAGE` capability there).
    const val CAPABILITY_SEND_MESSAGE = "actions.intent.SEND_MESSAGE"
    const val CAPABILITY_RECEIVE_MESSAGE = "actions.intent.RECEIVE_MESSAGE"

    /// A group is an audience, not a person: bound with this parameter, the
    /// assistant offers it as "the family group", never as a person to call
    /// "family".
    private const val PARAMETER_RECIPIENT_TYPE = "message.recipient.@type"
    private const val PARAMETER_SENDER_TYPE = "message.sender.@type"
    private val AUDIENCE = listOf("Audience")

    /// Shortcut id → [Chat.id], so a Direct Share intent can be resolved.
    ///
    /// Android hands a shortcut-launched `SEND` back with
    /// `EXTRA_SHORTCUT_ID` — the id, and only the id. That id is *sanitised*
    /// (`shareTargetSlotId` replaces everything outside `[A-Za-z0-9_.-]`), so a
    /// room id cannot be read back out of it: `!a:example.org` and
    /// `_a_example.org` both arrive as `chat__a_example.org`. The map is the
    /// inverse the sanitising threw away.
    ///
    /// In preferences rather than in memory because the share that needs it is
    /// most often a *cold start* — the user is in the gallery, Weft is not
    /// running, and the process that published the shortcut died days ago.
    private const val PREFS_NAME = "weft.share.shortcuts"

    /// Longest label the launcher gets, as a backstop.
    ///
    /// `weft_share` already caps these (`kMaxShortLabelLength`,
    /// `kMaxLongLabelLength`) and is the authority on where to cut. This is only
    /// here so a hand-written channel call cannot write an unbounded string into
    /// the launcher's own XML storage.
    private const val MAX_LABEL_CHARS = 64

    /// Side of the generated initials bitmap, in pixels.
    ///
    /// Adaptive icons are masked to the launcher's shape and the outer ring is
    /// cropped, so the glyph is drawn well inside. 256 is above every current
    /// launcher's requested size, which means it is downscaled rather than
    /// stretched.
    private const val ICON_SIZE_PX = 256

    /// Fraction of [ICON_SIZE_PX] the adaptive mask is guaranteed to keep.
    ///
    /// Android's adaptive icon spec: a 108dp canvas with a 72dp safe zone. Text
    /// drawn outside it is cropped on round-masked launchers.
    private const val SAFE_ZONE = 72f / 108f

    /// Publishes [slots] as the complete set of conversation shortcuts.
    ///
    /// "Complete" is what separates this from [publishOne]: every shortcut this
    /// object published before and that is not in [slots] is removed. A share
    /// sheet still offering a conversation the user archived last week is the
    /// failure this exists to prevent, and the launcher will not work it out on
    /// its own — a long-lived shortcut is long-lived precisely because nothing
    /// garbage-collects it.
    ///
    /// Clamped to [ShortcutManagerCompat.getMaxShortcutCountPerActivity] because
    /// pushing past the device's limit *throws*, and the limit is a device
    /// property: the guarantee is five, common devices allow fifteen, and the
    /// Dart ranker's `kMaxShareTargetSlots` of eight is a sensible request, not a
    /// number anyone can rely on. Slots arrive in rank order, so clamping takes
    /// the best ones.
    ///
    /// Returns how many were published, which is what the channel answers with —
    /// a caller that asked for eight and got four has learned something true
    /// about the device.
    fun publish(activity: Activity, slots: List<Map<String, Any?>>): Int {
        val cap = min(slots.size, ShortcutManagerCompat.getMaxShortcutCountPerActivity(activity))
        val wanted = if (cap <= 0) emptyList() else slots.take(cap)

        // Stale first, then push: removing frees room under the cap, so a full
        // set of shortcuts can be replaced by a different full set. The other
        // order silently drops the tail of the new list on a device whose limit
        // is exactly the list's length.
        val ids = wanted.mapNotNull { it["id"] as? String }.toSet()
        removeStale(activity, keep = ids)

        val editor = activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
        var published = 0
        wanted.forEachIndexed { index, slot ->
            val id = slot["id"] as? String ?: return@forEachIndexed
            val chatId = slot["chatId"] as? String ?: return@forEachIndexed
            val link = slot["link"] as? String ?: return@forEachIndexed
            val longLabel = label(slot["longLabel"] as? String)
            val shortLabel = label(slot["shortLabel"] as? String, fallback = longLabel)

            val shortcut = build(
                activity = activity,
                id = id,
                shortLabel = shortLabel,
                longLabel = longLabel,
                link = link,
                iconPath = slot["iconPath"] as? String,
                // The rank the ranker chose, not this loop's index: the two
                // agree today, and only one of them is a decision.
                rank = (slot["rank"] as? Int) ?: index,
                isGroup = slot["isGroup"] as? Boolean ?: false,
                // The ranked set is who the user writes to.
                capabilities = listOf(CAPABILITY_SEND_MESSAGE),
            ) ?: return@forEachIndexed

            try {
                ShortcutManagerCompat.pushDynamicShortcut(activity, shortcut)
            } catch (e: Exception) {
                // A launcher that refuses one shortcut must not cost the user
                // the other seven.
                return@forEachIndexed
            }
            editor.putString(id, chatId)
            published++
        }
        editor.apply()
        return published
    }

    /// Publishes a single conversation shortcut, for the notification path.
    ///
    /// Deliberately *not* a one-element [publish]: this is called immediately
    /// before posting a notification, for whichever conversation just received a
    /// message, and that conversation is frequently not in the ranked set at all.
    /// Removing everything else would empty the share sheet every time a
    /// notification arrived.
    ///
    /// The shortcut is otherwise identical — same id, same categories, same
    /// long-lived flag — so a conversation published here is a Direct Share
    /// target too, and the ranked publish that follows finds it already correct
    /// and leaves it alone.
    fun publishOne(
        activity: Activity,
        id: String,
        chatId: String?,
        label: String,
        link: String,
        iconPath: String?,
        isGroup: Boolean = false,
    ): Boolean {
        val shortcut = build(
            activity = activity,
            id = id,
            shortLabel = label(label),
            longLabel = label(label),
            link = link,
            iconPath = iconPath,
            // Behind every ranked slot: this shortcut is here because a message
            // arrived, which the ranker will account for on its next pass. Until
            // then it should not displace a pinned conversation in the sheet.
            rank = Int.MAX_VALUE,
            isGroup = isGroup,
            // Pushed because a message arrived: this conversation wrote to the
            // user. Still bound to SEND_MESSAGE as well, because this push
            // replaces the ranked one under the same id, and a conversation
            // that just wrote is the likeliest one to be answered by name.
            capabilities = listOf(CAPABILITY_SEND_MESSAGE, CAPABILITY_RECEIVE_MESSAGE),
        ) ?: return false

        return try {
            ShortcutManagerCompat.pushDynamicShortcut(activity, shortcut)
            if (chatId != null) {
                activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putString(id, chatId)
                    .apply()
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    /// Removes every shortcut Weft published, and forgets their chat ids.
    ///
    /// Called on logout. A signed-out device that still offers "Alexandra" in
    /// every app's share sheet has leaked a contact name to whoever picks the
    /// phone up, and the launcher will hold a long-lived shortcut indefinitely
    /// unless it is told otherwise.
    fun clear(activity: Activity) {
        removeStale(activity, keep = emptySet())
    }

    /// The [Chat.id] behind a shortcut id, or null if it was not one of ours.
    ///
    /// Null is the ordinary answer for a shortcut published by a build before
    /// this map existed, or one the user pinned and then signed out from. The
    /// share then falls back to the target picker, which is the same thing that
    /// happens for a plain share — a wrong guess would send someone's photo to
    /// the wrong person.
    fun chatIdFor(context: Context, shortcutId: String): String? =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(shortcutId, null)

    private fun removeStale(activity: Activity, keep: Set<String>) {
        val prefs = activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val stale = prefs.all.keys.filterNot(keep::contains)
        if (stale.isEmpty()) return

        try {
            // `removeLongLivedShortcuts` rather than `removeDynamicShortcuts`:
            // the shortcuts are long-lived, so the launcher keeps a cached copy
            // that the dynamic removal does not touch. On API 30+ this is the
            // call that actually reaches that cache; below it the compat library
            // falls back to the dynamic removal, which is all there is.
            ShortcutManagerCompat.removeLongLivedShortcuts(activity, stale)
        } catch (e: Exception) {
            // A launcher that will not remove them is not a reason to keep
            // claiming they exist — but it is a reason not to forget their chat
            // ids, since they are still out there and still tappable.
            return
        }
        val editor = prefs.edit()
        stale.forEach { editor.remove(it) }
        editor.apply()
    }

    /// One shortcut, or null when the link will not parse.
    private fun build(
        activity: Activity,
        id: String,
        shortLabel: String,
        longLabel: String,
        link: String,
        iconPath: String?,
        rank: Int,
        isGroup: Boolean,
        capabilities: List<String>,
    ): ShortcutInfoCompat? {
        val uri = Uri.parse(link)
        if (uri.scheme.isNullOrEmpty()) return null

        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            setPackage(activity.packageName)
            setClass(activity, MainActivity::class.java)
        }

        val icon = icon(iconPath) ?: initialsIcon(longLabel, id)

        val person = Person.Builder()
            .setName(longLabel)
            .setKey(id)
            .setIcon(icon)
            .build()

        val builder = ShortcutInfoCompat.Builder(activity, id)
            .setShortLabel(shortLabel)
            .setLongLabel(longLabel)
            .setIntent(intent)
            // Long-lived is not optional: a shortcut the launcher may garbage
            // collect cannot back a bubble, because the bubble outlives the
            // notification that created it — and it cannot be a Direct Share
            // target either, since the system caches the target list.
            .setLongLived(true)
            // Marks it a conversation for the system's people service, which
            // is what ranks it for the share sheet and the assistant.
            .setIsConversation()
            .setPerson(person)
            // The same id the notification is keyed on, so the system's
            // intelligence services can tell they are one conversation.
            .setLocusId(LocusIdCompat(id))
            // Both categories, because the two surfaces read different ones:
            // the shade wants `conversation` to file the notification, the
            // share sheet wants the share-target category to offer the icon.
            .setCategories(setOf(CONVERSATION_CATEGORY, SHARE_CATEGORY))
            .setRank(rank)
            .setIcon(icon)

        for (capability in capabilities) {
            val typeParameter = if (capability == CAPABILITY_SEND_MESSAGE) {
                PARAMETER_RECIPIENT_TYPE
            } else {
                PARAMETER_SENDER_TYPE
            }
            if (isGroup) {
                builder.addCapabilityBinding(capability, typeParameter, AUDIENCE)
            } else {
                builder.addCapabilityBinding(capability)
            }
        }
        return builder.build()
    }

    private fun icon(path: String?): IconCompat? {
        if (path.isNullOrEmpty()) return null
        return try {
            // Adaptive so the launcher can mask it to its own shape; a raw
            // bitmap comes out square next to every other round avatar.
            BitmapFactory.decodeFile(path)?.let { IconCompat.createWithAdaptiveBitmap(it) }
        } catch (e: Exception) {
            // A path that was valid when Dart resolved it and is gone now — the
            // cache is the platform's to reclaim at any moment.
            null
        }
    }

    /// A drawn initials avatar, for a conversation with no picture.
    ///
    /// Not optional, and not a placeholder: a Direct Share row renders as icons
    /// with captions, and a target with no icon is drawn by most launchers as
    /// the *app* icon — so eight conversations become eight identical Weft
    /// logos, which is worse than no Direct Share at all. Dart draws the same
    /// thing in `WeftAvatar`; the duplication is in one direction only (this
    /// side cannot call Flutter) and the failure mode of the two drifting is
    /// cosmetic.
    private fun initialsIcon(label: String, seed: String): IconCompat {
        val bitmap = Bitmap.createBitmap(ICON_SIZE_PX, ICON_SIZE_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        // Hue from the id, not the name: two people called "Alex" should not
        // share a colour, and one person renamed should not change one.
        val hue = abs(seed.hashCode() % 360).toFloat()
        canvas.drawColor(Color.HSVToColor(floatArrayOf(hue, 0.45f, 0.62f)))

        val text = initials(label)
        if (text.isNotEmpty()) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                textSize = ICON_SIZE_PX * SAFE_ZONE * 0.5f
                textAlign = Paint.Align.CENTER
            }
            val bounds = Rect()
            paint.getTextBounds(text, 0, text.length, bounds)
            canvas.drawText(
                text,
                ICON_SIZE_PX / 2f,
                // Centred on the glyph's own box rather than the font's line
                // box, which is asymmetric and leaves initials sitting low.
                ICON_SIZE_PX / 2f + bounds.height() / 2f,
                paint,
            )
        }

        return IconCompat.createWithAdaptiveBitmap(bitmap)
    }

    /// Up to two initials for [label].
    ///
    /// Code points rather than chars: a conversation titled with an emoji is
    /// common, and `label[0]` on one is half a surrogate pair, which renders as
    /// a replacement box.
    private fun initials(label: String): String {
        val words = label.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return ""
        val first = firstCodePoint(words.first())
        if (words.size == 1) return first.uppercase()
        return (first + firstCodePoint(words[1])).uppercase()
    }

    private fun firstCodePoint(word: String): String {
        val code = word.codePointAt(0)
        return String(Character.toChars(code))
    }

    private fun label(raw: String?, fallback: String = "Chat"): String {
        val trimmed = raw?.trim()
        if (trimmed.isNullOrEmpty()) return fallback
        return trimmed.take(MAX_LABEL_CHARS)
    }
}
