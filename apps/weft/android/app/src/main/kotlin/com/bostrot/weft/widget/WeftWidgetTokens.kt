package com.bostrot.weft.widget

import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.color.colorProviders
import androidx.glance.unit.ColorProvider
import com.bostrot.weft.R

/// `weft_design`, duplicated deliberately, for a process that has no Flutter in
/// it.
///
/// Every token in `packages/weft_design/lib/src/tokens.dart` is a Flutter type —
/// `Color`, `BorderRadius`, `Curve`, `ThemeExtension`. A Glance composable is
/// rendered by the *launcher*, in a process with no Flutter engine, and it
/// cannot import any of them. So the numbers are written twice, and this comment
/// is the other half of that: **`weft_design` is the source of truth**, this is
/// a copy, and a change there is a change owed here.
///
/// The precedent is `ChatNetwork.brandColor`, held as an `int` "so this package
/// stays Flutter-free" — the same trick one process further out. The same
/// treatment `ShareContainer.swift` gives to its path constants.
///
/// ## What is *not* duplicated
///
/// Network brand colours. They travel in the payload as
/// `InboxSnapshot.palette` — `ChatNetwork.id` → `0xAARRGGBB` — rather than being
/// re-tabled here, because that table changes every time a network is added and
/// a stale copy on this side would render the new network in the fallback grey
/// with nothing to say it had gone wrong.
///
/// Motion, too. The system draws these surfaces and does not animate them, so
/// `WeftMotion` has no referent on a home screen.
object WeftWidgetTokens {
    // The 4pt grid, from `WeftSpace`.
    val SPACE_XS = 4.dp
    val SPACE_SM = 8.dp
    val SPACE_MD = 12.dp

    // From `WeftRadius`. `md` for a widget's own card, `pill` for the badge.
    //
    // Applied through `GlanceModifier.cornerRadius`, which the platform honours
    // from API 31 and silently ignores below it. That is the right trade rather
    // than a bug: a square-cornered widget on Android 11 is a widget, and the
    // alternative is a nine-patch per corner radius shipped in `res/drawable`.
    val RADIUS_MD = 14.dp
    val RADIUS_PILL = 999.dp

    /// Side of a network glyph dot. Small enough that four fit beside a title,
    /// large enough to stay visible after the launcher's own downscaling.
    val DOT = 8.dp

    /// Minimum tap target, from `WeftTapTarget`/Material's 48dp rule. A widget
    /// row is a tap target like any other and the launcher does not enforce it.
    val ROW_MIN_HEIGHT = 48.dp

    // Type scale. Glance has no `TextTheme`, so the four sizes the widgets use
    // are named here rather than spelled at each call site.
    val TITLE_SIZE = 15.sp
    val BODY_SIZE = 13.sp
    val LABEL_SIZE = 12.sp

    /// The compact tile's number. Large because it is the whole content of that
    /// widget, and because a total unread count is read at arm's length.
    val COUNT_SIZE = 34.sp

    /// Below this width the inbox row drops its preview line.
    ///
    /// A 2×2 widget gives a row about 150dp of text; a preview truncated to
    /// three words plus an ellipsis says less than the title already did, and it
    /// costs the row the height that keeps it a legal tap target.
    val PREVIEW_MIN_WIDTH = 220.dp

    /// The fallback palette: `ColorScheme.fromSeed(WeftTheme.defaultSeed)`,
    /// light in `res/values/colors.xml` and dark in `res/values-night/`.
    ///
    /// **Resource-backed rather than literal**, which is the whole of the
    /// widget's light/dark handling. `ColorProvider(resId)` is resolved by Glance
    /// against the configuration the widget is actually drawn in, so the night
    /// variant of the resource *is* dark mode — there is no `Build.VERSION`
    /// check, no `isSystemInDarkTheme()` and no second palette in Kotlin. The
    /// same mechanism the app's own `values-night/styles.xml` already uses.
    ///
    /// It is also what keeps `androidx.compose.material3` out of this app. The
    /// obvious spelling — `androidx.glance.material3.ColorProviders(light =
    /// lightColorScheme(…), dark = darkColorScheme(…))` — needs Compose
    /// Material 3 on the compile classpath, which drags Compose UI, Foundation
    /// and Animation into an APK whose entire user interface is Flutter. Two
    /// dozen resource references cost nothing and read the same.
    ///
    /// Every slot must be named: `colorProviders` has no defaults. The ones this
    /// widget never draws with — tertiary, the error pair, the inverse trio —
    /// are pointed at the seed's real values rather than at black, so that a
    /// future row using one gets a Weft colour instead of a hole.
    val colors = colorProviders(
        primary = ColorProvider(R.color.weft_widget_primary),
        onPrimary = ColorProvider(R.color.weft_widget_on_primary),
        primaryContainer = ColorProvider(R.color.weft_widget_primary_container),
        onPrimaryContainer = ColorProvider(R.color.weft_widget_on_primary_container),
        secondary = ColorProvider(R.color.weft_widget_secondary),
        onSecondary = ColorProvider(R.color.weft_widget_on_secondary),
        secondaryContainer = ColorProvider(R.color.weft_widget_secondary_container),
        onSecondaryContainer = ColorProvider(R.color.weft_widget_on_secondary_container),
        tertiary = ColorProvider(R.color.weft_widget_tertiary),
        onTertiary = ColorProvider(R.color.weft_widget_on_tertiary),
        tertiaryContainer = ColorProvider(R.color.weft_widget_tertiary_container),
        onTertiaryContainer = ColorProvider(R.color.weft_widget_on_tertiary_container),
        error = ColorProvider(R.color.weft_widget_error),
        errorContainer = ColorProvider(R.color.weft_widget_error_container),
        onError = ColorProvider(R.color.weft_widget_on_error),
        onErrorContainer = ColorProvider(R.color.weft_widget_on_error_container),
        // Material 3 deprecated `background` in favour of `surface` and Weft's
        // theme follows it — `scaffoldBackgroundColor` is `scheme.surface`. The
        // two are pointed at one resource here for the same reason rather than
        // given a distinction the app does not make.
        background = ColorProvider(R.color.weft_widget_surface),
        onBackground = ColorProvider(R.color.weft_widget_on_surface),
        surface = ColorProvider(R.color.weft_widget_surface),
        onSurface = ColorProvider(R.color.weft_widget_on_surface),
        surfaceVariant = ColorProvider(R.color.weft_widget_surface_variant),
        onSurfaceVariant = ColorProvider(R.color.weft_widget_on_surface_variant),
        outline = ColorProvider(R.color.weft_widget_outline),
        inverseOnSurface = ColorProvider(R.color.weft_widget_inverse_on_surface),
        inverseSurface = ColorProvider(R.color.weft_widget_inverse_surface),
        inversePrimary = ColorProvider(R.color.weft_widget_inverse_primary),
        // Glance's own slot, and the one the card is painted with. The app has
        // no separate "widget background" to copy, so it is the surface colour —
        // which is also what Android 12's dynamic palette resolves it to.
        widgetBackground = ColorProvider(R.color.weft_widget_surface),
    )
}
