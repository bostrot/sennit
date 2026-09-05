import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

/// The two halves of "does this machine have a pointer", and the punctuation
/// that follows from it.
///
/// [WeftSurface] answers *which layout*; `hasPointer` answers *what arrives*,
/// and the whole reason they are two questions is Windows and Linux, which
/// answer them differently. Nothing else in the package can assert that pair,
/// because every widget that used to ask went to `defaultTargetPlatform`
/// directly and was therefore untestable in the case it was written for.
void main() {
  group('the pointer capability', () {
    test('a Mac theme has one without being told', () {
      final tokens = WeftTheme.build(
        surface: WeftSurface.mac,
      ).extension<WeftSurfaceTokens>()!;
      expect(tokens.isMac, isTrue);
      expect(tokens.pointer, isTrue);
    });

    test('a touch theme does not', () {
      final tokens = WeftTheme.build().extension<WeftSurfaceTokens>()!;
      expect(tokens.isMac, isFalse);
      expect(tokens.pointer, isFalse);
    });

    test('Windows and Linux are the case the two questions come apart on', () {
      // The touch *layout* — the Mac window is macOS down to its 13pt type —
      // driven by a mouse with a right button. Both facts at once, which is
      // what a single `isDesktop` could not say.
      final tokens = WeftTheme.build(
        pointer: true,
      ).extension<WeftSurfaceTokens>()!;
      expect(tokens.surface, WeftSurface.touch);
      expect(tokens.pointer, isTrue);
    });

    testWidgets('a widget reads both off the theme, never off the platform', (
      tester,
    ) async {
      late bool desktop;
      late bool pointer;
      await tester.pumpWidget(
        MaterialApp(
          theme: WeftTheme.build(pointer: true),
          home: Builder(
            builder: (context) {
              desktop = context.isDesktop;
              pointer = context.hasPointer;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(desktop, isFalse, reason: 'the layout question');
      expect(pointer, isTrue, reason: 'the input question');
    });
  });

  group('WeftSelectionLine', () {
    /// Drags a mouse across the whole of [child] and returns what was selected.
    Future<String?> selectAll(WidgetTester tester, Widget child) async {
      SelectedContent? content;
      await tester.pumpWidget(
        MaterialApp(
          theme: WeftTheme.build(),
          home: Scaffold(
            body: SelectionArea(
              onSelectionChanged: (value) => content = value,
              child: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        const Offset(1, 1),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      for (var step = 1; step <= 4; step++) {
        await gesture.moveTo(Offset(200.0 * step, 150.0 * step));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      return content?.plainText;
    }

    testWidgets('two plain children run together; two wrapped ones do not', (
      tester,
    ) async {
      // The bug this exists for, stated as the pair that shows it.
      expect(
        await selectAll(
          tester,
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text('Hello there'), Text('See you at six')],
          ),
        ),
        'Hello thereSee you at six',
      );

      expect(
        await selectAll(
          tester,
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WeftSelectionLine(child: Text('Hello there')),
              WeftSelectionLine(child: Text('See you at six')),
            ],
          ),
        ),
        'Hello there\nSee you at six\n',
      );
    });

    testWidgets('nesting does not double the break', (tester) async {
      // A message wraps its blocks and each block wraps itself, so the outer
      // one meets text that already ends in a newline.
      expect(
        await selectAll(
          tester,
          const WeftSelectionLine(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WeftSelectionLine(child: Text('one')),
                WeftSelectionLine(child: Text('two')),
              ],
            ),
          ),
        ),
        'one\ntwo\n',
      );
    });

    testWidgets('outside a SelectionArea it is not in the way', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: WeftTheme.build(),
          home: const Scaffold(
            body: WeftSelectionLine(child: Text('Hello there')),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Hello there'), findsOneWidget);
      expect(find.byType(SelectionContainer), findsNothing);
    });
  });
}
