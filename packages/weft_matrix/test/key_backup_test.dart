import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart' as enc;
import 'package:weft_matrix/weft_matrix.dart';

/// The SDK's bootstrap machine, without a homeserver behind it.
///
/// Reproduces the transitions `Bootstrap` actually makes — wipe leads to a
/// fresh state, `newSsss` mints the key, cross-signing and the online backup
/// each branch on whether one already exists — and records the calls in order.
///
/// This is the fake the whole file exists for. Every destructive step in the
/// real machine is a method that returns void or a `Future<void>` and reports
/// nothing: choosing the wrong arm does not throw, it silently discards the
/// cross-signing identity every other device is verified against. The only way
/// to check the driver never does that is to ask a stand-in what it was told.
class FakeBootstrap implements BootstrapController {
  FakeBootstrap({
    enc.BootstrapState initial = enc.BootstrapState.askNewSsss,
    this.crossSigningExists = false,
    this.backupExists = false,
    this.key = 'EsAA BBCC DDEE FFGG',
    this.stall = false,
  }) : _state = initial;

  enc.BootstrapState _state;

  /// Whether the account already has cross-signing keys, which is what makes
  /// the machine ask about wiping them.
  final bool crossSigningExists;
  final bool backupExists;

  /// The recovery key `newSsss` produces, or null to model a machine that
  /// reaches `done` with nothing to show.
  final String? key;

  /// Never advances, to model a machine that has stopped answering.
  final bool stall;

  String? _recoveryKey;
  Object? _error;

  final List<String> calls = [];
  String? passphraseGiven;

  @override
  enc.BootstrapState get state => _state;

  @override
  String? get recoveryKey => _recoveryKey;

  @override
  Object? get error => _error;

  /// Drops the machine into its failure state, the way an upload refused by the
  /// homeserver does.
  void fail(Object error) {
    _error = error;
    _state = enc.BootstrapState.error;
  }

  @override
  void wipeSsss(bool wipe) {
    calls.add('wipeSsss($wipe)');
    if (stall) return;
    _state = enc.BootstrapState.askNewSsss;
  }

  @override
  Future<void> newSsss([String? passphrase]) async {
    calls.add('newSsss');
    passphraseGiven = passphrase;
    if (stall) return;
    _recoveryKey = key;
    _state = crossSigningExists
        ? enc.BootstrapState.askWipeCrossSigning
        : enc.BootstrapState.askSetupCrossSigning;
  }

  @override
  Future<void> wipeCrossSigning(bool wipe) async {
    calls.add('wipeCrossSigning($wipe)');
    _state = enc.BootstrapState.askSetupCrossSigning;
  }

  @override
  Future<void> setUpCrossSigning() async {
    calls.add('setUpCrossSigning');
    _state = backupExists
        ? enc.BootstrapState.askWipeOnlineKeyBackup
        : enc.BootstrapState.askSetupOnlineKeyBackup;
  }

  @override
  void wipeOnlineKeyBackup(bool wipe) {
    calls.add('wipeOnlineKeyBackup($wipe)');
    _state = enc.BootstrapState.askSetupOnlineKeyBackup;
  }

  @override
  Future<void> setUpOnlineKeyBackup() async {
    calls.add('setUpOnlineKeyBackup');
    _state = enc.BootstrapState.done;
  }
}

void main() {
  group('backupStateFrom', () {
    test('no server version is absent, whatever this device holds', () {
      // Account data that still names a backup after the version was deleted
      // describes something that is not there, and the only honest answer is
      // that nothing is backed up.
      expect(
        backupStateFrom(
          serverVersionExists: false,
          keyCached: false,
          hasPendingKeys: true,
        ),
        KeyBackupState.absent,
      );
    });

    test('a backup this device cannot open is its own state', () {
      // The distinction the enum exists for: "locked" wants the key the user
      // already has, "absent" wants a new one — and offering the second to
      // somebody in the first state replaces the backup holding their history.
      expect(
        backupStateFrom(
          serverVersionExists: true,
          keyCached: false,
          hasPendingKeys: false,
        ),
        KeyBackupState.locked,
      );
    });

    test('pending keys are what makes a usable backup out of date', () {
      expect(
        backupStateFrom(
          serverVersionExists: true,
          keyCached: true,
          hasPendingKeys: true,
        ),
        KeyBackupState.outOfDate,
      );
      expect(
        backupStateFrom(
          serverVersionExists: true,
          keyCached: true,
          hasPendingKeys: false,
        ),
        KeyBackupState.upToDate,
      );
    });

    test('only absent means the server has nothing', () {
      expect(KeyBackupState.absent.exists, isFalse);
      expect(KeyBackupState.locked.exists, isTrue);
      expect(KeyBackupState.outOfDate.exists, isTrue);
      expect(KeyBackupState.upToDate.exists, isTrue);
    });
  });

  group('recoveryRiskFrom', () {
    test('one device, no backup, is the case worth spelling out', () {
      expect(
        recoveryRiskFrom(state: KeyBackupState.absent, otherDeviceCount: 0),
        RecoveryRisk.unrecoverable,
      );
    });

    test('another signed-in device is a weaker answer, not a red box', () {
      expect(
        recoveryRiskFrom(state: KeyBackupState.absent, otherDeviceCount: 1),
        RecoveryRisk.otherDevicesOnly,
      );
    });

    test('a locked backup is not a risk — the server is holding the keys', () {
      // Whether the user still has their recovery key is a question no client
      // can answer, and guessing "no" puts a warning on every account that has
      // ever set one up.
      expect(
        recoveryRiskFrom(state: KeyBackupState.locked, otherDeviceCount: 0),
        RecoveryRisk.none,
      );
      expect(
        recoveryRiskFrom(state: KeyBackupState.upToDate, otherDeviceCount: 0),
        RecoveryRisk.none,
      );
    });
  });

  group('recovery keys', () {
    // 48 base58 characters starting `Es`, which is what the SDK's own test for
    // a recovery key looks for.
    final realistic = 'Es${'A' * 46}';

    test('regroups into blocks of four however it arrived', () {
      expect(formatRecoveryKey('EsAABBCCDDEE'), 'EsAA BBCC DDEE');
      expect(formatRecoveryKey('EsAA BBCC DDEE'), 'EsAA BBCC DDEE');
      expect(formatRecoveryKey('EsAA\n BBCC\tDDEE'), 'EsAA BBCC DDEE');
    });

    test('a length that is not a multiple of four keeps its tail', () {
      expect(formatRecoveryKey('EsAABBCCD'), 'EsAA BBCC D');
    });

    test('round trips: what is shown is what is accepted back', () {
      // The confirm step compares what the user pasted against what was on
      // screen, and the two have been through different amounts of whitespace.
      expect(recoveryKeyMatches(formatRecoveryKey(realistic), realistic), true);
      expect(recoveryKeyMatches('  $realistic  ', realistic), true);
    });

    test('is case-sensitive, because base58 is', () {
      expect(recoveryKeyMatches('EsAABB', 'esaabb'), isFalse);
    });

    test('a passphrase is not mistaken for a key', () {
      // The unlock path tries a recovery key first and falls back; the confirm
      // step has no fallback, so it must not accept prose.
      expect(looksLikeRecoveryKey(realistic), isTrue);
      expect(looksLikeRecoveryKey('correct horse battery staple'), isFalse);
      expect(looksLikeRecoveryKey('Es${'A' * 45}'), isFalse);
    });
  });

  group('runBootstrap', () {
    test('a fresh account walks the machine and hands back the key', () async {
      final bootstrap = FakeBootstrap();

      final key = await runBootstrap(bootstrap, replaceExisting: false);

      expect(key, 'EsAA BBCC DDEE FFGG');
      expect(bootstrap.calls, [
        'newSsss',
        'setUpCrossSigning',
        'setUpOnlineKeyBackup',
      ]);
    });

    test('the passphrase reaches the key that is minted', () async {
      final bootstrap = FakeBootstrap();

      await runBootstrap(
        bootstrap,
        replaceExisting: false,
        passphrase: 'a thing I can remember',
      );

      expect(bootstrap.passphraseGiven, 'a thing I can remember');
    });

    test('existing recovery is refused, and nothing is touched', () async {
      final bootstrap = FakeBootstrap(initial: enc.BootstrapState.askWipeSsss);

      await expectLater(
        runBootstrap(bootstrap, replaceExisting: false),
        throwsA(
          isA<KeyBackupException>().having(
            (e) => e.message,
            'message',
            existingRecoveryMessage,
          ),
        ),
      );
      // The important half: the refusal happens before the first wipe, not
      // after it.
      expect(bootstrap.calls, isEmpty);
    });

    test('replacing wipes all three, in order', () async {
      final bootstrap = FakeBootstrap(
        initial: enc.BootstrapState.askWipeSsss,
        crossSigningExists: true,
        backupExists: true,
      );

      await runBootstrap(bootstrap, replaceExisting: true);

      expect(bootstrap.calls, [
        'wipeSsss(true)',
        'newSsss',
        'wipeCrossSigning(true)',
        'setUpCrossSigning',
        'wipeOnlineKeyBackup(true)',
        'setUpOnlineKeyBackup',
      ]);
    });

    test('existing cross-signing is re-minted, never kept', () async {
      // Keeping it would leave public keys whose private halves are in the
      // storage key we just replaced — an account that claims to be
      // cross-signed and cannot prove it.
      final bootstrap = FakeBootstrap(crossSigningExists: true);

      await runBootstrap(bootstrap, replaceExisting: false);

      expect(bootstrap.calls, [
        'newSsss',
        'wipeCrossSigning(true)',
        'setUpCrossSigning',
        'setUpOnlineKeyBackup',
      ]);
    });

    test('a failed machine reports what the server said', () async {
      final bootstrap = FakeBootstrap()..fail('M_FORBIDDEN');

      await expectLater(
        runBootstrap(bootstrap, replaceExisting: false),
        throwsA(
          isA<KeyBackupException>().having(
            (e) => e.message,
            'message',
            contains('M_FORBIDDEN'),
          ),
        ),
      );
    });

    test(
      'a state needing a key we do not have stops rather than guesses',
      () async {
        final bootstrap = FakeBootstrap(
          initial: enc.BootstrapState.askUnlockSsss,
        );

        await expectLater(
          runBootstrap(bootstrap, replaceExisting: true),
          throwsA(
            isA<KeyBackupException>().having(
              (e) => e.message,
              'message',
              allOf(contains('askUnlockSsss'), contains('Nothing was changed')),
            ),
          ),
        );
        expect(bootstrap.calls, isEmpty);
      },
    );

    test('a machine that stops advancing fails instead of spinning', () async {
      final bootstrap = FakeBootstrap(stall: true);

      await expectLater(
        runBootstrap(bootstrap, replaceExisting: false, steps: 3),
        throwsA(isA<KeyBackupException>()),
      );
      expect(bootstrap.calls, ['newSsss', 'newSsss', 'newSsss']);
    });

    test('done with no key is a failure, not a silent success', () async {
      // A caller that got null here would show a setup screen that finished and
      // no key, which is the one outcome worse than an error.
      final bootstrap = FakeBootstrap(key: null);

      await expectLater(
        runBootstrap(bootstrap, replaceExisting: false),
        throwsA(isA<KeyBackupException>()),
      );
    });
  });

  group('KeyBackupStatus', () {
    test('is a value type', () {
      const one = KeyBackupStatus(
        state: KeyBackupState.upToDate,
        crossSigningEnabled: true,
        version: '4',
        keyCount: 12,
      );
      const same = KeyBackupStatus(
        state: KeyBackupState.upToDate,
        crossSigningEnabled: true,
        version: '4',
        keyCount: 12,
      );
      const other = KeyBackupStatus(
        state: KeyBackupState.upToDate,
        crossSigningEnabled: true,
        version: '5',
        keyCount: 12,
      );

      expect(one, same);
      expect(one.hashCode, same.hashCode);
      expect(one, isNot(other));
    });

    test('the empty value is an account with nothing set up', () {
      expect(KeyBackupStatus.none.state, KeyBackupState.absent);
      expect(KeyBackupStatus.none.crossSigningEnabled, isFalse);
    });
  });
}
