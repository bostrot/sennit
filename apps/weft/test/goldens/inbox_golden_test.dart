import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/inbox/inbox_shell.dart';

import '../support/golden_harness.dart';

void main() {
  setUpAll(loadGoldenFonts);

  group('InboxShell goldens', () {
    testWidgets('dark, two-pane', (tester) async {
      await pumpWeft(tester, const InboxShell());
      await expectLater(
        find.byType(InboxShell),
        matchesGoldenFile('inbox_dark.png'),
      );
    });

    testWidgets('light, two-pane', (tester) async {
      await pumpWeft(tester, const InboxShell(), mode: WeftThemeMode.light);
      await expectLater(
        find.byType(InboxShell),
        matchesGoldenFile('inbox_light.png'),
      );
    });

    testWidgets('amoled with a custom accent', (tester) async {
      await pumpWeft(
        tester,
        const InboxShell(),
        mode: WeftThemeMode.amoled,
        seed: const Color(0xFF0CA678),
      );
      await expectLater(
        find.byType(InboxShell),
        matchesGoldenFile('inbox_amoled_teal.png'),
      );
    });

    testWidgets('narrow, single-pane', (tester) async {
      await pumpWeft(tester, const InboxShell(), size: const Size(430, 900));
      await expectLater(
        find.byType(InboxShell),
        matchesGoldenFile('inbox_narrow.png'),
      );
    });
  });
}
