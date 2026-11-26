@Tags(['preview'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/features/contact/contact_profile.dart';

import '../support/golden_harness.dart';

/// Renders the contact profile to disk, phone and desktop, light and dark,
/// right to left and at the largest text size, so a change to it can be looked
/// at before and after. Not a golden: nothing is compared.
///
/// `PREVIEW_OUT` names the folder; `PREVIEW_EXPAND=1` opens every group.
void main() {
  setUpAll(loadGoldenFonts);

  final out = Platform.environment['PREVIEW_OUT'] ?? 'build/preview/contact';
  final expand = Platform.environment['PREVIEW_EXPAND'] == '1';

  Future<void> shot(
    WidgetTester tester,
    String name, {
    required Size size,
    required WeftThemeMode mode,
    WeftSurface surface = WeftSurface.touch,
    WeftGoldenVariant variant = weftGoldenBaseline,
  }) async {
    await pumpWeft(
      tester,
      RepaintBoundary(
        child: ContactProfileScreen(chatId: 'merged:anna', onSearch: () {}),
      ),
      size: size,
      mode: mode,
      surface: surface,
      variant: variant,
      stores: WeftStores.inMemory(),
    );
    await tester.pumpAndSettle();
    if (expand) {
      final groups = find.byType(ExpansionTile).evaluate().length;
      for (var i = groups - 1; i >= 0; i--) {
        await tester.tap(find.byType(ExpansionTile).at(i), warnIfMissed: false);
        await tester.pumpAndSettle();
      }
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  const phone = Size(412, 2200);
  const desktop = Size(1280, 1700);
  for (final mode in [WeftThemeMode.light, WeftThemeMode.dark]) {
    testWidgets('phone ${mode.name}', (tester) async {
      await shot(tester, 'phone_${mode.name}', size: phone, mode: mode);
    });
    testWidgets('desktop ${mode.name}', (tester) async {
      await shot(
        tester,
        'desktop_${mode.name}',
        size: desktop,
        mode: mode,
        surface: WeftSurface.mac,
      );
    });
  }
  testWidgets('phone rtl', (tester) async {
    await shot(
      tester,
      'phone_rtl_light',
      size: phone,
      mode: WeftThemeMode.light,
      variant: weftAccessibilityVariants[0],
    );
  });
  testWidgets('phone large text', (tester) async {
    await shot(
      tester,
      'phone_large_text_dark',
      size: const Size(412, 1900),
      mode: WeftThemeMode.dark,
      variant: weftAccessibilityVariants[1],
    );
  });
}
