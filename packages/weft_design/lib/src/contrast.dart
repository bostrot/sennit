import 'package:flutter/widgets.dart';

/// WCAG 2.1 contrast maths, and the three helpers the token layer needs to act
/// on the answer.
///
/// This lives in `weft_design` rather than in a test because contrast is a
/// property of the *tokens*, not of the screens that use them: a colour that
/// fails here fails on every screen at once, and the fix belongs where the
/// colour is defined. [ensure], [inkOn] and [dim] are what let
/// `WeftTheme._paletteFor` state "this token is readable" as code rather than
/// as a hope, so a new seed colour cannot quietly push a token below AA.
///
/// The thresholds are WCAG 2.1 AA:
///
/// - [bodyText] (4.5:1) — text under 18pt, or under 14pt bold. Almost all of
///   Weft's text, including every timestamp and label.
/// - [largeText] (3.0:1) — 18pt+, or 14pt+ bold.
/// - [uiComponent] (3.0:1) — the visual boundary of a control, its focus
///   indicator, and any graphic that carries meaning. Success/presence dots,
///   the call buttons and the composer's border are all this.
///
/// A divider between two blocks of content is explicitly *not* a UI component
/// under WCAG 1.4.11 and has no minimum — which is why Weft carries both a
/// [WeftPalette.divider] hairline and a [WeftPalette.border] that does meet the
/// bar, rather than one token pretending to be both.
abstract final class WeftContrast {
  /// Minimum ratio for body-size text — WCAG 2.1 AA, 1.4.3.
  static const double bodyText = 4.5;

  /// Minimum ratio for large text (18pt, or 14pt bold) — WCAG 2.1 AA, 1.4.3.
  static const double largeText = 3;

  /// Minimum ratio for a control boundary, a focus ring or a meaningful
  /// graphic — WCAG 2.1 AA, 1.4.11.
  static const double uiComponent = 3;

  /// Contrast ratio between [foreground] and [background], from 1.0 (identical)
  /// to 21.0 (black on white).
  ///
  /// A translucent [foreground] is composited over [background] first, because
  /// that is what the screen shows and therefore what the eye has to read. This
  /// is the difference between "the token is fine" and "the token is fine until
  /// someone dims it to 60%", which is how most of Weft's failures got there.
  static double ratio(Color foreground, Color background) {
    final a = flatten(foreground, background).computeLuminance();
    final b = background.withValues(alpha: 1).computeLuminance();
    final (lighter, darker) = a >= b ? (a, b) : (b, a);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Composites [foreground] over [background] using source-over, returning an
  /// opaque colour.
  ///
  /// Contrast is undefined for a translucent colour on its own; everything else
  /// here goes through this first.
  static Color flatten(Color foreground, Color background) {
    if (foreground.a >= 1) return foreground;
    final base = background.withValues(alpha: 1);
    if (foreground.a <= 0) return base;
    return Color.lerp(base, foreground.withValues(alpha: 1), foreground.a)!;
  }

  /// True when [foreground] on [background] clears [minRatio].
  static bool meets(
    Color foreground,
    Color background, {
    double minRatio = bodyText,
  }) => ratio(foreground, background) + _epsilon >= minRatio;

  /// [preferred] if it already clears [minRatio] on [background], otherwise
  /// whichever of [dark] and [light] reads better there.
  ///
  /// The call buttons are the reason this exists, and the reason [preferred]
  /// exists with it: green-means-answer is fixed by every phone the user has
  /// ever held, so the fill cannot move — but the glyph on it can, and white
  /// on `#2ECC71` is 1.9:1 while black is 11:1. The decline red is a different
  /// case: white on `#E5484D` is already 3.9:1, and flipping it to black
  /// because black scores higher would rewrite a design that was not broken.
  /// Contrast correction should move what fails and leave what passes.
  static Color inkOn(
    Color background, {
    Color dark = const Color(0xFF000000),
    Color light = const Color(0xFFFFFFFF),
    Color? preferred,
    double minRatio = uiComponent,
  }) {
    if (preferred != null && meets(preferred, background, minRatio: minRatio)) {
      return preferred;
    }
    return ratio(dark, background) >= ratio(light, background) ? dark : light;
  }

  /// [color] pushed along its own lightness axis until it clears [minRatio]
  /// against [background], keeping hue and saturation.
  ///
  /// Direction is chosen by which end has room: a colour on a light surface
  /// darkens, one on a dark surface lightens. Both directions are tried when
  /// the first runs out of range — a mid-tone brand colour on a mid-tone
  /// surface can only be fixed by going the other way.
  ///
  /// Returns the closest colour it found when even black-or-white cannot reach
  /// [minRatio], which happens only for a background with no headroom at all.
  static Color ensure(
    Color color,
    Color background, {
    double minRatio = bodyText,
  }) {
    if (meets(color, background, minRatio: minRatio)) return color;

    // Which way has room is decided by which plain ink reads better on this
    // background, rather than by a luminance threshold — the two agree on
    // ordinary surfaces and the ink test is right on the awkward mid-tones.
    final darkenFirst =
        ratio(const Color(0xFF000000), background) >=
        ratio(const Color(0xFFFFFFFF), background);
    final hsl = HSLColor.fromColor(flatten(color, background));

    // Darken first on a light surface, lighten first on a dark one, then fall
    // back to the other direction.
    for (final descending in [darkenFirst, !darkenFirst]) {
      for (var step = 1; step <= _steps; step++) {
        final lightness =
            (descending
                    ? hsl.lightness - step / _steps
                    : hsl.lightness + step / _steps)
                .clamp(0.0, 1.0);
        final candidate = hsl.withLightness(lightness).toColor();
        if (meets(candidate, background, minRatio: minRatio)) {
          return candidate.withValues(alpha: color.a);
        }
        if (lightness == 0 || lightness == 1) break;
      }
    }

    // No lightness of this hue works; fall back to plain ink so the text is at
    // least readable, which is the point.
    return inkOn(background).withValues(alpha: color.a);
  }

  /// [ink] dimmed to [alpha] for visual hierarchy, then backed off toward
  /// opaque if that would drop it below [minRatio] against [background].
  ///
  /// Weft dims ink in fourteen places — timestamps, delivery ticks, file sizes,
  /// reply-chip bodies — and every one of them was a plain
  /// `withValues(alpha: 0.6)` that turned a 4.5:1 pair into roughly 2.3:1. The
  /// intent (this text is secondary) is right; the unconditional alpha is not.
  /// This keeps the intent and gives up exactly as much of the dimming as the
  /// contrast requires, so a light theme and a dark one each get the most
  /// hierarchy they can afford.
  static Color dim(
    Color ink,
    Color background, {
    double alpha = 0.6,
    double minRatio = bodyText,
  }) {
    final clamped = alpha.clamp(0.0, 1.0);
    final dimmed = ink.withValues(alpha: clamped);
    if (meets(dimmed, background, minRatio: minRatio)) return dimmed;

    // Walk back toward the undimmed ink. If even that fails the pair itself is
    // broken and belongs in the token test, not patched here.
    for (var step = 1; step <= _steps; step++) {
      final candidate = ink.withValues(
        alpha: (clamped + (1 - clamped) * step / _steps).clamp(0.0, 1.0),
      );
      if (meets(candidate, background, minRatio: minRatio)) return candidate;
    }
    return ink;
  }

  /// Resolution of the lightness and alpha searches. 100 steps is 1% of the
  /// range — finer than any colour difference a display can show.
  static const int _steps = 100;

  /// Absorbs the last bit of float error so a token computed to be exactly
  /// 4.5:1 does not fail the assertion that asked for 4.5:1.
  static const double _epsilon = 1e-9;
}
