package com.bostrot.weft.wear

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.wear.compose.material.Colors
import androidx.wear.compose.material.MaterialTheme

/// `weft_design`, duplicated a third time, for a device with no Flutter on it.
///
/// The same bargain `WeftWidgetTokens.kt` and `WeftWidgetTokens.swift` strike:
/// every token in `packages/weft_design/lib/src/tokens.dart` is a Flutter type,
/// this process has no engine, so the numbers are written twice and
/// **`weft_design` remains the source of truth**. A change there is a change
/// owed here.
///
/// ## Only the dark half
///
/// The phone widgets carry both brightnesses, in `values/colors.xml` and
/// `values-night/colors.xml`, because a launcher can be in either. A watch
/// cannot: Wear OS has no light mode, its own `Colors()` default is dark, and
/// the reason is a hardware one — an OLED pixel showing black is a pixel that is
/// off, on a device whose battery is measured in hours. So these are the
/// `values-night` values, and there is no branch.
///
/// ## What is not here
///
/// **Network brand colours.** They arrive in the payload as
/// `InboxSnapshot.palette`, for the reason both other platforms give: the table
/// changes whenever a network is added, and a stale copy on this side would
/// render a new one in the fallback grey with nothing to say it had gone wrong.
object WeftWearTokens {
    /// The seed's indigo, `ColorScheme.fromSeed(0xFF6C5CE7)` at `Brightness.dark`
    /// — read out of the running app rather than eyeballed, and the same pair
    /// `values-night/colors.xml` holds so that the badge on a wrist is the badge
    /// on the home screen is the badge in the app.
    val primary = Color(0xFFC6BFFF)
    val onPrimary = Color(0xFF2E295F)
    val primaryContainer = Color(0xFF454077)
    val onPrimaryContainer = Color(0xFFE4DFFF)
    val secondary = Color(0xFFC8C3DC)
    val onSecondary = Color(0xFF302E41)
    val secondaryContainer = Color(0xFF474459)
    val onSecondaryContainer = Color(0xFFE4DFF9)
    val error = Color(0xFFFFB4AB)
    val onError = Color(0xFF690005)
    val surface = Color(0xFF131318)
    val onSurface = Color(0xFFE5E1E9)
    val onSurfaceVariant = Color(0xFFC9C5D0)

    /// Pure black, and not [surface].
    ///
    /// The one place this diverges from the Material scheme rather than copying
    /// it. A watch app's background is the screen's off state; `#131318` is a
    /// very dark grey that costs power on an OLED and, worse, draws a visible
    /// rectangle inside the bezel on a round display where the app is supposed
    /// to end at the glass.
    val background = Color.Black

    /// The colour a network dot falls back to when the payload names a network
    /// this build has never heard of.
    ///
    /// That fallback is also why the *count* of dots rather than their colour is
    /// what says "merged": an unknown network still gets a dot.
    val unknownNetwork = Color(0xFF928F99)

    /// At most this many dots beside a row. Four, matching both other surfaces —
    /// past every merged conversation the app can currently produce. A fifth is
    /// dropped silently, which is why the content description counts networks
    /// off the row rather than off what was drawn.
    const val MAX_NETWORK_DOTS = 4

    /// `0xAARRGGBB` as a Compose `Color`.
    ///
    /// The palette arrives as `Int` from [com.bostrot.weft.snapshot.SnapshotFormat],
    /// which already did the one narrowing that matters — an opaque brand colour
    /// is past `Int.MAX_VALUE` as a `Long` and `optInt` would silently return the
    /// fallback for every one of them.
    fun color(argb: Int): Color = Color(argb)
}

/// Weft's colours, wrapped for Wear's own `MaterialTheme`.
///
/// `androidx.wear.compose.material.MaterialTheme`, which is a different class
/// from the phone's and takes a different `Colors` — Wear's has no `tertiary`,
/// no container roles and no `surfaceVariant`, because a watch's whole palette
/// is four colours and the ambient mode that dims them. Mapping the scheme down
/// to it is this function.
@Composable
fun WeftWearTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colors = Colors(
            primary = WeftWearTokens.primary,
            primaryVariant = WeftWearTokens.primaryContainer,
            onPrimary = WeftWearTokens.onPrimary,
            secondary = WeftWearTokens.secondary,
            secondaryVariant = WeftWearTokens.secondaryContainer,
            onSecondary = WeftWearTokens.onSecondary,
            background = WeftWearTokens.background,
            onBackground = WeftWearTokens.onSurface,
            surface = WeftWearTokens.surface,
            onSurface = WeftWearTokens.onSurface,
            onSurfaceVariant = WeftWearTokens.onSurfaceVariant,
            error = WeftWearTokens.error,
            onError = WeftWearTokens.onError,
        ),
        content = content,
    )
}
