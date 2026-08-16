import 'package:flutter/material.dart';
import 'package:weft_domain/weft_domain.dart';

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
    required this.divider,
    required this.networkColors,
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

  final Color online;
  final Color divider;

  /// Per-network brand colours, already harmonised against the active scheme so
  /// WhatsApp green doesn't fight a purple theme.
  final Map<ChatNetwork, Color> networkColors;

  Color networkColor(ChatNetwork network) =>
      networkColors[network] ?? Color(network.brandColor);

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
    Color? divider,
    Map<ChatNetwork, Color>? networkColors,
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
      divider: divider ?? this.divider,
      networkColors: networkColors ?? this.networkColors,
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
      divider: Color.lerp(divider, other.divider, t)!,
      networkColors: t < 0.5 ? networkColors : other.networkColors,
    );
  }
}

/// Builds Weft's themes.
abstract final class WeftTheme {
  /// Default seed. A deep indigo-violet: distinct from every network brand
  /// colour, so the app chrome never reads as belonging to one of them.
  static const Color defaultSeed = Color(0xFF6C5CE7);

  static ThemeData build({
    Color seed = defaultSeed,
    Brightness brightness = Brightness.dark,
    bool amoled = false,
    double densityScale = 0,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
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

    return ThemeData(
      useMaterial3: true,
      colorScheme: effectiveScheme,
      scaffoldBackgroundColor: effectiveScheme.surface,
      visualDensity: VisualDensity(
        horizontal: densityScale,
        vertical: densityScale,
      ),
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: effectiveScheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(
        color: effectiveScheme.outlineVariant.withValues(alpha: 0.5),
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
        ),
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
          borderSide: BorderSide(color: effectiveScheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: WeftSpace.lg,
          vertical: WeftSpace.md,
        ),
      ),
      extensions: [
        _paletteFor(effectiveScheme, isDark: isDark, amoled: amoled),
      ],
    );
  }

  static WeftPalette _paletteFor(
    ColorScheme scheme, {
    required bool isDark,
    required bool amoled,
  }) {
    return WeftPalette(
      ownBubble: scheme.primary,
      ownBubbleText: scheme.onPrimary,
      peerBubble: amoled
          ? const Color(0xFF16161B)
          : scheme.surfaceContainerHigh,
      peerBubbleText: scheme.onSurface,
      railBackground: amoled
          ? const Color(0xFF000000)
          : scheme.surfaceContainerLowest,
      railSelected: scheme.primaryContainer,
      unreadDot: scheme.primary,
      mergedAccent: scheme.tertiary,
      online: const Color(0xFF2ECC71),
      divider: scheme.outlineVariant.withValues(alpha: 0.5),
      networkColors: {
        for (final n in ChatNetwork.values)
          n: _harmonize(Color(n.brandColor), scheme, isDark: isDark),
      },
    );
  }

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

/// Convenience accessors so widgets don't repeat the lookup dance.
extension WeftThemeContext on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;

  WeftPalette get palette =>
      Theme.of(this).extension<WeftPalette>() ??
      WeftTheme.build().extension<WeftPalette>()!;
}
