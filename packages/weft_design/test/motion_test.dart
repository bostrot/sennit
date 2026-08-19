import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// `MediaQuery.disableAnimations`, end to end.
///
/// The theme carries the answer (see `contrast_test.dart`); this checks that a
/// component actually reads it, because a token nobody consults is a setting
/// nobody honours. The rail is the test subject because its staggered entry is
/// the app's most conspicuous movement — eight items fading and sliding in one
/// after another — and so the first thing a motion-sensitive user would report.
void main() {
  Future<void> pumpRail(WidgetTester tester, {required bool reduced}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(reduceMotion: reduced),
        home: Scaffold(
          body: NetworkRail(
            networks: const [
              ChatNetwork.whatsapp,
              ChatNetwork.telegram,
              ChatNetwork.signal,
            ],
            selected: const {},
            onToggle: (_) {},
            onShowAll: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('the rail marches in, then simply appears when asked to', (
    tester,
  ) async {
    // Frames-to-settle rather than an opacity at frame N: it is the same
    // measurement a user makes — how long the thing moves for — and it does not
    // depend on which of the rail's several transitions happens to be found
    // first.
    await pumpRail(tester, reduced: false);
    final animated = await tester.pumpAndSettle();

    await pumpRail(tester, reduced: true);
    final still = await tester.pumpAndSettle();

    expect(
      still,
      lessThan(animated),
      reason:
          'reduced motion settled in $still frames and full motion in '
          '$animated — the rail is not reading the setting',
    );

    // And what is on screen at the end is the arrived state either way: the
    // entry is skipped, not cancelled halfway.
    // Scoped to the rail items' own transitions: each `Tooltip` carries a
    // `FadeTransition` of its own that sits at 0 because no tooltip is showing,
    // and a bare `byType` would fail on those.
    final opacities = tester
        .widgetList<FadeTransition>(
          find.ancestor(
            of: find.byType(NetworkGlyph),
            matching: find.byType(FadeTransition),
          ),
        )
        .map((f) => f.opacity.value);
    expect(opacities, isNotEmpty);
    expect(opacities, everyElement(1.0));
  });

  testWidgets('context.motion reports what the theme was built with', (
    tester,
  ) async {
    late WeftMotionTokens motion;
    await tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(reduceMotion: true),
        home: Builder(
          builder: (context) {
            motion = context.motion;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(motion.reduced, isTrue);
    expect(motion.normal, Duration.zero);
    // Curves are untouched: a zero-length animation never samples one, and
    // keeping them means nothing downstream has to special-case a null curve.
    expect(motion.standard, WeftMotion.standard);
  });

  testWidgets('a theme with no motion extension still animates', (
    tester,
  ) async {
    late WeftMotionTokens motion;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(),
        home: Builder(
          builder: (context) {
            motion = context.motion;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(motion.reduced, isFalse);
    expect(motion.fast, WeftMotion.fast);
  });
}
