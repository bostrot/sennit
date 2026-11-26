import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/contact/contact_profile.dart';
import 'package:weft_design/weft_design.dart';

import '../support/golden_harness.dart';

/// Goldens for the contact profile: the name, the four quick actions, what
/// is shared and where the person is, then the settings folded into named
/// groups and archiving apart at the bottom.
///
/// `contact_profile_test.dart` pins that every row is still reachable; these
/// pin that the screen opens short — on a phone, in a window, right to left
/// and at twice the text size — and that a group opened shows its rows.
void main() {
  setUpAll(loadGoldenFonts);

  const phone = Size(412, 1000);
  const window = Size(1100, 900);

  Future<void> expectGolden(
    WidgetTester tester,
    String name, {
    Size size = phone,
    WeftSurface surface = WeftSurface.touch,
    WeftGoldenVariant variant = weftGoldenBaseline,
    bool open = false,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      await pumpWeft(
        tester,
        ContactProfileScreen(
          key: ValueKey(suffix),
          chatId: 'merged:anna',
          onSearch: () {},
        ),
        size: size,
        mode: mode,
        surface: surface,
        variant: variant,
        stores: WeftStores.inMemory(),
      );
      if (open) {
        await tester.tap(find.text('Chat settings'));
        await tester.pumpAndSettle();
      }
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('contact_profile_${name}_$suffix.png'),
      );
    }
  }

  testWidgets('phone', (tester) async {
    await expectGolden(tester, 'phone');
  });

  testWidgets('phone with chat settings open', (tester) async {
    await expectGolden(tester, 'phone_open', open: true);
  });

  testWidgets('desktop window', (tester) async {
    await expectGolden(
      tester,
      'desktop',
      size: window,
      surface: WeftSurface.mac,
    );
  });

  testWidgets('right to left', (tester) async {
    await expectGolden(
      tester,
      'rtl',
      variant: const WeftGoldenVariant(name: 'rtl', locale: Locale('ar')),
    );
  });

  testWidgets('large text', (tester) async {
    await expectGolden(
      tester,
      'large_text',
      size: const Size(412, 1600),
      variant: const WeftGoldenVariant(name: 'large_text', textScale: 2.0),
    );
  });
}
