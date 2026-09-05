import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

/// User-facing appearance settings.
///
/// Held in memory for now; `weft_store` persists these in M5 alongside the rest
/// of the settings surface.
@immutable
class WeftAppearance {
  const WeftAppearance({
    this.mode = WeftThemeMode.system,
    this.seed = WeftTheme.defaultSeed,
    this.densityScale = 0,
  });

  final WeftThemeMode mode;
  final Color seed;

  /// -1 (compact) … 1 (comfortable), fed to [VisualDensity].
  final double densityScale;

  WeftAppearance copyWith({
    WeftThemeMode? mode,
    Color? seed,
    double? densityScale,
  }) {
    return WeftAppearance(
      mode: mode ?? this.mode,
      seed: seed ?? this.seed,
      densityScale: densityScale ?? this.densityScale,
    );
  }

  /// [highContrast] and [reduceMotion] are the platform's own accessibility
  /// switches, not Braid settings — they arrive from `MediaQuery` at the app
  /// root and are folded into the theme so no widget below has to ask.
  ThemeData themeFor(
    Brightness platformBrightness, {
    bool highContrast = false,
    bool reduceMotion = false,
    WeftSurface surface = WeftSurface.touch,
    bool? pointer,
  }) {
    final brightness = switch (mode) {
      WeftThemeMode.light => Brightness.light,
      WeftThemeMode.dark || WeftThemeMode.amoled => Brightness.dark,
      WeftThemeMode.system => platformBrightness,
    };
    return WeftTheme.build(
      seed: seed,
      brightness: brightness,
      amoled: mode == WeftThemeMode.amoled,
      densityScale: densityScale,
      highContrast: highContrast,
      reduceMotion: reduceMotion,
      surface: surface,
      pointer: pointer,
    );
  }
}

class AppearanceNotifier extends Notifier<WeftAppearance> {
  @override
  WeftAppearance build() => const WeftAppearance();

  void setMode(WeftThemeMode mode) => state = state.copyWith(mode: mode);
  void setSeed(Color seed) => state = state.copyWith(seed: seed);
  void setDensity(double scale) => state = state.copyWith(densityScale: scale);
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, WeftAppearance>(
  AppearanceNotifier.new,
);

/// Preset accent colours offered in settings, chosen to stay distinct from
/// every network brand colour so app chrome never mimics one network.
const List<({String name, Color color})> weftAccentPresets = [
  (name: 'Violet', color: Color(0xFF6C5CE7)),
  (name: 'Ember', color: Color(0xFFE8590C)),
  (name: 'Teal', color: Color(0xFF0CA678)),
  (name: 'Rose', color: Color(0xFFD6336C)),
  (name: 'Slate', color: Color(0xFF4C6EF5)),
  (name: 'Amber', color: Color(0xFFF08C00)),
];
