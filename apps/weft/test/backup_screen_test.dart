import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_backup/weft_backup.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/localisation.dart';
import 'package:weft/features/settings/backup_screen.dart';
import 'package:weft/services/backup/backup_service.dart';

import 'support/backup_fakes.dart';

/// What the backup screen has to get right, and none of it is layout.
///
/// The format's own suite proves the archive. These cases are about the two
/// flows on top of it: that a passphrase the user mistyped never becomes an
/// archive they cannot open, that cancelling is honoured and said out loud, and
/// that each typed failure from `weft_backup` arrives as its own sentence
/// rather than as a shrug. The last of those is the whole reason the failures
/// are typed at all, and it is only true if this switch is exhaustive.
void main() {
  late FakeBackupService service;

  setUp(() => service = FakeBackupService());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backupServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: const BackupScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Walks the export flow as far as the passphrase dialog's confirm button.
  Future<void> openExportDialog(WidgetTester tester) async {
    await tester.tap(find.text('Create backup'));
    await tester.pumpAndSettle();
  }

  Future<void> typePassphrases(
    WidgetTester tester,
    String first,
    String second,
  ) async {
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), first);
    await tester.enterText(fields.at(1), second);
    await tester.pump();
  }

  group('the screen itself', () {
    testWidgets('says what a backup holds and what it leaves out', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('Backup & restore'), findsOneWidget);
      // The estimate is the reason anyone touches the media switch.
      expect(find.textContaining('12 conversations'), findsOneWidget);
      expect(find.textContaining('4300 messages'), findsOneWidget);

      // The exclusion is on the screen rather than in a help link. A user who
      // believes a backup restores their session would find out on the day it
      // mattered.
      expect(find.textContaining('encryption keys'), findsOneWidget);
      expect(find.textContaining('sign-in token'), findsOneWidget);
    });

    testWidgets('recounts when the media switch moves', (tester) async {
      await pump(tester);
      final before = service.estimateCalls;

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(service.estimateCalls, greaterThan(before));
    });

    testWidgets('a failed count does not take the screen with it', (
      tester,
    ) async {
      // Counting is a `COUNT(*)`; exporting is not. Refusing to draw the screen
      // would remove the feature for a worse reason than it exists.
      service.estimateError = StateError('no database');
      await pump(tester);

      expect(find.text('Create backup'), findsOneWidget);
      expect(
        find.textContaining('Could not work out how large'),
        findsOneWidget,
      );
    });
  });

  group('the export passphrase', () {
    testWidgets('the no-recovery warning is on screen before Create is', (
      tester,
    ) async {
      await pump(tester);
      await openExportDialog(tester);

      expect(
        find.textContaining('the backup cannot be opened'),
        findsOneWidget,
      );
      expect(find.text('Create'), findsOneWidget);
    });

    testWidgets('a mismatch blocks the export', (tester) async {
      await pump(tester);
      await openExportDialog(tester);
      await typePassphrases(tester, 'a passphrase here', 'a different one');

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('The two do not match.'), findsOneWidget);
      expect(service.exports, isEmpty, reason: 'nothing was exported');
    });

    testWidgets('a short passphrase blocks the export', (tester) async {
      await pump(tester);
      await openExportDialog(tester);
      await typePassphrases(tester, 'short', 'short');

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Too short'), findsOneWidget);
      expect(service.exports, isEmpty);
    });

    testWidgets('length is reported before the mismatch', (tester) async {
      // Told both at once, someone fixes the mismatch and is then told the
      // result is too short, which reads as the dialog moving the goalposts.
      await pump(tester);
      await openExportDialog(tester);
      await typePassphrases(tester, 'short', 'also different');

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Too short'), findsOneWidget);
      expect(find.text('The two do not match.'), findsNothing);
    });

    testWidgets('a matching passphrase exports and reports where it went', (
      tester,
    ) async {
      await pump(tester);
      await openExportDialog(tester);
      await typePassphrases(
        tester,
        'a long enough passphrase',
        'a long enough passphrase',
      );

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(service.exports, hasLength(1));
      expect(service.exports.single.passphrase, 'a long enough passphrase');
      expect(service.exports.single.includeMedia, isTrue);
      expect(
        find.textContaining('/tmp/braid-2026-08-28.braid'),
        findsOneWidget,
      );
    });

    testWidgets('the media switch reaches the export', (tester) async {
      await pump(tester);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      await openExportDialog(tester);
      await typePassphrases(
        tester,
        'a long enough passphrase',
        'a long enough passphrase',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(service.exports.single.includeMedia, isFalse);
    });

    testWidgets('a share-sheet hand-off says so instead of naming a path', (
      tester,
    ) async {
      // Mobile has no save dialog, so the platform cannot report a destination.
      service.exportResult = '';
      await pump(tester);
      await openExportDialog(tester);
      await typePassphrases(
        tester,
        'a long enough passphrase',
        'a long enough passphrase',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.textContaining('share sheet'), findsOneWidget);
    });

    testWidgets('a dismissed save dialog is not reported as a failure', (
      tester,
    ) async {
      service.exportResult = null;
      await pump(tester);
      await openExportDialog(tester);
      await typePassphrases(
        tester,
        'a long enough passphrase',
        'a long enough passphrase',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('progress and cancellation', () {
    /// Starts an export that keeps running until the test cancels it, and
    /// leaves the progress dialog on screen and animated in.
    Future<void> startSlowExport(WidgetTester tester) async {
      service.progressTicks = 1000;
      await pump(tester);
      await openExportDialog(tester);
      await typePassphrases(
        tester,
        'a long enough passphrase',
        'a long enough passphrase',
      );

      await tester.tap(find.text('Create'));
      await tester.pump();
      // Past the dialog's entrance animation and a few ticks of work.
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('the progress dialog appears and reports a count', (
      tester,
    ) async {
      await startSlowExport(tester);

      expect(find.text('Creating backup\u2026'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('items'), findsWidgets);

      // Unwound rather than left running: an export still ticking at teardown
      // is a pending timer, and `flutter_test` fails the test for it.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('the progress bar is a live region for a screen reader', (
      tester,
    ) async {
      // A label that changes on a surface the reader is already on — the case
      // `announce` is explicitly not for. Without the live region the bar moves
      // in silence.
      final handle = tester.ensureSemantics();
      await startSlowExport(tester);

      // The label itself is the counter, which changes as work lands; what is
      // being pinned is that the node is a live region at all, so a reader is
      // re-told rather than left on a bar that moves in silence.
      final node = tester.getSemantics(find.byType(LinearProgressIndicator));
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(node.label, isNotEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('cancel stops the export and says nothing was saved', (
      tester,
    ) async {
      await startSlowExport(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nothing was saved'), findsOneWidget);
    });
  });

  group('the restore flow', () {
    Future<void> startRestore(WidgetTester tester) async {
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
    }

    testWidgets('cancelling the file picker does nothing at all', (
      tester,
    ) async {
      service.pickResult = null;
      await pump(tester);
      await startRestore(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(service.restores, isEmpty);
    });

    testWidgets('the header preview is shown before any passphrase', (
      tester,
    ) async {
      service.pickResult = fakePickedArchive();
      await pump(tester);
      await startRestore(tester);

      // Scoped to the dialog: the screen behind it carries the same
      // "12 conversations, 4300 messages" sentence as its export estimate.
      Finder inDialog(Finder matching) =>
          find.descendant(of: find.byType(AlertDialog), matching: matching);

      expect(find.text('This backup'), findsOneWidget);
      expect(inDialog(find.text('braid-2026-08-28.braid')), findsOneWidget);
      expect(inDialog(find.textContaining('Created')), findsOneWidget);
      expect(inDialog(find.textContaining('12 conversations')), findsOneWidget);
      expect(inDialog(find.text('Photos and files included')), findsOneWidget);
      expect(
        inDialog(find.textContaining('Written by Braid 1.4.0')),
        findsOneWidget,
      );

      // The point of this step: no passphrase field yet.
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a media-free archive says so in the preview', (tester) async {
      service.pickResult = fakePickedArchive(mediaIncluded: false);
      await pump(tester);
      await startRestore(tester);

      expect(find.textContaining('messages only'), findsOneWidget);
    });

    /// Walks preview → passphrase → mode, stopping before the mode is chosen.
    Future<void> reachModeDialog(WidgetTester tester) async {
      service.pickResult ??= fakePickedArchive();
      await startRestore(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'the passphrase');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }

    testWidgets('the network list appears only after the passphrase', (
      tester,
    ) async {
      // The header deliberately withholds it, so this is the first point at
      // which it can be known — and the last chance to back out.
      service.pickResult = fakePickedArchive();
      await pump(tester);
      await startRestore(tester);
      expect(find.textContaining('whatsapp'), findsNothing);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'the passphrase');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.textContaining('whatsapp, sms'), findsOneWidget);
    });

    testWidgets('merge is the default and runs without a second prompt', (
      tester,
    ) async {
      await pump(tester);
      await reachModeDialog(tester);

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(service.restores, [ImportMode.merge]);
      expect(find.text('Restore finished'), findsOneWidget);
      expect(find.textContaining('4300 items restored'), findsOneWidget);
    });

    testWidgets('replace asks a second time before anything is deleted', (
      tester,
    ) async {
      await pump(tester);
      await reachModeDialog(tester);

      await tester.tap(find.text('Replace what is here'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Delete what is on this device?'),
        findsOneWidget,
      );
      expect(service.restores, isEmpty, reason: 'not yet confirmed');

      await tester.tap(find.text('Delete and restore'));
      await tester.pumpAndSettle();

      expect(service.restores, [ImportMode.replace]);
    });

    testWidgets('backing out of the replace warning restores nothing', (
      tester,
    ) async {
      await pump(tester);
      await reachModeDialog(tester);

      await tester.tap(find.text('Replace what is here'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      // The mode dialog is still behind this one and has its own Cancel; the
      // last in the tree is the confirmation's.
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();

      expect(service.restores, isEmpty);
    });

    testWidgets('an archive from a newer Braid says what it could not read', (
      tester,
    ) async {
      // Swallowing this would leave the user believing they have a complete
      // copy when they do not, which is the one thing a backup must not do.
      service.restoreResult = ImportOutcome(
        manifest: ArchiveManifest(
          createdAt: DateTime.utc(2026, 8, 28),
          appVersion: '9.9.9',
        ),
        applied: 4300,
        skippedExisting: 7,
        skippedUnknownType: 12,
        mediaWritten: 88,
        mediaSkipped: 0,
        unknownTypes: const {'holiday_plan'},
      );

      await pump(tester);
      await reachModeDialog(tester);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(find.textContaining('7 items were already here'), findsOneWidget);
      expect(find.textContaining('newer version of Braid'), findsOneWidget);
    });
  });

  group('every typed failure gets its own sentence', () {
    /// Each failure, and a phrase only its message contains.
    const cases = <(String, String)>[
      ('notAnArchive', 'not a Braid backup'),
      ('malformed', 'damaged near its start'),
      ('unsupportedVersion', 'newer version of Braid (9.0)'),
      ('wrongPassphrase', 'does not open this backup'),
      ('truncated', 'file ends early'),
      ('damaged', 'If you have another copy'),
      ('unknown', 'could not be finished'),
    ];

    ArchiveOpenFailure? failureFor(String name) => switch (name) {
      'notAnArchive' => const NotAnArchiveFailure(),
      'malformed' => const MalformedArchiveFailure(),
      'unsupportedVersion' => const UnsupportedVersionFailure(
        ArchiveVersion(9, 0),
      ),
      'wrongPassphrase' => const WrongPassphraseFailure(),
      'truncated' => const TruncatedArchiveFailure(),
      'damaged' => const DamagedArchiveFailure(3),
      // Deliberately not an ArchiveOpenFailure: the catch-all branch is a real
      // branch and an untested one is how it becomes a crash.
      _ => null,
    };

    for (final (name, phrase) in cases) {
      testWidgets('$name, raised while picking', (tester) async {
        service.pickError = failureFor(name) ?? const _UnexpectedFailure();
        await pump(tester);
        await tester.tap(find.text('Choose a file'));
        await tester.pumpAndSettle();

        expect(find.textContaining(phrase), findsOneWidget);
      });
    }

    testWidgets('a wrong passphrase is reported before a mode is chosen', (
      tester,
    ) async {
      service
        ..pickResult = fakePickedArchive()
        ..manifestError = const WrongPassphraseFailure();

      await pump(tester);
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.textContaining('does not open this backup'), findsOneWidget);
      expect(find.text('How should this be restored?'), findsNothing);
    });

    testWidgets('a mid-restore failure says nothing was changed', (
      tester,
    ) async {
      service
        ..pickResult = fakePickedArchive()
        ..restoreError = const DamagedArchiveFailure(4);

      await pump(tester);
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'the passphrase');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(find.textContaining('This backup is damaged'), findsOneWidget);
      expect(find.text('Restore finished'), findsNothing);
    });
  });
}

/// Something `weft_backup` never raises.
///
/// Exists so the catch-all branch of `_describeFailure` is a branch under test
/// rather than the one nobody exercised until a disk filled up.
class _UnexpectedFailure implements Exception {
  const _UnexpectedFailure();
}
