/// The account's own state — its logins and its key backup — for demo mode.
///
/// [DemoChatRepository] gives demo mode an inbox; these give it the two
/// settings screens that are not about rooms at all. Without them
/// `deviceManagerProvider` and `keyBackupProvider` build a
/// [MatrixDeviceManager] over `session.client`, and in demo mode there is no
/// session to have a client — `WeftMatrixSession.initialize()` is never called
/// — so Settings ▸ Devices and Settings ▸ Encryption were a red error screen
/// with a `ProviderException` on it. The route walk found both.
///
/// Those two providers are deliberately *unguarded* against an uninitialised
/// session, and that stays true: reading them before login is a programming
/// error and should fail loudly rather than report a healthy empty account.
/// Demo mode is a different question — it is a mode where every other seam is
/// already a fixture — so it gets fixtures here too rather than a guard that
/// would soften the real path.
///
/// Deliberately not the test fakes in `test/support/session_fakes.dart`. Those
/// model *failures* — a homeserver that demands re-auth, a mistyped recovery
/// key — because that is what those screens' tests are about. These model an
/// account that plainly works, because that is what a screenshot, a golden and
/// a route walk are for.
library;

import 'package:weft_matrix/weft_matrix.dart';

/// A [DeviceManager] over three fictional logins.
///
/// One of each trust state that has a control behind it: this device
/// (verified), a laptop that has never been verified, and an old client with no
/// keys at all. That spread is the point — a demo devices screen showing three
/// identical verified rows would exercise none of the screen's actual work.
class DemoDeviceManager implements DeviceManager {
  DemoDeviceManager();

  List<WeftDevice> _devices = [
    WeftDevice(
      deviceId: 'BRAIDPHONE',
      displayName: 'Sennit on Pixel 8',
      lastSeenIp: '192.168.1.24',
      lastSeenAt: DateTime(2026, 8, 15, 16, 40),
      isCurrent: true,
      trust: DeviceTrust.verified,
    ),
    WeftDevice(
      deviceId: 'BRAIDLAPTOP',
      displayName: 'Sennit on MacBook Pro',
      lastSeenIp: '192.168.1.31',
      lastSeenAt: DateTime(2026, 8, 15, 9, 12),
      trust: DeviceTrust.unverified,
    ),
    WeftDevice(
      deviceId: 'OLDCLIENT',
      lastSeenIp: '84.112.9.7',
      lastSeenAt: DateTime(2026, 7, 2, 21, 5),
    ),
  ];

  @override
  Future<List<WeftDevice>> devices() async => sortDevices(_devices);

  @override
  Future<void> rename(String deviceId, String displayName) async {
    _devices = [
      for (final device in _devices)
        device.deviceId == deviceId
            ? device.copyWith(displayName: displayName)
            : device,
    ];
  }

  /// Signs out without asking for a password.
  ///
  /// A real homeserver demands re-authentication for anything that invalidates
  /// a token, and demo mode has no password to give — so prompting would open
  /// a dialog with no correct answer in it.
  @override
  Future<void> signOut(
    List<String> deviceIds, {
    required ReauthPrompt reauth,
  }) async {
    _devices = [
      for (final device in _devices)
        if (!deviceIds.contains(device.deviceId)) device,
    ];
  }
}

/// A [KeyBackup] for an account with cross-signing and a working backup.
///
/// The healthy state on purpose. The two unhealthy ones — no backup, and a
/// backup this device cannot read — are what `security_screen_test.dart`
/// pumps, and they need a fake that can be told which to be; a demo account is
/// simply an account, and the screen it draws is the one most people will have.
class DemoKeyBackup implements KeyBackup {
  DemoKeyBackup();

  KeyBackupStatus _status = const KeyBackupStatus(
    state: KeyBackupState.upToDate,
    crossSigningEnabled: true,
    version: '3',
    keyCount: 412,
  );

  @override
  Future<KeyBackupStatus> status() async => _status;

  @override
  Future<String> createRecovery({
    String? passphrase,
    bool replaceExisting = false,
  }) async {
    _status = KeyBackupStatus(
      state: KeyBackupState.upToDate,
      crossSigningEnabled: true,
      version: '${int.parse(_status.version ?? '0') + 1}',
      keyCount: _status.keyCount,
    );
    // Formatted the way a real recovery key is — four-character groups — so the
    // screen that shows it is laid out against a string of the right shape.
    return 'EsTx 4Kd9 7Fma 2Qpv 8Rzb 1Nhy 6Cwe 3TLk';
  }

  @override
  Future<void> restore(String keyOrPassphrase) async {
    _status = KeyBackupStatus(
      state: KeyBackupState.upToDate,
      crossSigningEnabled: _status.crossSigningEnabled,
      version: _status.version,
      keyCount: _status.keyCount,
    );
  }
}
