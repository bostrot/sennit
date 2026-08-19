package com.bostrot.weft.wear

import androidx.concurrent.futures.ResolvableFuture
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.protolayout.material.Text
import androidx.wear.protolayout.material.Typography
import androidx.wear.protolayout.material.layouts.PrimaryLayout
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.bostrot.weft.snapshot.SnapshotFormat
import com.google.common.util.concurrent.ListenableFuture

/// The tile: unread, and the top conversations, one sideways swipe from the
/// watch face.
///
/// **ProtoLayout, not Compose**, and that is not a style choice. A tile is
/// rendered by the *system's* process from a serialised description this service
/// hands over — there is no Compose runtime on the other side of that boundary,
/// exactly as there is no Flutter engine on the other side of a Glance widget's.
/// The two surfaces are the same shape of constraint on two platforms, and both
/// arrive at the same place: the phone decided what may be shown, this decides
/// how it is laid out, and neither can ask a question of the other.
///
/// Five states, the same five as everywhere else. A tile that rendered blank for
/// four of them would be a tile the wearer removes.
class WeftWearTileService : TileService() {
    override fun onTileRequest(
        requestParams: RequestBuilders.TileRequest
    ): ListenableFuture<TileBuilders.Tile> {
        val state = WeftWearState.read(applicationContext, System.currentTimeMillis())
        val tile = TileBuilders.Tile.Builder()
            .setResourcesVersion(RESOURCES_VERSION)
            // `freshnessInterval` rather than a timer: it asks the system to come
            // back, and the system decides when it can afford to. The real
            // refresh is `TileService.getUpdater().requestUpdate()` the moment a
            // snapshot lands — see `WeftWearDataService.refreshSurfaces`. This
            // exists only so a tile whose phone has been away all morning stops
            // presenting yesterday's counts as today's, which is a twelve-hour
            // boundary and needs nothing finer than an hour.
            .setFreshnessIntervalMillis(60 * 60 * 1000)
            .setTileTimeline(
                TimelineBuilders.Timeline.Builder()
                    .addTimelineEntry(
                        TimelineBuilders.TimelineEntry.Builder()
                            .setLayout(
                                LayoutElementBuilders.Layout.Builder()
                                    .setRoot(layout(requestParams, state))
                                    .build()
                            )
                            .build()
                    )
                    .build()
            )
            .build()
        return immediate(tile)
    }

    override fun onTileResourcesRequest(
        requestParams: RequestBuilders.ResourcesRequest
    ): ListenableFuture<ResourceBuilders.Resources> = immediate(
        // No images. A row's avatar is an `mxc://` URI and this device has no
        // session to authenticate a media fetch with — the same answer the Glance
        // widgets and the WidgetKit widget give, for the same reason. So the only
        // resource this tile has is its version.
        ResourceBuilders.Resources.Builder().setVersion(RESOURCES_VERSION).build()
    )

    private fun layout(
        requestParams: RequestBuilders.TileRequest,
        state: WeftWearState,
    ): LayoutElementBuilders.LayoutElement {
        val context = applicationContext
        val theme = requestParams.deviceConfiguration
        val snapshot = state.snapshot

        if (snapshot == null || snapshot.rows.isEmpty()) {
            val (title, body) = WeftWearStrings.emptyState(context, state)
            return PrimaryLayout.Builder(theme)
                .setResponsiveContentInsetEnabled(true)
                .setPrimaryLabelTextContent(
                    Text.Builder(context, title)
                        .setTypography(Typography.TYPOGRAPHY_TITLE3)
                        .setColor(argb(WeftWearTokens.onSurface.value.toLong().toInt()))
                        .setMaxLines(2)
                        .build()
                )
                .setContent(
                    Text.Builder(context, body)
                        .setTypography(Typography.TYPOGRAPHY_CAPTION1)
                        .setColor(argb(WeftWearTokens.onSurfaceVariant.value.toLong().toInt()))
                        .setMaxLines(3)
                        .build()
                )
                .build()
        }

        // The number is `totalUnread` rather than a sum over the visible rows,
        // and the cap is applied here because that field is a *count* — the
        // per-row `unreadLabel` arrives pre-formatted so `99+` lives in Dart,
        // but this one does not. The same restatement, in the same words, as
        // `SnapshotFormat.unreadLabel` on the phone tile and
        // `WeftSnapshotFormat.unreadLabel` in Swift.
        val heading = "${SnapshotFormat.unreadLabel(snapshot.totalUnread)} " +
            context.getString(R.string.unread_label)

        val rows = LayoutElementBuilders.Column.Builder()
            .setWidth(expand())
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setPadding(
                        ModifiersBuilders.Padding.Builder()
                            .setTop(androidx.wear.protolayout.DimensionBuilders.dp(4f))
                            .build()
                    )
                    .build()
            )
        // Three, not sixteen. A tile is a glance and its height is fixed; the
        // rows past the third would be laid out and clipped, which costs the
        // system's renderer the same work as drawing them. The wearer who wants
        // the rest taps through to the app.
        for (row in snapshot.rows.take(TILE_ROWS)) {
            rows.addContent(
                Text.Builder(context, rowLine(row))
                    .setTypography(Typography.TYPOGRAPHY_CAPTION1)
                    .setColor(argb(WeftWearTokens.onSurface.value.toLong().toInt()))
                    .setMaxLines(1)
                    .build()
            )
        }

        return PrimaryLayout.Builder(theme)
            .setResponsiveContentInsetEnabled(true)
            .setPrimaryLabelTextContent(
                Text.Builder(context, heading)
                    .setTypography(Typography.TYPOGRAPHY_TITLE2)
                    .setColor(argb(WeftWearTokens.primary.value.toLong().toInt()))
                    .build()
            )
            .setContent(rows.build())
            .build()
    }

    /// A row, as one line of a tile.
    ///
    /// Title and badge only. The preview is deliberately dropped at this size —
    /// the same decision `systemSmall` makes in WidgetKit and the narrow Glance
    /// widget makes by measuring `LocalSize`: three words and an ellipsis is
    /// worse than the title alone, and this is the surface a wearer reads without
    /// stopping what they are doing.
    private fun rowLine(row: WearRow): String =
        if (row.unreadCount > 0) "${row.title}  ${row.unreadLabel}" else row.title

    private fun <T> immediate(value: T): ListenableFuture<T> =
        ResolvableFuture.create<T>().also { it.set(value) }

    companion object {
        /// Bumped when the images change, which so far means never. The system
        /// caches resources against this string and will not re-request them
        /// while it is unchanged.
        private const val RESOURCES_VERSION = "1"

        private const val TILE_ROWS = 3
    }
}
