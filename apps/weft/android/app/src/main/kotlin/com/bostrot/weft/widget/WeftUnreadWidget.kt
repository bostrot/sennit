package com.bostrot.weft.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.glance.GlanceId
import androidx.glance.GlanceTheme
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import androidx.glance.layout.Alignment
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.bostrot.weft.R

/// The compact tile: one number, the total across every conversation.
///
/// The smaller of the two widgets, and deliberately not a one-row list. What it
/// shows is [InboxSnapshot.totalUnread], which is a *field* in the payload
/// rather than a sum over the rows — counted before the row cap, on the phone,
/// over every conversation the policy allowed. The seventeenth conversation's
/// unread messages are still unread, and a tile that quietly dropped them would
/// disagree with the notification shade sitting directly above it.
///
/// It is also the least disclosing thing Weft can put on a home screen: a count
/// and nothing else — no title, no preview, no sender — whatever the policy
/// says. Someone who wants to know they have messages without anyone reading
/// them over their shoulder can place this one and leave previews off, and the
/// two decisions do not interact.
class WeftUnreadWidget : GlanceAppWidget() {
    /// One layout at every size. The tile is a number in a box; there is nothing
    /// it would do differently with more room, and `SizeMode.Exact` would cost a
    /// recomposition per size for no difference in output.
    override val sizeMode: SizeMode = SizeMode.Single

    /// The state read is here rather than inside the composition on purpose: it
    /// touches `SharedPreferences`, `provideGlance` is the suspending half where
    /// that belongs, and the system may compose the returned content more than
    /// once.
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val state = WeftWidgetState.read(context, System.currentTimeMillis())
        provideContent {
            WeftGlanceTheme {
                WeftUnreadContent(context = context, state = state)
            }
        }
    }
}

@Composable
private fun WeftUnreadContent(context: Context, state: WeftWidgetState) {
    // The tile opens the inbox, in every state. There is no per-conversation
    // target here, and an unread count that cannot be tapped is a number the
    // user has to go and act on somewhere else.
    val open = actionStartActivity(openLinkIntent(context, WEFT_INBOX_LINK))

    if (state !is WeftWidgetState.Ready) {
        WeftWidgetSurface(onClick = open) {
            WeftEmptyState(context = context, state = state)
        }
        return
    }

    val total = state.snapshot.totalUnread
    WeftWidgetSurface(
        onClick = open,
        // One label for the whole tile rather than a number and a word read as
        // two unrelated things. `getQuantityString` because "1 unread message"
        // and "4 unread messages" are not the same sentence, and a widget that
        // gets that wrong is read aloud getting it wrong.
        description = context.resources.getQuantityString(
            R.plurals.weft_widget_unread_count,
            total,
            total,
        ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            // Zero is drawn rather than hidden: "no unread messages" is
            // information, and a tile that renders nothing looks like a tile
            // that failed.
            text = SnapshotFormat.unreadLabel(total),
            style = TextStyle(
                color = GlanceTheme.colors.primary,
                fontSize = WeftWidgetTokens.COUNT_SIZE,
                fontWeight = FontWeight.Bold,
            ),
            maxLines = 1,
        )
        Text(
            text = context.getString(R.string.weft_widget_unread_label),
            style = TextStyle(
                color = GlanceTheme.colors.onSurfaceVariant,
                fontSize = WeftWidgetTokens.LABEL_SIZE,
            ),
            maxLines = 1,
        )
    }
}

/// Glance's receiver for [WeftUnreadWidget].
///
/// A plain `AppWidgetProvider` underneath — which is what
/// `WeftSnapshotStore.notifySurfaces` is already broadcasting
/// `ACTION_APPWIDGET_UPDATE` to. That broadcast reaches
/// `GlanceAppWidgetReceiver.onUpdate`, which re-runs
/// [WeftUnreadWidget.provideGlance] and so re-reads the payload. No extra
/// plumbing on either side: the writer predates these classes and enumerates
/// installed providers rather than naming them, deliberately.
class WeftUnreadWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = WeftUnreadWidget()
}
