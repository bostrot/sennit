package com.bostrot.weft.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.LocalSize
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.lazy.items
import androidx.glance.appwidget.provideContent
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.bostrot.weft.R

/// The list widget: recent conversations, in the order the inbox put them.
///
/// **Not re-sorted here**, and that is the one thing this file must not be
/// tempted into. `InboxSnapshot.rows` arrives in the order the app's own chat
/// list decided — pinned first, then activity — and a companion surface showing
/// a different top three than the app it companions is a bug the user reads as
/// the app being wrong about their messages. There is no `sortedByDescending` in
/// this file and there should never be one.
///
/// Every row is its own tap target carrying its own `weft://chat/<id>` link. The
/// surface *behind* the rows is a tap target too, aimed at the inbox, so the
/// gaps between rows are not dead space.
class WeftInboxWidget : GlanceAppWidget() {
    /// [SizeMode.Exact] because this widget genuinely renders differently at
    /// different widths: below [WeftWidgetTokens.PREVIEW_MIN_WIDTH] a row drops
    /// its preview line rather than showing three words and an ellipsis. The
    /// row *count* needs no size branch — [LazyColumn] scrolls, and the payload
    /// is already capped at `kDefaultSnapshotRowCap`.
    override val sizeMode: SizeMode = SizeMode.Exact

    /// The state read is *inside* [provideContent], and that placement is the
    /// whole of whether this widget ever changes. See [WeftUnreadWidget] for the
    /// device behaviour that settled it.
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            WeftGlanceTheme {
                WeftInboxContent(
                    context = context,
                    state = WeftWidgetState.read(context, System.currentTimeMillis()),
                )
            }
        }
    }
}

@Composable
private fun WeftInboxContent(context: Context, state: WeftWidgetState) {
    val open = actionStartActivity(openLinkIntent(context, WEFT_INBOX_LINK))

    // Everything that is not a populated snapshot is a sentence, not a blank
    // rectangle. `Ready` with no rows falls in here too — see `WeftEmptyState`,
    // which has a phrasing for it that does not read as a failure.
    if (state !is WeftWidgetState.Ready || state.snapshot.rows.isEmpty()) {
        WeftWidgetSurface(onClick = open) {
            WeftEmptyState(context = context, state = state)
        }
        return
    }

    val snapshot = state.snapshot
    val showPreview = LocalSize.current.width >= WeftWidgetTokens.PREVIEW_MIN_WIDTH

    WeftWidgetSurface(onClick = open) {
        Text(
            text = context.getString(R.string.weft_widget_inbox_heading),
            style = TextStyle(
                color = GlanceTheme.colors.onSurfaceVariant,
                fontSize = WeftWidgetTokens.LABEL_SIZE,
                fontWeight = FontWeight.Medium,
            ),
            maxLines = 1,
        )
        Spacer(modifier = GlanceModifier.height(WeftWidgetTokens.SPACE_XS))
        LazyColumn(modifier = GlanceModifier.fillMaxWidth()) {
            // A stable id per conversation rather than Glance's positional
            // default. The list is regenerated on every inbox tick and rows move
            // within it constantly; keyed by position, the launcher reuses row
            // three's view for whatever is third *now*, which is how a widget
            // ends up showing one conversation's title beside another's badge
            // for a frame.
            items(items = snapshot.rows, itemId = { it.chatId.hashCode().toLong() }) { row ->
                WeftConversationRow(
                    context = context,
                    row = row,
                    // The palette travels once per payload rather than per row,
                    // so it is threaded down rather than looked up again.
                    palette = snapshot.palette,
                    showPreview = showPreview,
                )
            }
        }
    }
}

/// Glance's receiver for [WeftInboxWidget]. See [WeftUnreadWidgetReceiver] for
/// why neither of these is named by the writer.
class WeftInboxWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = WeftInboxWidget()
}
