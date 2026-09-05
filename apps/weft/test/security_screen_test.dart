import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/features/settings/security_screen.dart';
import 'package:weft/features/settings/settings_section.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'support/session_fakes.dart';

/// The recovery-key flows, which are the only ones in Weft that cannot be
/// repeated. A key is shown once; a backup replaced is a backup gone. So the
/// assertions here are mostly about what does *not* happen — the setup that
/// stops at a cancelled prompt, the replace that waits for a confirmation, the
/// wrong key that leaves the user exactly where they were.
void main() {
  final en = lookupAppL10n(const Locale('en'));
  final thisDevice = const WeftDevice(
    deviceId: 'THISONE',
    displayName: 'Weft on Pixel',
    isCurrent: true,
    trust: DeviceTrust.verified,
  );
  final laptop = const WeftDevice(
    deviceId: 'LAPTOP',
    displayName: 'Weft on laptop',
    trust: DeviceTrust.unverified,
  );

  Future<({FakeKeyBackup backup, FakeDeviceManager devices})> pump(
    WidgetTester tester, {
    KeyBackupStatus status = KeyBackupStatus.none,
    List<WeftDevice>? devices,
    FakeKeyBackup? backup,
    Object? deviceFailure,
  }) async {
    final fakeBackup = backup ?? FakeKeyBackup(status0: status);
    final fakeDevices = FakeDeviceManager(devices ?? [thisDevice])
      ..failure = deviceFailure;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyBackupProvider.overrideWithValue(fakeBackup),
          deviceManagerProvider.overrideWithValue(fakeDevices),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: const SecurityScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (backup: fakeBackup, devices: fakeDevices);
  }

  group('status', () {
    testWidgets('one device and no backup says the history is unrecoverable', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text(backupLabel(en, KeyBackupState.absent)), findsOneWidget);
      expect(
        find.textContaining('every encrypted message you have is gone'),
        findsOneWidget,
      );
      // The one case that has to arrive before the phone is dropped, so it is
      // in the red box rather than the quiet one.
      expect(find.byType(PrivacyNotice), findsOneWidget);
      expect(find.text('Set up a recovery key'), findsOneWidget);
    });

    testWidgets('another signed-in device softens it, and is not red', (
      tester,
    ) async {
      await pump(tester, devices: [thisDevice, laptop]);

      expect(
        find.textContaining('another device is signed in'),
        findsOneWidget,
      );
      expect(find.byType(PrivacyNotice), findsNothing);
    });

    testWidgets(
      'a healthy backup shows what is in it and warns about nothing',
      (tester) async {
        await pump(
          tester,
          status: const KeyBackupStatus(
            state: KeyBackupState.upToDate,
            crossSigningEnabled: true,
            version: '3',
            keyCount: 412,
          ),
        );

        expect(
          find.text(backupLabel(en, KeyBackupState.upToDate)),
          findsOneWidget,
        );
        expect(find.textContaining('412 keys'), findsOneWidget);
        expect(find.textContaining('version 3'), findsOneWidget);
        expect(find.textContaining('cross-signing on'), findsOneWidget);
        expect(find.byType(PrivacyNotice), findsNothing);
        // Nothing to set up, only the destructive option, and it reads as one.
        expect(find.text('Set up a recovery key'), findsNothing);
        expect(find.text('Replace the recovery key'), findsOneWidget);
      },
    );

    testWidgets('a locked backup asks for the key rather than a new one', (
      tester,
    ) async {
      // The distinction the state exists for: offering setup here would replace
      // the backup holding this account's history.
      await pump(
        tester,
        status: const KeyBackupStatus(
          state: KeyBackupState.locked,
          crossSigningEnabled: true,
          version: '3',
          keyCount: 412,
        ),
      );

      expect(find.text('Enter your recovery key'), findsOneWidget);
      expect(find.text('Set up a recovery key'), findsNothing);
    });

    testWidgets('a status that will not load says so, not "no backup"', (
      tester,
    ) async {
      await pump(
        tester,
        deviceFailure: StateError(
          'WeftMatrixSession.initialize() has not been called',
        ),
      );

      expect(find.textContaining('initialize()'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Set up a recovery key'), findsNothing);
    });
  });

  group('setting recovery up', () {
    testWidgets('shows the key once, then checks it was written down', (
      tester,
    ) async {
      final fakes = await pump(tester);

      await tester.tap(find.text('Set up a recovery key'));
      await tester.pumpAndSettle();

      // The passphrase is optional and empty means none, not "".
      expect(find.text('Add a passphrase?'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(fakes.backup.creations, [
        (passphrase: null, replaceExisting: false),
      ]);
      // Shown regrouped into blocks of four, which is the form it is read and
      // typed in.
      expect(find.text('EsAA BBCC DDEE FFGG'), findsOneWidget);
      expect(find.textContaining('cannot show it again'), findsOneWidget);

      await tester.tap(find.text('I have saved it'));
      await tester.pumpAndSettle();

      // A wrong key is caught here, which is the entire point of the step.
      await tester.enterText(find.byType(TextField), 'EsAA BBCC DDEE FFGH');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not the key that was just shown'), findsOne);
      expect(find.text('Confirm'), findsOneWidget, reason: 'still on the step');

      // Spacing is not part of the key, so a paste from anywhere is accepted.
      await tester.enterText(find.byType(TextField), 'esaabbccddeeffgg');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('not the key'),
        findsOneWidget,
        reason: 'base58 is case-sensitive',
      );

      await tester.enterText(find.byType(TextField), 'EsAABBCCDDEEFFGG');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(
        find.text(backupLabel(en, KeyBackupState.upToDate)),
        findsOneWidget,
      );
    });

    testWidgets('the passphrase typed is the passphrase used', (tester) async {
      final fakes = await pump(tester);

      await tester.tap(find.text('Set up a recovery key'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  hunter2 correct  ');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(fakes.backup.creations, [
        (passphrase: 'hunter2 correct', replaceExisting: false),
      ]);
    });

    testWidgets('backing out of the passphrase prompt sets nothing up', (
      tester,
    ) async {
      // It is the last step before keys are minted and uploaded; treating a
      // dismissal as "no passphrase, carry on" would set recovery up on a shrug.
      final fakes = await pump(tester);

      await tester.tap(find.text('Set up a recovery key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(fakes.backup.creations, isEmpty);
      expect(find.text('Set up a recovery key'), findsOneWidget);
    });

    testWidgets('a refusal from the server is shown in its own words', (
      tester,
    ) async {
      await pump(
        tester,
        backup: FakeKeyBackup(
          createFailure: const KeyBackupException(
            'Your homeserver refused to set up encryption: M_FORBIDDEN',
          ),
        ),
      );

      await tester.tap(find.text('Set up a recovery key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('M_FORBIDDEN'),
        ),
        findsOneWidget,
      );
    });
  });

  group('replacing', () {
    testWidgets('is confirmed first, and says what it costs', (tester) async {
      final fakes = await pump(
        tester,
        status: const KeyBackupStatus(
          state: KeyBackupState.upToDate,
          crossSigningEnabled: true,
          version: '3',
          keyCount: 412,
        ),
      );

      await tester.tap(find.text('Replace the recovery key'));
      await tester.pumpAndSettle();

      expect(find.text('Replace the recovery key?'), findsOneWidget);
      expect(find.textContaining('The old key stops working'), findsOneWidget);
      expect(fakes.backup.creations, isEmpty, reason: 'not until confirmed');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fakes.backup.creations, isEmpty);

      await tester.tap(find.text('Replace the recovery key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(fakes.backup.creations, [
        (passphrase: null, replaceExisting: true),
      ]);
    });
  });

  group('restoring', () {
    const locked = KeyBackupStatus(
      state: KeyBackupState.locked,
      crossSigningEnabled: true,
      version: '3',
      keyCount: 412,
    );

    testWidgets('a wrong key leaves the user where they were', (tester) async {
      final fakes = await pump(
        tester,
        backup: FakeKeyBackup(
          status0: locked,
          restoreFailure: const KeyBackupException(
            'That is not the recovery key or passphrase for this account.',
          ),
        ),
      );

      await tester.tap(find.text('Enter your recovery key'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'EsNOPE');
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(find.textContaining('not the recovery key'), findsOneWidget);
      // Still on the restore step with the attempt intact, so a mistyped
      // character can be fixed rather than retyped from scratch.
      expect(find.text('Restore'), findsOneWidget);
      expect(fakes.backup.restores, isEmpty);
    });

    testWidgets('an empty field is refused without a round trip', (
      tester,
    ) async {
      final fakes = await pump(tester, backup: FakeKeyBackup(status0: locked));

      await tester.tap(find.text('Enter your recovery key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Enter your recovery key or'), findsOneWidget);
      expect(fakes.backup.restores, isEmpty);
    });

    testWidgets('a key that works unlocks the account and reloads', (
      tester,
    ) async {
      final fakes = await pump(tester, backup: FakeKeyBackup(status0: locked));

      await tester.tap(find.text('Enter your recovery key'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  EsAABBCCDDEEFFGG  ');
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(fakes.backup.restores, ['EsAABBCCDDEEFFGG']);
      expect(
        find.text(backupLabel(en, KeyBackupState.upToDate)),
        findsOneWidget,
      );
    });

    testWidgets('cancelling goes back without restoring', (tester) async {
      final fakes = await pump(tester, backup: FakeKeyBackup(status0: locked));

      await tester.tap(find.text('Enter your recovery key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(fakes.backup.restores, isEmpty);
      expect(find.text(backupLabel(en, KeyBackupState.locked)), findsOneWidget);
    });
  });

  group('the labels', () {
    test('every state has a name and a sentence, and they are distinct', () {
      final labels = KeyBackupState.values
          .map((s) => backupLabel(en, s))
          .toSet();
      expect(labels.length, KeyBackupState.values.length);

      for (final state in KeyBackupState.values) {
        expect(backupExplanation(en, state), isNotEmpty);
      }
    });

    test('only a real risk has something to say', () {
      expect(riskMessage(en, RecoveryRisk.none), isNull);
      expect(riskMessage(en, RecoveryRisk.otherDevicesOnly), isNotNull);
      expect(riskMessage(en, RecoveryRisk.unrecoverable), isNotNull);
    });
  });
}
