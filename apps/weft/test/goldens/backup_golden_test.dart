import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/settings/backup_screen.dart';

import '../support/backup_fakes.dart';
import '../support/golden_harness.dart';

/// Goldens for the backup screen and its two blunt dialogs.
///
/// `backup_screen_test.dart` already pins the behaviour — a mismatch blocks,
/// cancel cancels, each typed failure gets its own sentence — and none of that
/// can see what the screen is judged on. Two of the frames here are claims
/// about ink rather than about strings:
///
/// * **The passphrase dialog.** The whole feature rests on one sentence being
///   read before a button is pressed, and that sentence is in the same red box
///   the privacy gates use. An assertion that the words are on screen is true
///   of a layout where they are grey, below the fields, and off the bottom of a
///   phone.
/// * **The replace confirmation.** It is the only control in Braid that deletes
///   a user's messages, and it has to look like it. A destructive button that
///   renders in the ordinary filled style is the failure.
///
/// The variants are the Phase 04 set, applied to the screen rather than to the
/// dialogs: the screen is four paragraphs, a switch whose subtitle wraps and
/// three buttons, which is where 2.0× and Arabic have something to break. The
/// right-to-left words draw as placeholder boxes for the reason
/// `a11y_golden_test.dart` gives — the SDK's Roboto has no Arabic coverage —
/// and the claim is about the *arrangement*: a switch that stayed on the
/// physical right, buttons that moved to the trailing edge.
void main() {
  setUpAll(loadGoldenFonts);

  /// Phone-width, and tall enough to hold the whole list at 1.0× so that 2.0×
  /// has somewhere to fail rather than simply clipping at the same place every
  /// variant does.
  const screenWindow = Size(620, 1180);
  const dialogWindow = Size(620, 900);

  Future<void> expectGolden(
    WidgetTester tester,
    String name, {
    required Size size,
    WeftGoldenVariant variant = weftGoldenBaseline,
    Future<void> Function(WidgetTester tester)? open,

    /// A fresh service per theme, because the fakes record what they were
    /// asked and a shared one would carry the dark run's state into the light
    /// image.
    FakeBackupService Function()? service,
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
        BackupScreen(key: ValueKey('${variant.name}_$suffix')),
        size: size,
        mode: mode,
        variant: variant,
        backupService: service?.call() ?? FakeBackupService(),
      );
      if (open != null) await open(tester);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('backup_${name}_${variant.name}_$suffix.png'),
      );

      // The second `pumpWidget` reuses the Navigator element, so any dialog
      // this iteration opened is still on the stack when the next one starts —
      // which made the light image of a two-step flow a picture of step four.
      // Popping back to the screen is what makes the two runs independent.
      if (open != null) {
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.popUntil((route) => route.isFirst);
        await tester.pumpAndSettle();
      }
    }
  }

  testWidgets('the screen, both themes', (tester) async {
    // What the feature looks like before anything has been decided: the
    // estimate under the media switch, the two actions, and the paragraph
    // saying what a backup deliberately leaves out. That last section is the
    // one most likely to be quietly dropped in a redesign, which is why it is
    // in the frame rather than only in an assertion.
    await expectGolden(tester, 'screen', size: screenWindow);
  });

  testWidgets('the passphrase dialog, both themes', (tester) async {
    await expectGolden(
      tester,
      'passphrase',
      size: dialogWindow,
      open: (tester) async {
        await tester.tap(find.text('Create backup'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('the replace confirmation, both themes', (tester) async {
    await expectGolden(
      tester,
      'replace',
      // The full screen height rather than [dialogWindow]: Restore sits below
      // the export section, and at the shorter size the button this flow
      // starts from is off the bottom and the tap lands on nothing.
      size: screenWindow,
      service: () => FakeBackupService(pickResult: fakePickedArchive()),
      open: (tester) async {
        // Scrolled into view first: the restore button sits below the export
        // section, and a tap on an off-screen widget is silently a tap on
        // nothing.
        await tester.ensureVisible(find.text('Choose a file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose a file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'the passphrase');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Replace what is here'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Restore'));
        await tester.pumpAndSettle();
      },
    );
  });

  group('the screen, under the accessibility variants', () {
    for (final variant in weftAccessibilityVariants) {
      testWidgets(variant.name, (tester) async {
        await expectGolden(
          tester,
          'screen',
          size: screenWindow,
          variant: variant,
        );
      });
    }
  });
}
