package com.bostrot.weft.wear

import android.app.PendingIntent
import android.content.Intent
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.RangedValueComplicationData
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService
import com.bostrot.weft.snapshot.SnapshotFormat

/// Total unread, on a watch face.
///
/// The smallest surface in the whole phase and the one with the sharpest rule:
/// it shows [InboxSnapshot.totalUnread] and never a sum over the visible rows,
/// because `totalUnread` counts the conversations past the row cap and the
/// seventeenth conversation's unread messages are still unread. The same
/// sentence appears in `InboxSnapshot`'s own doc, in `WeftWidgetState.swift` and
/// in `WeftWearState`, because this is the number it is about.
///
/// **No names, ever.** A complication sits on a watch face that is on whenever
/// the wrist is up, in a meeting, on a table. A count identifies nobody; a name
/// identifies somebody to everyone who can see the watch. That is the same split
/// `privacySensitive()` makes on a Lock Screen, made here by simply not having a
/// text variant that could carry one.
class WeftWearComplicationService : SuspendingComplicationDataSourceService() {

    override fun getPreviewData(type: ComplicationType): ComplicationData? =
        complication(type, count = 4, tappable = false)

    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        val state = WeftWearState.read(applicationContext, System.currentTimeMillis())
        // Every state that is not `Ready` shows zero rather than an error glyph.
        // A complication has no room to say why, and "0" on a watch face is a
        // truthful thing for a surface that has been told nothing to display —
        // the app, the tile and the phone all have somewhere to explain it.
        return complication(request.complicationType, state.totalUnread, tappable = true)
    }

    private fun complication(
        type: ComplicationType,
        count: Int,
        tappable: Boolean,
    ): ComplicationData? {
        val label = SnapshotFormat.unreadLabel(count)
        val description = PlainComplicationText.Builder(
            WeftWearStrings.unreadCount(applicationContext, count)
        ).build()

        return when (type) {
            ComplicationType.SHORT_TEXT -> ShortTextComplicationData.Builder(
                text = PlainComplicationText.Builder(label).build(),
                contentDescription = description,
            ).setTapAction(if (tappable) openApp() else null).build()

            // Offered because a great many watch faces have a slot that only
            // takes a ranged value, and an unread count is a quantity. The
            // ceiling is the badge cap rather than an invented maximum: it is
            // the number above which this app already stops counting out loud.
            ComplicationType.RANGED_VALUE -> RangedValueComplicationData.Builder(
                value = count.coerceIn(0, SnapshotFormat.UNREAD_BADGE_CAP).toFloat(),
                min = 0f,
                max = SnapshotFormat.UNREAD_BADGE_CAP.toFloat(),
                contentDescription = description,
            )
                .setText(PlainComplicationText.Builder(label).build())
                .setTapAction(if (tappable) openApp() else null)
                .build()

            // A type this build was not asked for in the manifest. Returning
            // null is the documented way to decline, and the editor then simply
            // does not offer Weft for that slot.
            else -> null
        }
    }

    private fun openApp(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, WeftWearActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
