import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

/// [WeftTapTarget] on its own, because the four things it has to do at once are
/// each easy to lose and only one of them is visible.
///
/// The touch-target register is fourteen controls between 22dp and 44dp, and
/// the temptation at every one of them is to make the number a test reads go up
/// without making the control any easier to hit. So these assert the box, the
/// paint, the *hit* and the semantics rect separately — a version that grew the
/// layout and left the hit test on the old bounds would pass a guideline sweep
/// and still miss a thumb.
void main() {
  /// A 20dp square that records the taps it receives.
  Widget target(List<String> taps, {Size? minSize, double side = 20}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Semantics(
            button: true,
            label: 'small',
            excludeSemantics: true,
            onTap: () => taps.add('semantics'),
            child: WeftTapTarget(
              minSize: minSize ?? const Size.square(kWeftMinTapTarget),
              child: GestureDetector(
                onTap: () => taps.add('tap'),
                child: Container(
                  key: const ValueKey('child'),
                  width: side,
                  height: side,
                  color: const Color(0xFF000000),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('grows the box to the minimum and leaves the child alone', (
    tester,
  ) async {
    await tester.pumpWidget(target([]));

    expect(tester.getSize(find.byType(WeftTapTarget)), const Size(48, 48));
    // The whole point: what is painted does not change, so a chip designed at
    // 28dp still reads as a 28dp chip.
    expect(
      tester.getSize(find.byKey(const ValueKey('child'))),
      const Size(20, 20),
    );
  });

  testWidgets('centres the child in the grown box', (tester) async {
    await tester.pumpWidget(target([]));

    expect(
      tester.getCenter(find.byKey(const ValueKey('child'))),
      tester.getCenter(find.byType(WeftTapTarget)),
    );
  });

  testWidgets('a tap in the padding reaches the child', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(target(taps));

    // 4dp inside the corner of the grown box, which is 10dp clear of anything
    // the child paints. Padding that looks generous and does not take the tap
    // is the failure mode that makes an over-large button feel broken.
    await tester.tapAt(
      tester.getTopLeft(find.byType(WeftTapTarget)) + const Offset(4, 4),
    );
    await tester.pump();

    expect(taps, ['tap']);
  });

  testWidgets('a child already big enough is not padded', (tester) async {
    await tester.pumpWidget(target([], side: 60));

    expect(tester.getSize(find.byType(WeftTapTarget)), const Size(60, 60));
  });

  testWidgets('the minimum can be asked for on one axis only', (tester) async {
    await tester.pumpWidget(target([], minSize: const Size(48, 0)));

    // For a control in a running line, where a 48dp height would push the line
    // apart and the width is what is actually short.
    expect(tester.getSize(find.byType(WeftTapTarget)), const Size(48, 20));
  });

  testWidgets('the semantics node is the grown box, not the child', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(target([]));

    // Which is what [MinimumTapTargetGuideline] measures, and what a screen
    // reader's touch exploration lands in. A tap target added *outside* the
    // annotation would leave this node 20dp square.
    final node = tester.getSemantics(find.byType(WeftTapTarget));
    expect(node.rect.size, const Size(48, 48));
    handle.dispose();
  });

  testWidgets('intrinsics report the minimum', (tester) async {
    // An `IntrinsicWidth` above a padded control would otherwise size to the
    // child and squeeze the padding back out again.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: IntrinsicWidth(
            child: WeftTapTarget(
              child: Container(width: 20, height: 20, color: Colors.black),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(WeftTapTarget)).width, 48);
  });
}
