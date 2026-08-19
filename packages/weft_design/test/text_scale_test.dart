import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// Dynamic type from 0.85× to 2.0×, against the two components that sized
/// their text from their own box.
///
/// [WeftAvatar]'s initials and [NetworkGlyph]'s lettermark are marks rather
/// than reading material: their `fontSize` is derived from the circle they sit
/// in, so a scaler that grows the glyph without growing the circle pushes the
/// letters straight out of it. Both opt out of scaling; these tests are what
/// stops someone deleting the opt-out as dead weight.
void main() {
  Future<void> pump(WidgetTester tester, Widget child, double scale) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );
  }

  group('a mark does not grow out of the box that sizes it', () {
    for (final scale in [0.85, 1.0, 1.3, 2.0]) {
      testWidgets('avatar initials at ${scale}x', (tester) async {
        await pump(
          tester,
          const WeftAvatar(label: 'Anna Maven', size: 46),
          scale,
        );

        final avatar = tester.getRect(find.byType(WeftAvatar));
        final text = tester.getRect(find.text('AM'));

        expect(avatar.size, const Size(46, 46));
        expect(
          avatar.inflate(0.5).contains(text.topLeft) &&
              avatar.inflate(0.5).contains(text.bottomRight),
          isTrue,
          reason: 'initials $text escaped the avatar $avatar at ${scale}x',
        );
      });

      testWidgets('network lettermark at ${scale}x', (tester) async {
        // SMS has no Simple Icons glyph, so it draws the two-character
        // lettermark — the widest of the fallbacks and the first to overflow.
        await pump(
          tester,
          const NetworkGlyph(network: ChatNetwork.sms, size: 36),
          scale,
        );

        final chip = tester.getRect(find.byType(NetworkGlyph));
        final text = tester.getRect(find.text('Sm'));

        expect(chip.size, const Size(36, 36));
        expect(
          chip.inflate(0.5).contains(text.topLeft) &&
              chip.inflate(0.5).contains(text.bottomRight),
          isTrue,
          reason: 'lettermark $text escaped the chip $chip at ${scale}x',
        );
      });
    }
  });

  testWidgets('real text still scales — only the marks opt out', (
    tester,
  ) async {
    await pump(
      tester,
      const NetworkGlyph(network: ChatNetwork.sms, size: 36, showLabel: true),
      1,
    );
    final small = tester.getRect(find.text('SMS')).width;

    await pump(
      tester,
      const NetworkGlyph(network: ChatNetwork.sms, size: 36, showLabel: true),
      2,
    );
    final large = tester.getRect(find.text('SMS')).width;

    expect(large, greaterThan(small * 1.5));
  });

  testWidgets('a focused field wears the focus ring, in both themes', (
    tester,
  ) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final theme = WeftTheme.build(brightness: brightness);
      final palette = theme.extension<WeftPalette>()!;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(body: Center(child: TextField())),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      final border = theme.inputDecorationTheme.focusedBorder;
      expect(border, isA<OutlineInputBorder>());
      expect(border!.borderSide.color, palette.focusRing);
      expect(border.borderSide.width, 2);
      expect(
        WeftContrast.ratio(palette.focusRing, theme.colorScheme.surface),
        greaterThanOrEqualTo(WeftContrast.uiComponent),
      );
    }
  });
}
