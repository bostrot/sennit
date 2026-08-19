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

  group('the unread badge grows with the count inside it', () {
    // The mirror image of the group above, and the reason both are worth
    // pinning: a *mark* sized from its box must not scale, and a *number* must,
    // along with the pill around it. The two badges were the same defect twice
    // — `height: 20` on the chat row, `height: 18` on the rail — which at 2.0×
    // put 22dp and 20dp of digits in boxes that had not moved and sliced the
    // tops and bottoms off both. That is SCALE-4 and SCALE-5, and it was found
    // by looking at `a11y_inbox_large_text_dark.png`.
    for (final scale in [0.85, 1.0, 1.3, 2.0]) {
      for (final count in [3, 27, 128]) {
        testWidgets('$count at ${scale}x', (tester) async {
          await pump(
            tester,
            WeftUnreadBadge(
              count: count,
              color: const Color(0xFFB9A3FF),
              ink: const Color(0xFF1B1140),
            ),
            scale,
          );

          final pill = tester.getRect(find.byType(WeftUnreadBadge));
          final digits = tester.getRect(find.text(count > 99 ? '99+' : '$count'));

          expect(
            pill.inflate(0.5).contains(digits.topLeft) &&
                pill.inflate(0.5).contains(digits.bottomRight),
            isTrue,
            reason: 'digits $digits escaped the badge $pill at ${scale}x',
          );
          // Still a pill rather than a squashed oval: the minimum is square, so
          // a one-digit count is a circle at every scale.
          expect(pill.width, greaterThanOrEqualTo(pill.height - 0.5));
        });
      }
    }

    testWidgets('and is pixel-identical at 1.0× to the box it replaced', (
      tester,
    ) async {
      // The scaler is applied at 1.0× too, so this asserts the arithmetic is
      // the identity there — which is what keeps every inbox golden taken
      // before this widget existed unmoved. Measured against the recipe the two
      // call sites carried, rebuilt here, rather than against numbers typed out
      // of the old source: the width depends on the font, so a literal would be
      // a different assertion on a machine with a different Roboto.
      Widget legacy({
        required double extent,
        required double fontSize,
        required double horizontal,
        Color? border,
      }) => Container(
        constraints: BoxConstraints(minWidth: extent),
        height: extent,
        padding: EdgeInsets.symmetric(horizontal: horizontal),
        decoration: BoxDecoration(
          borderRadius: WeftRadius.pill,
          border: border == null ? null : Border.all(color: border, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(
          '27',
          style: TextStyle(fontSize: fontSize, height: 1),
        ),
      );

      for (final (badge, old) in [
        (
          const WeftUnreadBadge(
            count: 27,
            color: Color(0xFFB9A3FF),
            ink: Color(0xFF1B1140),
          ),
          legacy(extent: 20, fontSize: 11, horizontal: 6),
        ),
        (
          const WeftUnreadBadge(
            count: 27,
            color: Color(0xFFB9A3FF),
            ink: Color(0xFF1B1140),
            extent: 18,
            fontSize: 10,
            horizontalPadding: 5,
            borderColor: Color(0xFF101014),
          ),
          legacy(
            extent: 18,
            fontSize: 10,
            horizontal: 5,
            border: const Color(0xFF101014),
          ),
        ),
      ]) {
        // A `Row` because that is what both call sites are underneath, and it
        // is what leaves the badge's width unbounded — the constraint the old
        // `Container(alignment:)` silently depended on.
        await pump(tester, Row(children: [badge]), 1);
        final now = tester.getSize(find.byType(WeftUnreadBadge));
        await pump(tester, Row(children: [old]), 1);
        expect(now, tester.getSize(find.byType(Container).last));
      }
    });
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
