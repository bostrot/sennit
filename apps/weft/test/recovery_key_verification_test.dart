import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/features/auth/verification_screen.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'support/session_fakes.dart';

/// Verifying a new sign-in with the recovery key instead of another device.
///
/// The screen around this needs a live session, so what is pumped is the part
/// that decides anything: what reaches the key store, and what a wrong key
/// leaves behind.
void main() {
  final en = lookupAppL10n(const Locale('en'));

  Future<({FakeKeyBackup backup, List<String> calls})> pump(
    WidgetTester tester, {
    Object? restoreFailure,
  }) async {
    final backup = FakeKeyBackup(restoreFailure: restoreFailure);
    final calls = <String>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [keyBackupProvider.overrideWithValue(backup)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: Scaffold(
            body: RecoveryKeyVerification(
              onDone: () => calls.add('done'),
              onBack: () => calls.add('back'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (backup: backup, calls: calls);
  }

  testWidgets('the right key verifies, and only then offers to continue', (
    tester,
  ) async {
    final (:backup, :calls) = await pump(tester);

    await tester.enterText(find.byType(TextField), ' EsTx 4Kd9 7Fma ');
    await tester.tap(find.text(en.commonVerify));
    await tester.pumpAndSettle();

    expect(backup.restores, ['EsTx 4Kd9 7Fma']);
    expect(find.text(en.verifyDone), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(calls, isEmpty);

    await tester.tap(find.text(en.commonContinue));
    expect(calls, ['done']);
  });

  testWidgets('a wrong key says so and leaves the field where it was', (
    tester,
  ) async {
    final (:backup, :calls) = await pump(
      tester,
      restoreFailure: const KeyBackupException('Not the key.'),
    );

    await tester.enterText(find.byType(TextField), 'EsWrong');
    await tester.tap(find.text(en.commonVerify));
    await tester.pumpAndSettle();

    expect(find.text('Not the key.'), findsOneWidget);
    expect(find.text(en.verifyDone), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(backup.restores, isEmpty);
    expect(calls, isEmpty);
  });

  testWidgets('an empty field is not sent anywhere', (tester) async {
    final (:backup, calls: _) = await pump(tester);

    await tester.tap(find.text(en.commonVerify));
    await tester.pumpAndSettle();

    expect(backup.restores, isEmpty);
    expect(find.text(en.securityEnterKeyOrPassphrase), findsOneWidget);
  });

  testWidgets('going back returns to the other-device path', (tester) async {
    final (backup: _, :calls) = await pump(tester);

    await tester.tap(find.text(en.verifyWithAnotherDevice));
    expect(calls, ['back']);
  });
}
