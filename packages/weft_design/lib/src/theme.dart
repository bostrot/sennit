import 'package:flutter/material.dart';
import 'package:weft_domain/weft_domain.dart';

import 'contrast.dart';
import 'surface.dart';
import 'tokens.dart';

/// How dark Weft should be. Kept separate from [ThemeMode] because AMOLED is a
/// distinct surface treatment, not a third brightness.
enum WeftThemeMode { system, light, dark, amoled }

/// Weft-specific colours that Material's [ColorScheme] has no slot for.
///
/// Registered as a [ThemeExtension] so widgets read them the ordinary way —
/// `Theme.of(context).extension<WeftPalette>()` — and golden tests can swap the
/// whole palette without touching widget code.
@immutable
class WeftPalette extends ThemeExtension<WeftPalette> {
  const WeftPalette({
    required this.ownBubble,
    required this.ownBubbleText,
    required this.peerBubble,
    required this.peerBubbleText,
    required this.railBackground,
    required this.railSelected,
    required this.unreadDot,
    required this.mergedAccent,
    required this.online,
    required this.callAccept,
    required this.callDecline,
    required this.onCallAccept,
    required this.onCallDecline,
    required this.divider,
    required this.border,
    required this.focusRing,
    required this.scrim,
    required this.networkColors,
    required this.networkTextColors,
    required this.networkInk,
  });

  final Color ownBubble;
  final Color ownBubbleText;
  final Color peerBubble;
  final Color peerBubbleText;
  final Color railBackground;
  final Color railSelected;
  final Color unreadDot;

  /// Accent marking a merged conversation — the visual signature of the
  /// feature, so it is a first-class token rather than a one-off colour.
  final Color mergedAccent;

  /// Presence, and every "this is good" label in settings — a verified device,
  /// a working backup, a signed-in bridge, the SMS role.
  ///
  /// Contrast-corrected against the active surface rather than fixed, because
  /// it is read as *text* in six places. The fixed `#2ECC71` survives on a dark
  /// surface and is 1.9:1 on a light one, which is a fail for a label and for a
  /// meaningful dot alike.
  final Color online;

  /// Answer and hang up.
  ///
  /// Fixed rather than derived from the scheme, and the two colours a call is
  /// allowed to break the theme with: green-means-answer and red-means-hang-up
  /// are learned from every phone the user has ever held, and a call screen
  /// that tinted them with a purple seed would be prettier and slower to read.
  /// [callDecline] is deliberately not `ColorScheme.error` — an error is
  /// something that went wrong, and hanging up is not.
  final Color callAccept;
  final Color callDecline;

  /// Ink for the glyph on [callAccept] / [callDecline].
  ///
  /// The fills cannot move, so the glyph does: white on `#2ECC71` is 1.9:1 and
  /// the accept glyph is the only thing telling it apart from decline.
  final Color onCallAccept;
  final Color onCallDecline;

  /// Hairline between two blocks of content. Not a UI component under WCAG
  /// 1.4.11 and deliberately below 3:1 — use [border] for anything that bounds
  /// a control or a pane.
  final Color divider;

  /// Boundary of a control or a pane: the composer's top edge, the share
  /// sheet's action bar, the two-pane split. Meets 3:1 against the surface it
  /// sits on, which [divider] does not.
  final Color border;

  /// Keyboard focus indicator. Meets 3:1 against every surface a focusable
  /// control is drawn on, including the AMOLED black.
  final Color focusRing;

  /// Wash placed under text that sits over arbitrary content — a video frame,
  /// a photograph — where no token can promise a contrast ratio because the
  /// background is whatever the sender sent.
  final Color scrim;

  /// Per-network brand colours as a **fill**: the glyph chip, the merged ring,
  /// a bubble's origin hairline. Harmonised against the active scheme so
  /// WhatsApp green doesn't fight a purple theme, then corrected to 3:1 — the
  /// bar WCAG 1.4.11 sets for a graphic that carries meaning.
  final Map<ChatNetwork, Color> networkColors;

  /// The same brand colours as **text** on a surface — the network name in a
  /// merged bubble, a reply title, a link preview's host line.
  ///
  /// A separate token because text owes 4.5:1 and a fill owes 3:1, and one
  /// colour cannot be both without either failing the text or washing out the
  /// fill. [networkColor] stays close to the brand; this one goes as far as
  /// legibility needs.
  final Map<ChatNetwork, Color> networkTextColors;

  /// Ink for the glyph inside a network chip.
  ///
  /// One colour for the whole set rather than one per network: chosen per fill,
  /// a rail would come out half white glyphs and half black, which reads as a
  /// bug rather than as contrast care.
  final Color networkInk;

  Color networkColor(ChatNetwork network) =>
      networkColors[network] ?? Color(network.brandColor);

  Color networkTextColor(ChatNetwork network) =>
      networkTextColors[network] ?? networkColor(network);

  /// Secondary ink on [background] — dimmed for hierarchy, but never past AA.
  ///
  /// Timestamps, delivery ticks, file sizes and reply-chip bodies all want to
  /// recede; an unconditional `withValues(alpha: 0.6)` turns a guaranteed
  /// 4.5:1 pair into roughly 2.3:1. This gives up only as much of the dimming
  /// as the contrast needs, so each theme gets the most hierarchy it can afford.
  Color muted(Color ink, Color background, {double alpha = 0.6}) =>
      WeftContrast.dim(ink, background, alpha: alpha);

  /// Secondary ink on a message bubble.
  Color mutedOnBubble(bool own, {double alpha = 0.6}) => muted(
    own ? ownBubbleText : peerBubbleText,
    own ? ownBubble : peerBubble,
    alpha: alpha,
  );

  @override
  WeftPalette copyWith({
    Color? ownBubble,
    Color? ownBubbleText,
    Color? peerBubble,
    Color? peerBubbleText,
    Color? railBackground,
    Color? railSelected,
    Color? unreadDot,
    Color? mergedAccent,
    Color? online,
    Color? callAccept,
    Color? callDecline,
    Color? onCallAccept,
    Color? onCallDecline,
    Color? divider,
    Color? border,
    Color? focusRing,
    Color? scrim,
    Map<ChatNetwork, Color>? networkColors,
    Map<ChatNetwork, Color>? networkTextColors,
    Color? networkInk,
  }) {
    return WeftPalette(
      ownBubble: ownBubble ?? this.ownBubble,
      ownBubbleText: ownBubbleText ?? this.ownBubbleText,
      peerBubble: peerBubble ?? this.peerBubble,
      peerBubbleText: peerBubbleText ?? this.peerBubbleText,
      railBackground: railBackground ?? this.railBackground,
      railSelected: railSelected ?? this.railSelected,
      unreadDot: unreadDot ?? this.unreadDot,
      mergedAccent: mergedAccent ?? this.mergedAccent,
      online: online ?? this.online,
      callAccept: callAccept ?? this.callAccept,
      callDecline: callDecline ?? this.callDecline,
      onCallAccept: onCallAccept ?? this.onCallAccept,
      onCallDecline: onCallDecline ?? this.onCallDecline,
      divider: divider ?? this.divider,
      border: border ?? this.border,
      focusRing: focusRing ?? this.focusRing,
      scrim: scrim ?? this.scrim,
      networkColors: networkColors ?? this.networkColors,
      networkTextColors: networkTextColors ?? this.networkTextColors,
      networkInk: networkInk ?? this.networkInk,
    );
  }

  @override
  WeftPalette lerp(ThemeExtension<WeftPalette>? other, double t) {
    if (other is! WeftPalette) return this;
    return WeftPalette(
      ownBubble: Color.lerp(ownBubble, other.ownBubble, t)!,
      ownBubbleText: Color.lerp(ownBubbleText, other.ownBubbleText, t)!,
      peerBubble: Color.lerp(peerBubble, other.peerBubble, t)!,
      peerBubbleText: Color.lerp(peerBubbleText, other.peerBubbleText, t)!,
      railBackground: Color.lerp(railBackground, other.railBackground, t)!,
      railSelected: Color.lerp(railSelected, other.railSelected, t)!,
      unreadDot: Color.lerp(unreadDot, other.unreadDot, t)!,
      mergedAccent: Color.lerp(mergedAccent, other.mergedAccent, t)!,
      online: Color.lerp(online, other.online, t)!,
      callAccept: Color.lerp(callAccept, other.callAccept, t)!,
      callDecline: Color.lerp(callDecline, other.callDecline, t)!,
      onCallAccept: Color.lerp(onCallAccept, other.onCallAccept, t)!,
      onCallDecline: Color.lerp(onCallDecline, other.onCallDecline, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      border: Color.lerp(border, other.border, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      networkColors: t < 0.5 ? networkColors : other.networkColors,
      networkTextColors: t < 0.5 ? networkTextColors : other.networkTextColors,
      networkInk: Color.lerp(networkInk, other.networkInk, t)!,
    );
  }
}

/// Builds Weft's themes.
abstract final class WeftTheme {
  /// Default seed. A deep indigo-violet: distinct from every network brand
  /// colour, so the app chrome never reads as belonging to one of them.
  static const Color defaultSeed = Color(0xFF6C5CE7);

  /// [highContrast] comes from `MediaQuery.highContrast` and [reduceMotion]
  /// from `MediaQuery.disableAnimations` — both are read once, at the app root,
  /// so every widget below gets the answer through the theme rather than each
  /// checking for itself.
  ///
  /// [surface] is the same idea for the machine. It is the theme's job because
  /// almost everything it changes is a theme value: a Mac's body text is 13pt
  /// and a phone's is 15, a Mac's controls are 22pt tall and a phone's are 48,
  /// a Mac has no ripple, and a Mac's corners are 7pt where a phone's are 14.
  /// Widgets that need more than metrics read [WeftSurfaceContext.isMac].
  static ThemeData build({
    Color seed = defaultSeed,
    Brightness brightness = Brightness.dark,
    bool amoled = false,
    double densityScale = 0,
    bool highContrast = false,
    bool reduceMotion = false,
    WeftSurface surface = WeftSurface.touch,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      // Material's own high-contrast tone mapping: it pushes the on-colours to
      // the ends of their tonal palettes, which is exactly the adjustment that
      // would otherwise have to be hand-made for every scheme slot.
      contrastLevel: highContrast ? 1.0 : 0.0,
    );

    // AMOLED pushes the base surface to true black to save power on OLED and
    // to make the accent colours pop, but keeps elevated surfaces lifted so the
    // hierarchy doesn't collapse into an unreadable void.
    final effectiveScheme = amoled && brightness == Brightness.dark
        ? scheme.copyWith(
            surface: const Color(0xFF000000),
            surfaceContainerLowest: const Color(0xFF000000),
            surfaceContainerLow: const Color(0xFF0A0A0C),
            surfaceContainer: const Color(0xFF121216),
            surfaceContainerHigh: const Color(0xFF1A1A20),
            surfaceContainerHighest: const Color(0xFF222229),
          )
        : scheme;

    final isDark = brightness == Brightness.dark;
    final palette = _paletteFor(
      effectiveScheme,
      isDark: isDark,
      amoled: amoled,
      highContrast: highContrast,
    );

    // A visible ring rather than Material's default focus overlay, which is an
    // alpha wash of `onSurface` — on the AMOLED palette that is a very dark
    // grey on black and nowhere near the 3:1 WCAG 1.4.11 asks of a focus
    // indicator.
    final focusedSide = WidgetStateProperty.resolveWith<BorderSide?>(
      (states) => states.contains(WidgetState.focused)
          ? BorderSide(color: palette.focusRing, width: 2)
          : null,
    );

    final mac = surface == WeftSurface.mac;
    // Every control shrinks on the desktop. Material's own compact density is
    // exactly the -2 the system's controls sit at against its touch defaults,
    // so the user's density preference rides on top of it rather than
    // replacing it.
    final density = mac
        ? VisualDensity(horizontal: -2 + densityScale, vertical: -2 + densityScale)
        : VisualDensity(horizontal: densityScale, vertical: densityScale);

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: effectiveScheme,
      scaffoldBackgroundColor: effectiveScheme.surface,
      // The system face, which on this platform is what "not a mobile app"
      // most immediately means: Roboto in a Mac window is recognisable at a
      // glance and wrong. Falls back to whatever the test runner has loaded,
      // so a golden still renders real glyphs.
      typography: mac
          ? Typography.material2021(
              platform: TargetPlatform.macOS,
              colorScheme: effectiveScheme,
            )
          : null,
      visualDensity: density,
      // The sparkle is a 400ms travelling highlight — the single most motion-y
      // thing in the app, and the first to go when the user has asked for none.
      splashFactory: reduceMotion
          ? NoSplash.splashFactory
          : InkSparkle.splashFactory,
      pageTransitionsTheme: reduceMotion
          ? _noPageTransitions
          : const PageTransitionsTheme(),
      focusColor: palette.focusRing.withValues(alpha: 0.28),
      appBarTheme: AppBarTheme(
        backgroundColor: effectiveScheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(
        color: palette.divider,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: effectiveScheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(borderRadius: WeftRadius.allLg),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const RoundedRectangleBorder(borderRadius: WeftRadius.allMd),
          padding: const EdgeInsets.symmetric(
            horizontal: WeftSpace.xl,
            vertical: WeftSpace.md,
          ),
        ).copyWith(side: focusedSide),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(side: focusedSide),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(side: focusedSide),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(side: focusedSide),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: effectiveScheme.surfaceContainerHigh,
        border: const OutlineInputBorder(
          borderRadius: WeftRadius.allMd,
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: WeftRadius.allMd,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: WeftRadius.allMd,
          borderSide: BorderSide(color: palette.focusRing, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: WeftSpace.lg,
          vertical: WeftSpace.md,
        ),
      ),
      extensions: [
        palette,
        WeftMotionTokens(reduced: reduceMotion),
        WeftSurfaceTokens(surface: surface),
      ],
    );

    return mac ? _macify(base, palette) : base;
  }

  /// Re-fits a built theme to the desktop.
  ///
  /// Applied on top of the shared theme rather than branched inside it,
  /// because everything above this point is a decision about *Braid* — the
  /// palette, the contrast corrections, the focus ring — and everything here
  /// is a decision about *macOS*. Keeping the two apart is what stops the
  /// colour work from having to be repeated per platform.
  static ThemeData _macify(ThemeData base, WeftPalette palette) {
    final scheme = base.colorScheme;
    final text = _macTextTheme(base.textTheme);
    const radius = MacMetrics.controlRadius;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    return base.copyWith(
      textTheme: text,
      primaryTextTheme: text,
      // macOS has no ripple. A travelling highlight under the pointer is the
      // single loudest "this is an Android app" tell there is.
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: scheme.onSurface.withValues(alpha: 0.06),
      appBarTheme: base.appBarTheme.copyWith(
        toolbarHeight: MacMetrics.toolbarHeight,
        titleTextStyle: text.titleSmall,
      ),
      dividerTheme: base.dividerTheme.copyWith(thickness: 0.5, space: 0.5),
      cardTheme: base.cardTheme.copyWith(shape: shape),
      // Hairline scrollbars that appear while scrolling, as the system's do.
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(7),
        radius: const Radius.circular(4),
        thumbVisibility: const WidgetStatePropertyAll(false),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => scheme.onSurface.withValues(
            alpha: states.contains(WidgetState.hovered) ? 0.45 : 0.28,
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 900),
        textStyle: text.labelSmall?.copyWith(color: scheme.onSurface),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: palette.border, width: 0.5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MacMetrics.popoverRadius - 4),
          side: BorderSide(color: palette.border, width: 0.5),
        ),
        textStyle: text.bodyMedium,
        // A menu item is 22pt on this platform, not the 48 Material gives it.
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MacMetrics.popoverRadius),
        ),
        // A Mac alert is a narrow, centred column with the title above the
        // body and the buttons at the trailing edge — not a wide sheet.
        alignment: Alignment.center,
        titleTextStyle: text.titleSmall,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MacMetrics.sheetRadius),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: base.filledButtonTheme.style?.copyWith(
          shape: WidgetStatePropertyAll(shape),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: WeftSpace.md, vertical: 4),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(0, 24)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: (base.textButtonTheme.style ?? const ButtonStyle()).copyWith(
          shape: WidgetStatePropertyAll(shape),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: WeftSpace.md, vertical: 4),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(0, 24)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: (base.outlinedButtonTheme.style ?? const ButtonStyle()).copyWith(
          shape: WidgetStatePropertyAll(shape),
          minimumSize: const WidgetStatePropertyAll(Size(0, 24)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        minVerticalPadding: 2,
        // `dense` shrinks the *text* and leaves the box: a menu of five items
        // still came out 240 points tall, where the system's is nearer 120.
        // The height and the density are what actually move it.
        minTileHeight: 30,
        visualDensity: VisualDensity.compact,
        iconColor: scheme.onSurfaceVariant,
        horizontalTitleGap: WeftSpace.sm,
        titleTextStyle: text.bodyMedium,
        subtitleTextStyle: text.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        shape: shape,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: palette.focusRing, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: WeftSpace.sm,
          vertical: 6,
        ),
        isDense: true,
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      checkboxTheme: CheckboxThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
      radioTheme: const RadioThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// The system's type scale, mapped onto the slots the app already reads.
  ///
  /// macOS is an 11/13 platform: 13pt is body and every list row, 11pt is every
  /// secondary line, and a window title is 13pt semibold rather than the 22pt
  /// headline a phone screen puts at the top. Nothing in the app has to change
  /// for this — the sizes travel through the slots the widgets already use,
  /// which is the whole reason to express it as a text theme.
  static TextTheme _macTextTheme(TextTheme base) {
    TextStyle? at(TextStyle? style, double size, [FontWeight? weight]) =>
        style?.copyWith(
          fontSize: size,
          fontWeight: weight,
          // The system's own tracking at these sizes; Material's is looser
          // because it is designed for a larger body size.
          letterSpacing: 0,
        );

    return base.copyWith(
      displayLarge: at(base.displayLarge, 34, FontWeight.w700),
      displayMedium: at(base.displayMedium, 28, FontWeight.w700),
      displaySmall: at(base.displaySmall, 26, FontWeight.w700),
      headlineLarge: at(base.headlineLarge, 22, FontWeight.w700),
      headlineMedium: at(base.headlineMedium, 20, FontWeight.w600),
      headlineSmall: at(base.headlineSmall, 17, FontWeight.w600),
      titleLarge: at(base.titleLarge, 15, FontWeight.w600),
      titleMedium: at(base.titleMedium, 13, FontWeight.w600),
      titleSmall: at(base.titleSmall, 13, FontWeight.w600),
      bodyLarge: at(base.bodyLarge, 13, FontWeight.w400),
      bodyMedium: at(base.bodyMedium, 13, FontWeight.w400),
      bodySmall: at(base.bodySmall, 12, FontWeight.w400),
      labelLarge: at(base.labelLarge, 13, FontWeight.w500),
      labelMedium: at(base.labelMedium, 11, FontWeight.w500),
      labelSmall: at(base.labelSmall, 11, FontWeight.w400),
    );
  }

  static final PageTransitionsTheme _noPageTransitions = PageTransitionsTheme(
    builders: {
      for (final platform in TargetPlatform.values)
        platform: const _NoPageTransitionsBuilder(),
    },
  );

  static WeftPalette _paletteFor(
    ColorScheme scheme, {
    required bool isDark,
    required bool amoled,
    required bool highContrast,
  }) {
    final peerBubble = amoled
        ? const Color(0xFF16161B)
        : scheme.surfaceContainerHigh;

    // The two backgrounds every accent in this palette is read against: the
    // page itself, and the peer bubble a network name or a reply title sits
    // inside. A colour that clears both clears everything in between.
    final backgrounds = [scheme.surface, peerBubble];

    // Deliberately fixed as a *fill* (see [WeftPalette.callAccept]) but read as
    // text in six places, so the presence/success token is the corrected one
    // and the call fills stay put with corrected ink instead.
    const brandGreen = Color(0xFF2ECC71);
    const brandRed = Color(0xFFE5484D);

    // The "Merged" pill tints its own background with the accent at 16% and
    // then puts the same accent on top, so one of the backgrounds this has to
    // clear is derived from the candidate itself — hence the callback rather
    // than a fixed list.
    final mergedAccent = _ensureOn(
      scheme.tertiary,
      (candidate) => [
        ...backgrounds,
        WeftContrast.flatten(candidate.withValues(alpha: 0.16), scheme.surface),
      ],
      WeftContrast.bodyText,
    );

    // Two derivations of each brand colour, because the app uses it two ways
    // and the two have different bars. As a *fill* — the glyph chip, the
    // merged ring, a bubble's origin hairline — it is a graphic bounding a
    // control and owes 3:1. As *text* — the network name in a merged bubble,
    // a reply title, a link preview's host — it owes 4.5:1, which at the light
    // theme's L=0.58 clamp it misses by a wide margin.
    final networkFills = {
      for (final n in ChatNetwork.values)
        n: _ensureOn(
          _harmonize(Color(n.brandColor), scheme, isDark: isDark),
          (_) => backgrounds,
          WeftContrast.uiComponent,
        ),
    };
    final networkInk = _glyphInkFor(networkFills.values);
    final networkColors = {
      for (final entry in networkFills.entries)
        entry.key: _ensureGlyphInk(entry.value, networkInk),
    };
    final networkTextColors = {
      for (final entry in networkColors.entries)
        entry.key: _ensureOn(
          entry.value,
          (_) => backgrounds,
          WeftContrast.bodyText,
        ),
    };

    final border = _ensureOn(
      scheme.outlineVariant,
      (_) => backgrounds,
      WeftContrast.uiComponent,
    );

    return WeftPalette(
      ownBubble: scheme.primary,
      ownBubbleText: scheme.onPrimary,
      peerBubble: peerBubble,
      peerBubbleText: scheme.onSurface,
      railBackground: amoled
          ? const Color(0xFF000000)
          : scheme.surfaceContainerLowest,
      railSelected: scheme.primaryContainer,
      unreadDot: scheme.primary,
      mergedAccent: mergedAccent,
      online: _ensureOn(brandGreen, (_) => backgrounds, WeftContrast.bodyText),
      callAccept: brandGreen,
      callDecline: brandRed,
      // White is the glyph these buttons were designed with; it survives on the
      // decline red at 3.9:1 and collapses to 1.9:1 on the accept green, so
      // only the accept button's ink actually moves.
      onCallAccept: WeftContrast.inkOn(
        brandGreen,
        preferred: const Color(0xFFFFFFFF),
      ),
      onCallDecline: WeftContrast.inkOn(
        brandRed,
        preferred: const Color(0xFFFFFFFF),
      ),
      // A hairline between two blocks of content is not a UI component under
      // WCAG 1.4.11, so this is allowed to stay faint — except under high
      // contrast, where the user has said the faint version does not work.
      divider: highContrast
          ? border
          : scheme.outlineVariant.withValues(alpha: 0.5),
      border: border,
      // Every surface a focusable control is drawn *on* — the page, a field's
      // fill, a card, the rail. Deliberately not the control's own fill: the
      // ring is drawn on the outer boundary, so what it has to stand out
      // against is what surrounds the control. Requiring it to clear both a
      // near-white page and the dark `primaryContainer` of a selected rail
      // item is arithmetically impossible under high contrast — the two
      // demands point opposite ways — and pretending otherwise would only
      // move the failure somewhere less visible.
      focusRing: _ensureOn(
        scheme.primary,
        (_) => [
          scheme.surface,
          scheme.surfaceContainerHigh,
          scheme.surfaceContainerLow,
          amoled ? const Color(0xFF000000) : scheme.surfaceContainerLowest,
        ],
        WeftContrast.uiComponent,
      ),
      // Heavy enough that white ink over a bright video frame or a
      // sun-blown photograph still clears 4.5:1 — the frame under it can be
      // any colour at all, so the wash has to do the whole job.
      scrim: const Color(0xFF000000).withValues(alpha: 0.62),
      networkColors: networkColors,
      networkTextColors: networkTextColors,
      networkInk: networkInk,
    );
  }

  /// The lightness of [color] closest to its own that clears [minRatio] on
  /// every background [backgrounds] reports for it.
  ///
  /// A nearest-first search over both directions rather than a fix-up loop:
  /// correcting for one background can break another — darkening a colour for
  /// the page pushes it into the peer bubble it also sits on — and chasing that
  /// pairwise oscillates instead of converging. Searching the whole axis for a
  /// value that satisfies *all* of them at once has no such failure mode, and
  /// "closest first" keeps the token as near the designed colour as legibility
  /// allows.
  ///
  /// [backgrounds] is a function of the candidate because some backgrounds are
  /// derived from the colour itself — the "Merged" pill is a 16% tint of the
  /// very accent that has to be readable on it.
  ///
  /// Returns [color] untouched when no lightness satisfies every background,
  /// which means the constraints contradict each other and belongs in the
  /// token test as a loud failure rather than in a silent approximation here.
  static Color _ensureOn(
    Color color,
    List<Color> Function(Color candidate) backgrounds,
    double minRatio,
  ) {
    bool satisfied(Color candidate) => backgrounds(
      candidate,
    ).every((bg) => WeftContrast.meets(candidate, bg, minRatio: minRatio));

    if (satisfied(color)) return color;

    final hsl = HSLColor.fromColor(color);
    for (var step = 1; step <= 100; step++) {
      for (final lightness in [
        hsl.lightness - step / 100,
        hsl.lightness + step / 100,
      ]) {
        if (lightness < 0 || lightness > 1) continue;
        final candidate = hsl.withLightness(lightness).toColor();
        if (satisfied(candidate)) return candidate;
      }
    }
    return color;
  }

  /// One ink for every network chip in a theme.
  ///
  /// Deliberately not per-network: chosen per fill, a light theme's rail would
  /// come out half white glyphs and half black ones, which reads as a bug
  /// rather than as contrast care. So the whole set gets whichever ink has the
  /// better *worst* case across every network — and [_ensureGlyphInk] then
  /// moves the few fills that ink still fails on.
  static Color _glyphInkFor(Iterable<Color> fills) {
    const dark = Color(0xFF000000);
    const light = Color(0xFFFFFFFF);
    double worst(Color ink) => fills
        .expand(_gradientStops)
        .map((stop) => WeftContrast.ratio(ink, stop))
        .reduce((a, b) => a < b ? a : b);
    return worst(dark) >= worst(light) ? dark : light;
  }

  /// [fill] moved along its lightness axis only as far as [ink] needs to clear
  /// 3:1 on it — away from the ink, so a white glyph darkens its chip and a
  /// black one lightens it.
  ///
  /// The chip is a gradient from the brand colour to 22% black, so both ends
  /// have to hold; the darker end is where a white glyph gives out. Hue and
  /// saturation are untouched, which is what keeps the chip recognisably
  /// WhatsApp-green after the correction.
  static Color _ensureGlyphInk(Color fill, Color ink) {
    bool legible(Color candidate) => _gradientStops(candidate).every(
      (stop) =>
          WeftContrast.meets(ink, stop, minRatio: WeftContrast.uiComponent),
    );
    if (legible(fill)) return fill;

    final darken = ink.computeLuminance() > 0.5;
    final hsl = HSLColor.fromColor(fill);
    for (var step = 1; step <= 100; step++) {
      final lightness =
          (darken ? hsl.lightness - step / 100 : hsl.lightness + step / 100)
              .clamp(0.0, 1.0);
      final candidate = hsl.withLightness(lightness).toColor();
      if (legible(candidate)) return candidate;
      if (lightness == 0 || lightness == 1) break;
    }
    return fill;
  }

  static List<Color> _gradientStops(Color fill) => [
    fill,
    Color.lerp(fill, const Color(0xFF000000), 0.22)!,
  ];

  /// Nudges a brand colour toward the active scheme so a rail of eight logos
  /// reads as one designed set rather than eight competing brands — while
  /// staying recognisably WhatsApp-green or Telegram-blue.
  static Color _harmonize(
    Color brand,
    ColorScheme scheme, {
    required bool isDark,
  }) {
    final blended = Color.lerp(brand, scheme.primary, 0.12)!;
    final hsl = HSLColor.fromColor(blended);

    // On dark surfaces a saturated mid-tone brand colour is hard to read;
    // lifting lightness and trimming saturation keeps contrast usable.
    final lightness = isDark
        ? hsl.lightness.clamp(0.52, 0.78)
        : hsl.lightness.clamp(0.32, 0.58);
    return hsl
        .withLightness(lightness)
        .withSaturation(hsl.saturation.clamp(0.35, 0.85))
        .toColor();
  }
}

/// Routes that arrive without moving.
///
/// `PageTransitionsTheme` has no "none" builder of its own, and reduced motion
/// has to reach page changes too — they are the largest movement in the app.
class _NoPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

/// Convenience accessors so widgets don't repeat the lookup dance.
extension WeftThemeContext on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;

  WeftPalette get palette =>
      Theme.of(this).extension<WeftPalette>() ??
      WeftTheme.build().extension<WeftPalette>()!;

  /// Durations to animate at, with the platform's reduce-motion setting already
  /// applied. Use this rather than [WeftMotion] directly at any animation site.
  WeftMotionTokens get motion =>
      Theme.of(this).extension<WeftMotionTokens>() ?? const WeftMotionTokens();
}
