package com.bostrot.weft.widget

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.Action
import androidx.glance.action.clickable
// The `Intent` overload, which lives in the appwidget artifact rather than in
// `androidx.glance.action` beside the `ComponentName` and `Class` ones. The
// distinction matters: those two can only name an activity, and every tap on
// this surface has to carry a *URI* — the row's `weft://chat/<id>` link.
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ColumnScope
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.bostrot.weft.MainActivity
import com.bostrot.weft.R

/// The pieces both Weft widgets are built from.
///
/// Two widgets, one vocabulary: the same surface, the same empty states, the
/// same badge. Split out rather than duplicated because the difference between
/// the compact tile and the inbox list is only what they draw when there *is*
/// something to draw — every other state is the same sentence, and a user with
/// both widgets on one home screen must not be told two different things about
/// one setting.

/// The theme wrapper, and the whole of Weft's dynamic-colour policy.
///
/// On Android 12 and up `GlanceTheme.colors` resolves to the system's dynamic
/// palette, derived from the wallpaper — which is what makes a widget look like
/// it belongs on the home screen it is sitting on rather than like a rectangle
/// cut out of another app. Below that there is no system palette to defer to, so
/// the widget falls back to [WeftWidgetTokens.colors], the `weft_design` seed.
///
/// Kept in the shape the platform documentation prescribes on purpose: it
/// depends only on `GlanceTheme.colors` resolving dynamically, which is Glance's
/// own contract, rather than on this file naming the dynamic provider and having
/// to track which package it lives in.
@Composable
fun WeftGlanceTheme(content: @Composable () -> Unit) {
    GlanceTheme(
        colors = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            GlanceTheme.colors
        } else {
            WeftWidgetTokens.colors
        },
        content = content,
    )
}

/// The card every widget draws itself into.
///
/// [appWidgetBackground] is not decoration: it tags this element as
/// `@android:id/background`, which is what lets Android 12's launcher round the
/// widget's corners and apply its own outline. A widget without it is the one on
/// the home screen with square corners.
///
/// [onClick] is the whole-surface fallback target, so that every state — even
/// the empty ones, especially the empty ones — opens the app. An empty widget
/// that also does nothing when tapped reads as broken rather than as empty.
@Composable
fun WeftWidgetSurface(
    onClick: Action,
    description: String? = null,
    verticalAlignment: Alignment.Vertical = Alignment.Top,
    horizontalAlignment: Alignment.Horizontal = Alignment.Start,
    content: @Composable ColumnScope.() -> Unit,
) {
    val base = GlanceModifier
        .fillMaxSize()
        .appWidgetBackground()
        .background(GlanceTheme.colors.widgetBackground)
        .cornerRadius(WeftWidgetTokens.RADIUS_MD)
        .padding(WeftWidgetTokens.SPACE_MD)
        .clickable(onClick)
    Column(
        modifier = if (description == null) {
            base
        } else {
            base.semantics { contentDescription = description }
        },
        verticalAlignment = verticalAlignment,
        horizontalAlignment = horizontalAlignment,
        content = content,
    )
}

/// A state that has nothing to show, and says why.
///
/// Every branch of [WeftWidgetState] that is not a populated `Ready` lands here.
/// The rule it exists to keep is the phase brief's: *"a signed-out and a
/// snapshot-disabled empty state that explains itself rather than rendering
/// blank"* — so each one names its own cause and, where there is one, the thing
/// the user would do about it.
///
/// The strings live in `res/values/strings.xml` rather than in the app's ARB
/// catalogue, because nothing here can reach Flutter's localisations: the
/// launcher renders this, and `AppLocalizations` needs an engine. That
/// duplicates the localisation *mechanism* and not any string — no sentence
/// below appears anywhere in the Flutter app.
@Composable
fun WeftEmptyState(context: Context, state: WeftWidgetState) {
    val headline: String
    val detail: String
    when (state) {
        is WeftWidgetState.SignedOut -> {
            headline = context.getString(R.string.weft_widget_signed_out_title)
            detail = context.getString(R.string.weft_widget_signed_out_body)
        }
        is WeftWidgetState.SwitchedOff -> {
            headline = context.getString(R.string.weft_widget_disabled_title)
            detail = context.getString(R.string.weft_widget_disabled_body)
        }
        is WeftWidgetState.Unavailable -> {
            headline = context.getString(R.string.weft_widget_stale_title)
            detail = context.getString(R.string.weft_widget_stale_body)
        }
        // An enabled snapshot with no rows: an empty inbox, or one whose every
        // conversation is on an excluded network. Not an error, and phrased so
        // that it does not read as one.
        is WeftWidgetState.Ready -> {
            headline = context.getString(R.string.weft_widget_empty_title)
            detail = context.getString(R.string.weft_widget_empty_body)
        }
    }

    Text(
        text = headline,
        style = TextStyle(
            color = GlanceTheme.colors.onSurface,
            fontSize = WeftWidgetTokens.TITLE_SIZE,
            fontWeight = FontWeight.Medium,
        ),
        maxLines = 2,
    )
    Spacer(modifier = GlanceModifier.height(WeftWidgetTokens.SPACE_XS))
    Text(
        text = detail,
        style = TextStyle(
            color = GlanceTheme.colors.onSurfaceVariant,
            fontSize = WeftWidgetTokens.BODY_SIZE,
        ),
        maxLines = 4,
    )
}

/// One conversation.
///
/// The tap target is the whole row and it carries the row's own link, which is
/// the part that has to be right: Glance turns each [actionStartActivity] into a
/// `PendingIntent`, and two `Intent`s that differ only in their *extras* compare
/// equal as far as `PendingIntent` caching is concerned. Putting the chat in the
/// intent's **data URI** — where `chatDeepLink` already put it — is what stops
/// sixteen rows collapsing onto whichever one was created first.
///
/// Merged conversations are signalled two ways, neither of them colour on its
/// own: the *number* of glyph dots, and the accessibility description. `ChatTile`
/// manages three; a row this size can carry two, which is the floor the design
/// notes set.
@Composable
fun WeftConversationRow(
    context: Context,
    row: SnapshotRow,
    palette: Map<String, Int>,
    showPreview: Boolean,
) {
    // Folded into one nullable rather than kept as a flag beside the text: the
    // row has to make the same decision twice — once for its height and once for
    // its second line — and two spellings of it is how those two drift apart.
    val preview = if (showPreview) row.preview else null
    Row(
        modifier = GlanceModifier
            .fillMaxWidth()
            .padding(vertical = WeftWidgetTokens.SPACE_SM)
            // A one-line row is about 36dp of intrinsic height, which is under
            // the 48dp minimum tap target `WeftTapTarget` enforces everywhere
            // else in the app — and a launcher enforces nothing. Pinned only
            // when the preview is hidden; a two-line row already clears it, and
            // a fixed height there would clip the second line instead.
            .let { if (preview != null) it else it.height(WeftWidgetTokens.ROW_MIN_HEIGHT) }
            .clickable(actionStartActivity(openLinkIntent(context, row.link)))
            .semantics { contentDescription = rowDescription(context, row) },
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        WeftNetworkDots(row = row, palette = palette)
        Spacer(modifier = GlanceModifier.width(WeftWidgetTokens.SPACE_SM))
        Column(modifier = GlanceModifier.defaultWeight()) {
            Text(
                text = row.title,
                style = TextStyle(
                    color = GlanceTheme.colors.onSurface,
                    fontSize = WeftWidgetTokens.TITLE_SIZE,
                    // Unread is what this surface exists to show, so it is
                    // carried by weight as well as by the badge — the same
                    // "never one signal alone" rule the merged indicator follows,
                    // and the one that survives a user who cannot see the badge's
                    // colour.
                    fontWeight = if (row.unreadCount > 0) FontWeight.Bold else FontWeight.Normal,
                ),
                maxLines = 1,
            )
            // The preview is already policy-filtered, already rendered per kind
            // by `weft_notify`, and already cut at a grapheme boundary. Nothing
            // here re-truncates it: a second cut would be a second rule, and this
            // one would be measured in the wrong units.
            if (preview != null) {
                Text(
                    text = withSender(row.senderName, preview),
                    style = TextStyle(
                        color = GlanceTheme.colors.onSurfaceVariant,
                        fontSize = WeftWidgetTokens.BODY_SIZE,
                    ),
                    maxLines = 2,
                )
            }
        }
        if (row.unreadCount > 0) {
            Spacer(modifier = GlanceModifier.width(WeftWidgetTokens.SPACE_SM))
            WeftUnreadBadge(label = row.unreadLabel)
        }
    }
}

/// The `99+` pill.
///
/// The label is [SnapshotRow.unreadLabel], formatted on the phone. The cap is
/// `WeftUnreadBadge`'s and it is applied in Dart precisely so the same
/// conversation does not read `120` in the app and `99+` here, or the reverse.
@Composable
fun WeftUnreadBadge(label: String) {
    Box(
        modifier = GlanceModifier
            .background(GlanceTheme.colors.primary)
            .cornerRadius(WeftWidgetTokens.RADIUS_PILL)
            .padding(horizontal = WeftWidgetTokens.SPACE_SM, vertical = 2.dp),
        contentAlignment = Alignment.Center,
        content = {
            Text(
                text = label,
                style = TextStyle(
                    color = GlanceTheme.colors.onPrimary,
                    fontSize = WeftWidgetTokens.LABEL_SIZE,
                    fontWeight = FontWeight.Medium,
                ),
                maxLines = 1,
            )
        },
    )
}

/// One dot per network feeding the conversation, in the payload's order.
///
/// Colours come from [InboxSnapshot.palette] — `ChatNetwork.brandColor`, carried
/// as an int, once per payload rather than once per row — and fall back to the
/// theme when the payload names a network this build has never heard of. That
/// fallback is why the *count* of dots rather than their colour is what says
/// "merged": an unknown network still gets a dot.
///
/// Stacked vertically rather than in a row because the strip sits in a fixed
/// column to the left of the title, and a merged conversation must not push the
/// title further right than a plain one does.
@Composable
fun WeftNetworkDots(row: SnapshotRow, palette: Map<String, Int>) {
    Column(
        modifier = GlanceModifier.width(WeftWidgetTokens.DOT),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        for (network in row.networks.take(MAX_NETWORK_DOTS)) {
            val brand = palette[network]
            Box(
                modifier = GlanceModifier
                    .size(WeftWidgetTokens.DOT)
                    .background(
                        if (brand == null) {
                            GlanceTheme.colors.onSurfaceVariant
                        } else {
                            ColorProvider(Color(brand))
                        }
                    )
                    .cornerRadius(WeftWidgetTokens.DOT / 2),
                content = {},
            )
            Spacer(modifier = GlanceModifier.height(2.dp))
        }
    }
}

/// The intent a tap sends, on the path that already exists.
///
/// Explicitly targeted at [MainActivity] rather than left to the intent
/// resolver. The `weft://` filter in the manifest would resolve it too, but an
/// implicit `ACTION_VIEW` from a widget can raise a disambiguation dialog on a
/// device where something else has claimed the scheme, and a widget tap that
/// opens a chooser is a widget tap that failed. The activity's own `ACTION_VIEW`
/// arm then hands the URL to `WeftLink.parse` — the same router a notification
/// tap and a launcher shortcut use, which is the reuse the brief asks for.
///
/// `FLAG_ACTIVITY_NEW_TASK` because a widget is not an activity and has no task
/// of its own to start into. `CLEAR_TOP` with the manifest's `singleTop` is what
/// makes a second tap arrive at `onNewIntent` on the running activity rather
/// than stack a second copy of Weft.
fun openLinkIntent(context: Context, link: String): Intent =
    Intent(Intent.ACTION_VIEW, Uri.parse(link), context, MainActivity::class.java)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

/// `weft://`, which `WeftLink.parse` reads as `OpenInboxLink`.
///
/// A URI with no path segments rather than an invented `weft://inbox`: the
/// parser returns `OpenInboxLink` for an empty segment list and `null` for an
/// unrecognised first segment, so the invented spelling is the one that opens
/// nothing. Written here rather than carried in the payload because it names no
/// conversation and so discloses nothing — it is the one link on this surface
/// that is not a privacy decision.
const val WEFT_INBOX_LINK = "weft://"

/// At most this many dots beside a row.
///
/// Four is past every merged conversation the app can currently produce and
/// keeps the strip inside the width a 2×2 widget has. A fifth would be dropped
/// silently, which is why [rowDescription] counts networks off the row rather
/// than off what was drawn.
private const val MAX_NETWORK_DOTS = 4

/// What a screen reader hears for a row.
///
/// Assembled here rather than left to Glance's default, which would read the
/// title, the preview and the badge as three unrelated strings in layout order —
/// so a merged conversation would be indistinguishable from a plain one, and the
/// unread count would arrive after the message it belongs to.
private fun rowDescription(context: Context, row: SnapshotRow): String {
    val parts = mutableListOf(row.title)
    if (row.isMerged) parts.add(context.getString(R.string.weft_widget_merged))
    if (row.unreadCount > 0) {
        parts.add(
            context.resources.getQuantityString(
                R.plurals.weft_widget_unread_count,
                row.unreadCount,
                row.unreadCount,
            )
        )
    }
    row.preview?.let { parts.add(withSender(row.senderName, it)) }
    return parts.joinToString(separator = ", ")
}

/// `Grace: on my way`, or the preview alone when names are withheld.
///
/// The sender is already disambiguated by network for a merged chat
/// (`snapshotSenderName`), so nothing is added here beyond the separator.
private fun withSender(sender: String?, preview: String): String =
    if (sender.isNullOrEmpty()) preview else "$sender: $preview"
