import 'package:weft_matrix/weft_matrix.dart';

/// The account's own state — its logins and its key backup — without a
/// homeserver.
///
/// Both interfaces exist for this: every method on the real implementations is
/// a round trip plus a key-store write, and a screen that can only be exercised
/// against a live Synapse is a screen that stops being exercised. Shared
/// between `devices_screen_test.dart` and `security_screen_test.dart` because
/// the security screen reads the device list too — it is what separates "no
/// backup, but your laptop can vouch for a new phone" from "no backup and
/// nothing else" — and two device fakes would be two things to keep in step.

/// A [DeviceManager] with no homeserver behind it.
class FakeDeviceManager implements DeviceManager {
  FakeDeviceManager(this._devices);

  List<WeftDevice> _devices;

  /// Thrown by the next call instead of answering it.
  Object? failure;

  /// Whether [signOut] demands a password before it does anything, the way a
  /// homeserver does for any request that invalidates a token.
  bool demandsReauth = false;

  final List<({String deviceId, String name})> renames = [];
  final List<List<String>> signOuts = [];
  final List<String?> passwordsGiven = [];

  @override
  Future<List<WeftDevice>> devices() async {
    if (failure case final error?) throw error;
    return sortDevices(_devices);
  }

  @override
  Future<void> rename(String deviceId, String displayName) async {
    if (failure case final error?) throw error;
    renames.add((deviceId: deviceId, name: displayName));
    _devices = [
      for (final device in _devices)
        device.deviceId == deviceId
            ? device.copyWith(displayName: displayName)
            : device,
    ];
  }

  @override
  Future<void> signOut(
    List<String> deviceIds, {
    required ReauthPrompt reauth,
  }) async {
    if (failure case final error?) throw error;
    if (demandsReauth) {
      final password = await reauth();
      passwordsGiven.add(password);
      if (password == null) throw const ReauthCancelled();
    }
    signOuts.add(deviceIds);
    _devices = [
      for (final device in _devices)
        if (!deviceIds.contains(device.deviceId)) device,
    ];
  }
}

/// A [KeyBackup] with no secret storage behind it.
///
/// Models the two things the screen depends on and cannot see: what the account
/// looks like now, and what happens when a wrong key is offered.
class FakeKeyBackup implements KeyBackup {
  FakeKeyBackup({
    this.status0 = KeyBackupStatus.none,
    this.key = 'EsAABBCCDDEEFFGG',
    this.restoreFailure,
    this.createFailure,
  });

  /// What [status] reports, until a successful setup replaces it.
  KeyBackupStatus status0;

  /// The recovery key [createRecovery] hands back.
  final String key;

  /// Thrown by [restore], the way a mistyped key is.
  Object? restoreFailure;

  /// Thrown by [createRecovery].
  Object? createFailure;

  final List<({String? passphrase, bool replaceExisting})> creations = [];
  final List<String> restores = [];

  @override
  Future<KeyBackupStatus> status() async => status0;

  @override
  Future<String> createRecovery({
    String? passphrase,
    bool replaceExisting = false,
  }) async {
    if (createFailure case final error?) throw error;
    creations.add((passphrase: passphrase, replaceExisting: replaceExisting));
    status0 = const KeyBackupStatus(
      state: KeyBackupState.upToDate,
      crossSigningEnabled: true,
      version: '1',
      keyCount: 0,
    );
    return key;
  }

  @override
  Future<void> restore(String keyOrPassphrase) async {
    if (restoreFailure case final error?) throw error;
    restores.add(keyOrPassphrase);
    status0 = KeyBackupStatus(
      state: KeyBackupState.upToDate,
      crossSigningEnabled: status0.crossSigningEnabled,
      version: status0.version,
      keyCount: status0.keyCount,
    );
  }
}
