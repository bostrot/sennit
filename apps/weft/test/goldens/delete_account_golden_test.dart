import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/delete_account_screen.dart';

import '../support/golden_harness.dart';

/// Goldens for the account deletion screen.
///
/// `delete_account_test.dart` pins the behaviour — the order, the prompts, the
/// lock on the button. What only an image can pin is that the screen reads as
/// what it is: every consequence on screen before the field, the button in the
/// error colour and visibly disabled until the username is typed. A delete
/// button drawn in the ordinary filled style, or a list long enough at 2.0×
/// to push the field off the bottom of a phone, would pass every assertion.
void main() {
  setUpAll(loadGoldenFonts);

  const phone = Size(430, 932);

  Future<void> expectGolden(
    WidgetTester tester,
    String name, {
    WeftGoldenVariant variant = weftGoldenBaseline,
    bool typed = false,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      await pumpWeft(
        tester,
        KeyedSubtree(key: ValueKey(suffix), child: const DeleteAccountScreen()),
        size: phone,
        mode: mode,
        variant: variant,
        stores: stores,
        ownUserId: '@alice:matrix.example.org',
      );
      if (typed) {
        await tester.enterText(find.byType(TextField), 'alice');
        await tester.pumpAndSettle();
      }
      await expectLater(
        find.byType(DeleteAccountScreen),
        matchesGoldenFile('delete_account_${name}_$suffix.png'),
      );
    }
  }

  testWidgets('before the username is typed', (tester) async {
    await expectGolden(tester, 'locked');
  });

  testWidgets('with the username typed', (tester) async {
    await expectGolden(tester, 'unlocked', typed: true);
  });

  testWidgets('right to left', (tester) async {
    await expectGolden(tester, 'rtl', variant: weftAccessibilityVariants.first);
  });
}
