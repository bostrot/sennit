import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/auto_reply_screen.dart';

import '../support/golden_harness.dart';

/// Goldens for the auto-reply list and its editor.
///
/// `auto_reply_screen_test.dart` pins the behaviour — what is saved, what stays
/// switched off, which failure gets which sentence — and none of that can see
/// the one thing this screen is actually judged on: whether the warning is
/// *read*. Every sentence in the box at the top is something a user would be
/// upset to discover afterwards, and an assertion that the words are somewhere
/// in the tree is equally true of a layout where they are grey, eight point,
/// and below the fold.
///
/// So the frames are claims about ink. The list frame is the warning in the
/// same red box the privacy gates use, above the rules rather than under them.
/// The editor frame is the prompt field with the sentence saying it is sent
/// verbatim, and the cooldown row that repeats the hourly ceiling — the two
/// places a redesign would quietly drop.
///
/// The variants are the Phase 04 set. The right-to-left words draw as
/// placeholder boxes for the reason `a11y_golden_test.dart` gives — the SDK's
/// Roboto has no Arabic coverage — and the claim there is about the
/// *arrangement*: switches that stayed on the physical right, chips that moved
/// to the trailing edge.
void main() {
  setUpAll(loadGoldenFonts);

  /// Phone-width, and tall enough to hold the whole list at 1.0× so that 2.0×
  /// has somewhere to fail rather than clipping at the same place every variant
  /// does.
  const listWindow = Size(620, 1180);
  const editorWindow = Size(620, 1400);

  WeftStores storesWithRules() {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    stores.settings
      ..setString(WeftSettings.llmBaseUrl, 'http://localhost:11434/v1')
      ..setString(WeftSettings.llmModel, 'llama3')
      ..setJson(
        WeftSettings.autoReplyRules,
        AutoReplyRule.listToJson(const [
          AutoReplyRule(
            id: 'holiday',
            name: 'Out of office',
            prompt: 'Say I am away until Monday and will read this then.',
            enabled: true,
          ),
          AutoReplyRule(
            id: 'work',
            name: 'Work hours only',
            prompt: 'Answer briefly and say I will call back this afternoon.',
            audience: LabelAudience('Work'),
            window: ReplyWindow(startMinute: 540, endMinute: 1020),
          ),
        ]),
      );
    return stores;
  }

  Future<void> expectGolden(
    WidgetTester tester,
    String name, {
    required Size size,
    WeftGoldenVariant variant = weftGoldenBaseline,
    Future<void> Function(WidgetTester tester)? open,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      // Keyed for the reason the accessibility goldens are: without it the
      // second `pumpWidget` reuses the first run's element, so the light image
      // would be taken against the dark run's scroll offset.
      await pumpWeft(
        tester,
        AutoReplyScreen(key: ValueKey('${variant.name}_$suffix')),
        size: size,
        mode: mode,
        variant: variant,
        stores: storesWithRules(),
      );
      if (open != null) await open(tester);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('auto_reply_${name}_${variant.name}_$suffix.png'),
      );

      // The second `pumpWidget` reuses the Navigator element, so a route this
      // iteration pushed is still on the stack when the next one starts.
      if (open != null) {
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.popUntil((route) => route.isFirst);
        await tester.pumpAndSettle();
      }
    }
  }

  testWidgets('the rule list, both themes', (tester) async {
    await expectGolden(tester, 'list', size: listWindow);
  });

  testWidgets('the editor, both themes', (tester) async {
    await expectGolden(
      tester,
      'editor',
      size: editorWindow,
      open: (tester) async {
        await tester.tap(find.byIcon(Icons.edit_outlined).first);
        await tester.pumpAndSettle();
      },
    );
  });

  group('the rule list, under the accessibility variants', () {
    for (final variant in weftAccessibilityVariants) {
      testWidgets(variant.name, (tester) async {
        await expectGolden(tester, 'list', size: listWindow, variant: variant);
      });
    }
  });
}
