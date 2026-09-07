import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

/// [WeftDraggableSheet]'s one job: the keyboard never covers the sheet.
///
/// Measured in pixels rather than by looking at the widget, because the bug it
/// exists for is entirely geometric — the field was built, laid out and painted
/// exactly as intended, three hundred logical pixels below the top of the
/// keyboard drawn over it.
void main() {
  const screen = Size(400, 800);

  /// The sheet on a bare surface, the way a modal bottom sheet gives it the
  /// whole screen. Not a `Scaffold`: that insets its own body for the keyboard,
  /// which is the thing under test being done for us.
  Widget harness({double initialSize = 0.6}) => MaterialApp(
    home: Material(
      child: WeftDraggableSheet(
        initialSize: initialSize,
        builder: (context, controller) => ListView(
          key: const Key('body'),
          controller: controller,
          children: [
            for (var i = 0; i < 20; i++) ListTile(title: Text('row $i')),
          ],
        ),
      ),
    ),
  );

  Future<void> pumpSheet(
    WidgetTester tester, {
    double initialSize = 0.6,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(initialSize: initialSize));
    await tester.pumpAndSettle();
  }

  Future<void> raiseKeyboard(WidgetTester tester, double height) async {
    tester.view.viewInsets = FakeViewPadding(bottom: height);
    await tester.pumpAndSettle();
  }

  Rect body(WidgetTester tester) =>
      tester.getRect(find.byKey(const Key('body')));

  testWidgets('with no keyboard the sheet is its plain fraction', (
    tester,
  ) async {
    await pumpSheet(tester);

    final rect = body(tester);
    expect(rect.bottom, screen.height);
    expect(rect.height, closeTo(screen.height * 0.6, 0.5));
  });

  testWidgets('the keyboard lifts the sheet without shrinking it', (
    tester,
  ) async {
    await pumpSheet(tester);
    final before = body(tester).height;

    await raiseKeyboard(tester, 300);

    final rect = body(tester);
    // The whole of it above the keys, which is the bug: the last row of a
    // sheet like this is a caption field and a Send button.
    expect(rect.bottom, screen.height - 300);
    // And the same size it was, rather than 60% of what the keyboard left.
    expect(rect.height, closeTo(before, 0.5));
  });

  testWidgets('the sheet returns to its old height when the keyboard goes', (
    tester,
  ) async {
    await pumpSheet(tester);
    final before = body(tester).height;

    await raiseKeyboard(tester, 300);
    await raiseKeyboard(tester, 0);

    final rect = body(tester);
    expect(rect.bottom, screen.height);
    expect(rect.height, closeTo(before, 0.5));
  });

  testWidgets('a keyboard with no room left fills what is left of the screen', (
    tester,
  ) async {
    await pumpSheet(tester);
    final before = body(tester).height;

    // 480 pixels of sheet cannot be kept in the 200 the keyboard leaves. The
    // sheet takes all of them and stops there — the one case where it does
    // come out shorter, and it must still not be drawn under the keys.
    await raiseKeyboard(tester, 600);

    final squeezed = body(tester);
    expect(squeezed.bottom, screen.height - 600);
    expect(squeezed.height, closeTo(200, 0.5));
    expect(tester.takeException(), isNull);

    // And the height it had to give up comes back with the screen, rather than
    // leaving the sheet permanently smaller than the user opened it.
    await raiseKeyboard(tester, 0);
    expect(body(tester).height, closeTo(before, 0.5));
  });
}
