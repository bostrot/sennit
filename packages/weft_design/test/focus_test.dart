import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

/// What `WeftFocusable` has to be true of, and it is three things at once.
///
/// The audit's CROSS-3 finding was not that controls were unlabelled — task 3
/// and task 4 fixed that — but that a labelled control is still unusable if Tab
/// cannot land on it, if landing on it shows nothing, or if landing on it does
/// nothing. Doing two of the three is the trap, so every test here pins one
/// leg and the group only means something together.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(),
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  /// The label of whatever [WeftFocusable] currently holds focus.
  String? focusedLabel() => FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<WeftFocusable>()
      ?.label;

  /// Whether anything on screen is painting a ring in [color].
  bool ringPainted(WidgetTester tester, Color color) =>
      tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)).any((box) {
        final decoration = box.decoration;
        return decoration is BoxDecoration &&
            decoration.border?.top.color == color;
      });

  testWidgets('Tab lands on it and Enter activates it', (tester) async {
    var taps = 0;
    await pump(
      tester,
      WeftFocusable(
        label: 'Anna Maven',
        onTap: () => taps++,
        child: const SizedBox(width: 200, height: 60),
      ),
    );

    // The whole failure in one line: before this widget existed the control
    // below was a `GestureDetector` under a `Semantics`, and this Tab went
    // nowhere at all.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focusedLabel(), 'Anna Maven');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);

    // Space is the other activation key every platform agrees on.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(taps, 2);
  });

  testWidgets('the ring appears for a keyboard and not for a pointer', (
    tester,
  ) async {
    await pump(
      tester,
      WeftFocusable(
        label: 'Anna Maven',
        onTap: () {},
        child: const SizedBox(width: 200, height: 60),
      ),
    );
    final ring = WeftTheme.build().extension<WeftPalette>()!.focusRing;

    expect(ringPainted(tester, ring), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ringPainted(tester, ring), isTrue);

    // Touching the screen puts the highlight mode back to `touch`. A phone
    // that grew a ring around every row the moment something took focus would
    // be the fix visibly making things worse.
    await tester.tap(find.byType(WeftFocusable));
    await tester.pump();
    expect(ringPainted(tester, ring), isFalse);
  });

  testWidgets('a control with nothing to do is not a tab stop', (tester) async {
    await pump(
      tester,
      const WeftFocusable(
        label: 'Photo, loading',
        button: false,
        child: SizedBox(width: 200, height: 60),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focusedLabel(), isNull);
  });

  testWidgets('onActivate is the keyboard and onTap stays the pointer', (
    tester,
  ) async {
    var activations = 0;
    await pump(
      tester,
      WeftFocusable(
        label: 'Anna Maven, on Telegram',
        button: false,
        excludeSemantics: false,
        onActivate: () => activations++,
        onLongPress: () => activations += 10,
        child: const SizedBox(width: 200, height: 60),
      ),
    );

    // A tap must not open the action sheet — that is the bubble's whole
    // reason for wanting the two separated.
    await tester.tap(find.byType(WeftFocusable));
    await tester.pump();
    expect(activations, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activations, 1);
  });

  testWidgets('a group keeps its children reachable', (tester) async {
    final handle = tester.ensureSemantics();
    var inner = 0;
    await pump(
      tester,
      WeftFocusable(
        label: 'Anna Maven, on Telegram',
        button: false,
        // The bubble's setting. Excluding here would silence the links and
        // mention pills inside it and take their focus nodes with them, which
        // is a worse bug than the one the group label fixes.
        excludeSemantics: false,
        onActivate: () {},
        child: WeftFocusable(
          label: 'Mention: Anna',
          onTap: () => inner++,
          child: const SizedBox(width: 80, height: 20),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focusedLabel(), 'Anna Maven, on Telegram');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focusedLabel(), 'Mention: Anna');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(inner, 1);
    handle.dispose();
  });

  testWidgets('the node says it is focusable, and says when it is focused', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      WeftFocusable(
        label: 'Anna Maven',
        onTap: () {},
        child: const SizedBox(width: 200, height: 60),
      ),
    );

    var data = tester
        .getSemantics(find.byType(WeftFocusable))
        .getSemanticsData();
    // Focusable-but-not-focused, which the engine spells as a tristate: `none`
    // is "this node is not a focus target at all".
    expect(data.flagsCollection.isFocused, Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.tap), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    data = tester.getSemantics(find.byType(WeftFocusable)).getSemanticsData();
    expect(data.flagsCollection.isFocused, Tristate.isTrue);
    // The label survived being wrapped in a detector — the whole reason the
    // annotation sits outside it rather than under its `MouseRegion`.
    expect(data.label, 'Anna Maven');
    handle.dispose();
  });
}
