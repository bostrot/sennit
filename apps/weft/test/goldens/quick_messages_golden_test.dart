import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/features/chat/quick_message_sheet.dart';
import 'package:weft/features/settings/quick_messages_screen.dart';
import 'package:weft/services/ai/quick_messages.dart';

import '../support/golden_harness.dart';

/// Goldens for the quick message list in settings and the sheet the attach
/// menu opens.
///
/// The settings frame is a claim about the privacy box: picking a quick
/// message sends part of a chat to the user's model, and the box saying so
/// sits above the list rather than under it. The sheet frame is the subtitle
/// that says a draft is checked before sending — the promise the feature is
/// built on — and the emoji column that keeps the titles aligned.
void main() {
  setUpAll(loadGoldenFonts);

  const window = Size(620, 1100);

  WeftStores stores() {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    return stores;
  }

  Future<void> both(
    WidgetTester tester,
    String name,
    Widget Function(Key key) build, {
    Future<void> Function(WidgetTester tester)? open,
    WeftGoldenVariant variant = weftGoldenBaseline,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      await pumpWeft(
        tester,
        build(ValueKey('${variant.name}_$suffix')),
        size: window,
        mode: mode,
        variant: variant,
        stores: stores(),
      );
      if (open != null) await open(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('quick_messages_${name}_${variant.name}_$suffix.png'),
      );
      if (open != null) {
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.popUntil((route) => route.isFirst);
        await tester.pumpAndSettle();
      }
    }
  }

  testWidgets('the settings list, both themes', (tester) async {
    await both(tester, 'list', (key) => QuickMessagesScreen(key: key));
  });

  testWidgets('the sheet, both themes', (tester) async {
    await both(
      tester,
      'sheet',
      (key) => Scaffold(
        key: key,
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showQuickMessageSheet(
                context,
                QuickMessage.defaults,
                onEdit: () {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      open: (tester) async {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      },
    );
  });

  group('the settings list, under the accessibility variants', () {
    for (final variant in weftAccessibilityVariants) {
      testWidgets(variant.name, (tester) async {
        await both(
          tester,
          'list',
          (key) => QuickMessagesScreen(key: key),
          variant: variant,
        );
      });
    }
  });
}
