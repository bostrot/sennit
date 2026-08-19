import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// Every foreground/background pair the token layer promises, asserted at WCAG
/// 2.1 AA across every theme Weft can be in.
///
/// This is the test the design system did not have: `weft_design` owns every
/// colour pair in the app, so a token that regresses below AA regresses on
/// every screen at once — and until now nothing would have noticed. The
/// assertions are computed rather than golden, which means a new seed colour,
/// a new network or a Material tone-mapping change is checked rather than
/// re-blessed.
void main() {
  group('contrast maths', () {
    test('black on white is 21:1 and white on white is 1:1', () {
      expect(
        WeftContrast.ratio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(21, 0.01),
      );
      expect(
        WeftContrast.ratio(const Color(0xFFFFFFFF), const Color(0xFFFFFFFF)),
        closeTo(1, 0.001),
      );
    });

    test('is symmetric — contrast has no foreground preference', () {
      const a = Color(0xFF6C5CE7);
      const b = Color(0xFFF2F2F7);
      expect(
        WeftContrast.ratio(a, b),
        closeTo(WeftContrast.ratio(b, a), 0.0001),
      );
    });

    test('a translucent foreground is measured composited, not raw', () {
      const ink = Color(0xFF000000);
      const background = Color(0xFFFFFFFF);
      // Raw, the colour is black and would score 21:1. What the eye sees is
      // 40% black on white — mid grey — and that is what must be scored.
      final dimmed = ink.withValues(alpha: 0.4);
      expect(WeftContrast.ratio(dimmed, background), lessThan(4.5));
      expect(
        WeftContrast.flatten(dimmed, background),
        WeftContrast.flatten(const Color(0x66000000), background),
      );
    });

    test('ensure() reaches the requested ratio from either direction', () {
      // A mid-tone green that fails on both a light and a dark surface.
      const green = Color(0xFF2ECC71);
      for (final background in [
        const Color(0xFFFFFFFF),
        const Color(0xFF000000),
        const Color(0xFF808080),
      ]) {
        final fixed = WeftContrast.ensure(green, background);
        expect(
          WeftContrast.ratio(fixed, background),
          greaterThanOrEqualTo(WeftContrast.bodyText),
          reason: 'ensure() left $fixed unreadable on $background',
        );
      }
    });

    test('ensure() keeps the hue it was given', () {
      const green = Color(0xFF2ECC71);
      final fixed = WeftContrast.ensure(green, const Color(0xFFFFFFFF));
      expect(
        HSLColor.fromColor(fixed).hue,
        closeTo(HSLColor.fromColor(green).hue, 1),
      );
    });

    test('inkOn moves the ink that fails and leaves the ink that passes', () {
      // The CONTRAST-2 finding, as an assertion: white on the accept green is
      // 1.9:1 and has to go; white on the decline red is 3.9:1 and stays.
      const green = Color(0xFF2ECC71);
      const red = Color(0xFFE5484D);
      const white = Color(0xFFFFFFFF);

      expect(WeftContrast.ratio(white, green), lessThan(3));
      expect(WeftContrast.ratio(white, red), greaterThan(3));
      expect(
        WeftContrast.inkOn(green, preferred: white),
        const Color(0xFF000000),
      );
      expect(WeftContrast.inkOn(red, preferred: white), white);
      // Without a preference it is simply the better of the two.
      expect(WeftContrast.inkOn(green), const Color(0xFF000000));
    });

    test('dim() gives up only as much alpha as contrast requires', () {
      const ink = Color(0xFFFFFFFF);
      const background = Color(0xFF6C5CE7);

      final dimmed = WeftContrast.dim(ink, background, alpha: 0.6);
      expect(
        WeftContrast.ratio(dimmed, background),
        greaterThanOrEqualTo(WeftContrast.bodyText),
      );
      // Not simply forced opaque: some dimming survives where it can.
      expect(dimmed.a, greaterThanOrEqualTo(0.6));

      // A pair with headroom keeps the alpha it asked for.
      final roomy = WeftContrast.dim(
        const Color(0xFF000000),
        const Color(0xFFFFFFFF),
        alpha: 0.6,
      );
      expect(roomy.a, closeTo(0.6, 0.001));
    });
  });

  group('token pairs meet WCAG AA', () {
    for (final variant in _variants) {
      group(variant.name, () {
        final theme = variant.build();
        final scheme = theme.colorScheme;
        final palette = theme.extension<WeftPalette>()!;

        for (final pair in _pairsFor(scheme, palette)) {
          test('${pair.name} — ${pair.minRatio}:1', () {
            final ratio = WeftContrast.ratio(pair.foreground, pair.background);
            expect(
              ratio,
              greaterThanOrEqualTo(pair.minRatio),
              reason:
                  '${pair.name} is ${ratio.toStringAsFixed(2)}:1 in '
                  '${variant.name} — ${pair.foreground} on ${pair.background}',
            );
          });
        }

        test('every network fill carries a legible glyph', () {
          for (final network in ChatNetwork.values) {
            final fill = palette.networkColor(network);
            // The chip is a gradient to 22% black; both ends have to hold.
            for (final stop in [
              fill,
              Color.lerp(fill, const Color(0xFF000000), 0.22)!,
            ]) {
              expect(
                WeftContrast.ratio(palette.networkInk, stop),
                greaterThanOrEqualTo(WeftContrast.uiComponent),
                reason: '${network.label} glyph on $stop in ${variant.name}',
              );
            }
          }
        });

        test(
          'every network reads as text on the surface and a peer bubble',
          () {
            for (final network in ChatNetwork.values) {
              for (final background in [scheme.surface, palette.peerBubble]) {
                expect(
                  WeftContrast.ratio(
                    palette.networkTextColor(network),
                    background,
                  ),
                  greaterThanOrEqualTo(WeftContrast.bodyText),
                  reason:
                      '${network.label} as text on $background in '
                      '${variant.name}',
                );
              }
            }
          },
        );

        test(
          'dimmed bubble ink stays readable at every alpha the app uses',
          () {
            // The alphas from the CONTRAST-3 register, applied through the
            // palette's own helper rather than raw.
            for (final alpha in [0.55, 0.6, 0.7, 0.75, 0.8, 0.9]) {
              for (final own in [true, false]) {
                expect(
                  WeftContrast.ratio(
                    palette.mutedOnBubble(own, alpha: alpha),
                    own ? palette.ownBubble : palette.peerBubble,
                  ),
                  greaterThanOrEqualTo(WeftContrast.bodyText),
                  reason:
                      'muted ink at $alpha on the '
                      '${own ? 'own' : 'peer'} bubble in ${variant.name}',
                );
              }
            }
          },
        );
      });
    }
  });

  group('accessibility switches reach the theme', () {
    test('high contrast raises the scheme, not just the palette', () {
      final plain = WeftTheme.build(brightness: Brightness.light);
      final high = WeftTheme.build(
        brightness: Brightness.light,
        highContrast: true,
      );
      expect(
        WeftContrast.ratio(
          high.colorScheme.onSurface,
          high.colorScheme.surface,
        ),
        greaterThan(
          WeftContrast.ratio(
            plain.colorScheme.onSurface,
            plain.colorScheme.surface,
          ),
        ),
      );
    });

    test('high contrast promotes the hairline divider to a real border', () {
      final high = WeftTheme.build(highContrast: true);
      final palette = high.extension<WeftPalette>()!;
      expect(palette.divider, palette.border);
      expect(
        WeftContrast.ratio(palette.divider, high.colorScheme.surface),
        greaterThanOrEqualTo(WeftContrast.uiComponent),
      );
    });

    test('reduce motion collapses every duration to zero', () {
      final motion = WeftTheme.build(
        reduceMotion: true,
      ).extension<WeftMotionTokens>()!;
      expect(motion.reduced, isTrue);
      expect([
        motion.instant,
        motion.fast,
        motion.normal,
        motion.slow,
        motion.stagger,
      ], everyElement(Duration.zero));
    });

    test('the default theme animates', () {
      final motion = WeftTheme.build().extension<WeftMotionTokens>()!;
      expect(motion.reduced, isFalse);
      expect(motion.normal, WeftMotion.normal);
    });

    test('reduce motion takes the sparkle and the page transition with it', () {
      final still = WeftTheme.build(reduceMotion: true);
      expect(still.splashFactory, NoSplash.splashFactory);
      expect(
        still.pageTransitionsTheme,
        isNot(WeftTheme.build().pageTransitionsTheme),
      );
    });
  });
}

/// Every theme the app can actually be in. A token that passes in one and fails
/// in another is still a failure — AMOLED's true black and Material's
/// high-contrast tone mapping move the surfaces furthest.
final _variants = <({String name, ThemeData Function() build})>[
  (name: 'light', build: () => WeftTheme.build(brightness: Brightness.light)),
  (name: 'dark', build: () => WeftTheme.build(brightness: Brightness.dark)),
  (
    name: 'amoled',
    build: () => WeftTheme.build(brightness: Brightness.dark, amoled: true),
  ),
  (
    name: 'light high-contrast',
    build: () =>
        WeftTheme.build(brightness: Brightness.light, highContrast: true),
  ),
  (
    name: 'dark high-contrast',
    build: () =>
        WeftTheme.build(brightness: Brightness.dark, highContrast: true),
  ),
  (
    name: 'amoled high-contrast',
    build: () => WeftTheme.build(
      brightness: Brightness.dark,
      amoled: true,
      highContrast: true,
    ),
  ),
  // A seed a long way from the default indigo, because "our violet passes" is
  // not the same claim as "the derivation passes".
  (
    name: 'ember seed',
    build: () => WeftTheme.build(
      brightness: Brightness.light,
      seed: const Color(0xFFE8590C),
    ),
  ),
];

typedef _Pair = ({
  String name,
  Color foreground,
  Color background,
  double minRatio,
});

/// The pairs the app actually paints, named for what breaks when one fails.
List<_Pair> _pairsFor(ColorScheme scheme, WeftPalette palette) {
  const body = WeftContrast.bodyText;
  const ui = WeftContrast.uiComponent;

  return [
    (
      name: 'own bubble text',
      foreground: palette.ownBubbleText,
      background: palette.ownBubble,
      minRatio: body,
    ),
    (
      name: 'peer bubble text',
      foreground: palette.peerBubbleText,
      background: palette.peerBubble,
      minRatio: body,
    ),
    (
      name: 'body text on the page',
      foreground: scheme.onSurface,
      background: scheme.surface,
      minRatio: body,
    ),
    (
      name: 'secondary text on the page',
      foreground: scheme.onSurfaceVariant,
      background: scheme.surface,
      minRatio: body,
    ),
    (
      name: 'secondary text on a peer bubble',
      foreground: scheme.onSurfaceVariant,
      background: palette.peerBubble,
      minRatio: body,
    ),
    (
      name: 'text on the rail',
      foreground: scheme.onSurface,
      background: palette.railBackground,
      minRatio: body,
    ),
    (
      name: 'text on a selected rail item',
      foreground: scheme.onPrimaryContainer,
      background: palette.railSelected,
      minRatio: body,
    ),
    (
      name: 'unread count on its badge',
      foreground: scheme.onPrimary,
      background: palette.unreadDot,
      minRatio: body,
    ),
    (
      name: 'rail unread count on its badge',
      foreground: scheme.onError,
      background: scheme.error,
      minRatio: body,
    ),
    (
      name: 'error text on the page',
      foreground: scheme.error,
      background: scheme.surface,
      minRatio: body,
    ),
    (
      name: 'merged accent as text',
      foreground: palette.mergedAccent,
      background: scheme.surface,
      minRatio: body,
    ),
    (
      name: 'merged accent on its own 16% pill',
      foreground: palette.mergedAccent,
      background: WeftContrast.flatten(
        palette.mergedAccent.withValues(alpha: 0.16),
        scheme.surface,
      ),
      minRatio: body,
    ),
    (
      name: 'presence/success as text',
      foreground: palette.online,
      background: scheme.surface,
      minRatio: body,
    ),
    (
      name: 'presence/success as text on a card',
      foreground: palette.online,
      background: scheme.surfaceContainerLow,
      minRatio: body,
    ),
    (
      name: 'accept glyph on the accept button',
      foreground: palette.onCallAccept,
      background: palette.callAccept,
      minRatio: ui,
    ),
    (
      name: 'decline glyph on the decline button',
      foreground: palette.onCallDecline,
      background: palette.callDecline,
      minRatio: ui,
    ),
    (
      name: 'pane and composer border',
      foreground: palette.border,
      background: scheme.surface,
      minRatio: ui,
    ),
    (
      name: 'border against a peer bubble',
      foreground: palette.border,
      background: palette.peerBubble,
      minRatio: ui,
    ),
    (
      name: 'focus ring on the page',
      foreground: palette.focusRing,
      background: scheme.surface,
      minRatio: ui,
    ),
    (
      name: 'focus ring on a field',
      foreground: palette.focusRing,
      background: scheme.surfaceContainerHigh,
      minRatio: ui,
    ),
    (
      name: 'focus ring on the rail',
      foreground: palette.focusRing,
      background: palette.railBackground,
      minRatio: ui,
    ),
    (
      name: 'focus ring on a card',
      foreground: palette.focusRing,
      background: scheme.surfaceContainerLow,
      minRatio: ui,
    ),
    (
      name: 'white caption over the scrim on a bright frame',
      foreground: const Color(0xFFFFFFFF),
      background: WeftContrast.flatten(palette.scrim, const Color(0xFFFFFFFF)),
      minRatio: body,
    ),
  ];
}
