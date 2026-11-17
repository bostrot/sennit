import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

/// The toolbar search field's clear button: a 13pt glyph at the end of a 24pt
/// field. It used to be hittable on the glyph alone and named in English
/// whatever the app's language; these hold the target and the name.
void main() {
  Widget field(
    TextEditingController controller, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
    String clearLabel = 'Suche löschen',
    List<String>? changes,
  }) => MaterialApp(
    theme: WeftTheme.build(brightness: brightness, surface: WeftSurface.mac),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: Center(
          child: MacSearchField(
            controller: controller,
            clearLabel: clearLabel,
            onChanged: changes?.add,
            width: 120,
            focusedWidth: 180,
          ),
        ),
      ),
    ),
  );

  Finder clearButton(String label) => find.bySemanticsLabel(label);

  testWidgets('shows no clear button while the field is empty', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(field(controller));

    expect(find.byIcon(Icons.cancel_rounded), findsNothing);
  });

  testWidgets('names the clear button with the label it is given', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final controller = TextEditingController(text: 'anna');
    addTearDown(controller.dispose);
    await tester.pumpWidget(field(controller));

    expect(clearButton('Suche löschen'), findsOneWidget);
    expect(find.bySemanticsLabel('Clear search'), findsNothing);
    expect(find.byTooltip('Suche löschen'), findsOneWidget);
    handle.dispose();
  });

  for (final focused in [false, true]) {
    testWidgets('the clear target is the full field height '
        '(${focused ? 'focused' : 'unfocused'})', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = TextEditingController(text: 'anna');
      addTearDown(controller.dispose);
      await tester.pumpWidget(field(controller));
      if (focused) {
        await tester.tap(find.byType(TextField));
        await tester.pumpAndSettle();
      }

      final target = tester.getRect(find.byType(WeftTapTarget));
      expect(target.height, MacMetrics.fieldHeight);
      expect(target.width, greaterThanOrEqualTo(MacMetrics.fieldHeight));
      // The node a screen reader and the UI walk measure, not just the box.
      final node = tester.getSemantics(clearButton('Suche löschen'));
      expect(node.rect.height, greaterThanOrEqualTo(MacMetrics.fieldHeight));
      expect(node.rect.width, greaterThanOrEqualTo(MacMetrics.fieldHeight));
      // The glyph is drawn as before.
      expect(tester.getSize(find.byIcon(Icons.cancel_rounded)).width, 13);
      handle.dispose();
    });
  }

  testWidgets('a click near the glyph, not on it, clears the field', (
    tester,
  ) async {
    final changes = <String>[];
    final controller = TextEditingController(text: 'anna');
    addTearDown(controller.dispose);
    await tester.pumpWidget(field(controller, changes: changes));

    // Inside the target, outside the 13pt glyph: this missed before.
    final target = tester.getRect(find.byType(WeftTapTarget));
    await tester.tapAt(target.topLeft + const Offset(2, 2));
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(changes, ['']);
    expect(find.byIcon(Icons.cancel_rounded), findsNothing);
  });

  testWidgets('focusing the field does not move what is inside it', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'anna');
    addTearDown(controller.dispose);
    await tester.pumpWidget(field(controller));
    // Measured from the field's own corner: the field widens on focus.
    Offset glyph() =>
        tester.getTopLeft(find.byIcon(Icons.search_rounded)) -
        tester.getTopLeft(find.byType(MacSearchField));
    final before = glyph();

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(glyph(), before);
  });

  for (final (brightness, scale) in [
    (Brightness.dark, 1.0),
    (Brightness.light, 2.0),
  ]) {
    testWidgets('lays out in $brightness at ${scale}x text', (tester) async {
      final controller = TextEditingController(text: 'a longer query');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        field(controller, brightness: brightness, textScale: scale),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(clearButton('Suche löschen'), findsOneWidget);
    });
  }
}
