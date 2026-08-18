import 'package:matrix/encryption.dart' as enc;
import 'package:matrix/matrix.dart' as sdk;
import 'package:meta/meta.dart';

/// Where this account's server-side key backup stands.
///
/// Four states rather than the three a status line would suggest, for the same
/// reason [DeviceTrust] has four: "there is no backup" and "there is a backup
/// this device cannot open" look identical in a row and need opposite actions.
/// The first wants a setup flow that mints a new recovery key; the second wants
/// the key the user already has. Collapsing them would send half the people who
/// hit it into a flow that silently replaces the backup holding their history.
enum KeyBackupState {
  /// The homeserver holds no backup version. Every key lives only on the
  /// devices that received it.
  absent,

  /// A backup exists, but this device does not hold the key to it — so it can
  /// neither read from it nor upload to it.
  locked,

  /// Usable, but this device is holding room keys the backup does not have yet.
  outOfDate,

  /// Usable, and everything this device knows is in it.
  upToDate;

  /// Whether the homeserver has a backup at all, whatever this device can do
  /// with it.
  bool get exists => this != KeyBackupState.absent;
}

/// Classifies the backup from the three facts a client can cheaply establish.
///
/// Takes booleans rather than a client so the rule — and the order it tests
/// them in, which is the whole content of it — is checkable without a
/// homeserver, a key store or a network.
///
/// A stored secret with no server version is [absent], not out of date: account
/// data saying "there is a backup" after the version was deleted describes
/// something that no longer exists, and the only honest thing to tell someone
/// is that nothing is backed up.
KeyBackupState backupStateFrom({
  required bool serverVersionExists,
  required bool keyCached,
  required bool hasPendingKeys,
}) {
  if (!serverVersionExists) return KeyBackupState.absent;
  if (!keyCached) return KeyBackupState.locked;
  return hasPendingKeys ? KeyBackupState.outOfDate : KeyBackupState.upToDate;
}

/// What losing the device in your hand would cost.
///
/// The case worth naming is the last one: a single device, no backup, and a
/// homeserver that cannot help because it never had the keys. Every other
/// messenger the user has met would restore that history from a support desk,
/// and Matrix cannot — so the screen has to say it before the phone is dropped
/// rather than after.
enum RecoveryRisk {
  /// A backup exists on the server. A lost device costs nothing.
  none,

  /// No backup, but another session is signed in: it can verify a replacement
  /// device and share its keys with it.
  otherDevicesOnly,

  /// No backup and nothing else signed in. The history goes with the device,
  /// permanently, and nobody can undo it.
  unrecoverable,
}

/// Weighs [state] against how many *other* sessions this account has.
///
/// [KeyBackupState.locked] counts as [RecoveryRisk.none]: the server is holding
/// the keys, and whether the user still has the recovery key is a question no
/// client can answer for them. Overstating it as a risk would put a red box on
/// the account of everyone who has ever set a backup up.
RecoveryRisk recoveryRiskFrom({
  required KeyBackupState state,
  required int otherDeviceCount,
}) {
  if (state.exists) return RecoveryRisk.none;
  return otherDeviceCount > 0
      ? RecoveryRisk.otherDevicesOnly
      : RecoveryRisk.unrecoverable;
}

/// The backup as the security screen needs it.
@immutable
class KeyBackupStatus {
  const KeyBackupStatus({
    required this.state,
    required this.crossSigningEnabled,
    this.version,
    this.keyCount = 0,
  });

  /// Nothing set up at all — the state a fresh account is in, and the value the
  /// screen renders before its first load resolves.
  static const KeyBackupStatus none = KeyBackupStatus(
    state: KeyBackupState.absent,
    crossSigningEnabled: false,
  );

  final KeyBackupState state;

  /// Whether the account has cross-signing keys. Separate from the backup
  /// because they fail apart: an account can be cross-signed with no backup
  /// (verified devices, unrecoverable history) or backed up with no
  /// cross-signing (recoverable history, every device verified by hand).
  final bool crossSigningEnabled;

  /// The server's identifier for the current backup, shown so a user comparing
  /// two clients can see they are talking about the same one.
  final String? version;

  /// How many room keys the server says the backup holds.
  final int keyCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeyBackupStatus &&
          other.state == state &&
          other.crossSigningEnabled == crossSigningEnabled &&
          other.version == version &&
          other.keyCount == keyCount;

  @override
  int get hashCode =>
      Object.hash(state, crossSigningEnabled, version, keyCount);

  @override
  String toString() => 'KeyBackupStatus(${state.name}, $keyCount keys)';
}

/// A key-backup operation could not be carried out, with a sentence fit to
/// show.
///
/// Same contract as [DeviceActionException]: the message is the user-facing
/// text, not a log line. Everything in this file that fails does so with one of
/// these, because the alternative is a screen that renders a Dart exception at
/// the exact moment somebody is being asked to trust it with their history.
class KeyBackupException implements Exception {
  const KeyBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Recovery keys are base58 in blocks of four. Any whitespace the user pasted,
/// typed or was given by a password manager is noise.
String normalizeRecoveryKey(String input) =>
    input.replaceAll(RegExp(r'\s+'), '');

/// Regroups a recovery key into blocks of four, however it arrived.
///
/// The SDK already emits it spaced, but a key that has been through a clipboard
/// or a text field has usually lost that, and an unbroken 48-character string
/// is the form people mistype.
String formatRecoveryKey(String input) {
  final cleaned = normalizeRecoveryKey(input);
  return [
    for (var i = 0; i < cleaned.length; i += 4)
      cleaned.substring(i, i + 4 > cleaned.length ? cleaned.length : i + 4),
  ].join(' ');
}

/// Whether the two are the same key, ignoring how either was spaced.
bool recoveryKeyMatches(String entered, String expected) =>
    normalizeRecoveryKey(entered) == normalizeRecoveryKey(expected);

/// Whether [input] is shaped like a recovery key rather than a passphrase.
///
/// Delegates to the SDK's own test so the confirm step and the unlock path
/// cannot disagree about what a key looks like.
bool looksLikeRecoveryKey(String input) => enc.SSSS.looksLikeRecoveryKey(input);

/// The steps of the SDK's bootstrap state machine Weft actually drives.
///
/// An interface rather than the concrete [enc.Bootstrap] because the machine is
/// the dangerous part of this file: three of its states wipe something, and
/// picking the wrong arm does not throw — it quietly destroys the cross-signing
/// identity every other device is verified against. A fake can assert which
/// calls happen in which order; a live Synapse cannot be asked to prove a
/// negative.
abstract class BootstrapController {
  enc.BootstrapState get state;

  /// The key the user must save, available once the machine reaches
  /// [enc.BootstrapState.done].
  String? get recoveryKey;

  /// Whatever the machine failed with, for the message.
  Object? get error;

  void wipeSsss(bool wipe);

  Future<void> newSsss([String? passphrase]);

  Future<void> wipeCrossSigning(bool wipe);

  /// Mints and uploads all three cross-signing keys and self-signs this device.
  Future<void> setUpCrossSigning();

  void wipeOnlineKeyBackup(bool wipe);

  /// Creates the server-side backup version and uploads what this device holds.
  Future<void> setUpOnlineKeyBackup();
}

/// What [runBootstrap] says when the account already has recovery set up.
const String existingRecoveryMessage =
    'This account already has a recovery key. Setting up a new one replaces '
    'it, and the old key stops working — so Weft will not do it unless you '
    'ask for it explicitly.';

/// Runs the bootstrap machine to completion and returns the new recovery key.
///
/// Every path through here is a *fresh* setup, and that is deliberate rather
/// than lazy. The machine only offers to keep existing cross-signing keys or an
/// existing backup after migrating their secrets into the new storage key,
/// which is a path this driver never takes — so reaching either "keep" arm
/// would leave an account whose public keys claim a private half that is now
/// unreachable. Wiping and re-minting is the only honest answer once a new
/// storage key exists, and [replaceExisting] is where the user consents to it.
///
/// [steps] caps the walk so a controller that stops advancing fails loudly
/// instead of spinning; the real sequence is at most seven states long.
Future<String> runBootstrap(
  BootstrapController bootstrap, {
  required bool replaceExisting,
  String? passphrase,
  int steps = 16,
}) async {
  for (var step = 0; step < steps; step++) {
    switch (bootstrap.state) {
      case enc.BootstrapState.askWipeSsss:
        if (!replaceExisting) {
          throw const KeyBackupException(existingRecoveryMessage);
        }
        bootstrap.wipeSsss(true);
      case enc.BootstrapState.askNewSsss:
        await bootstrap.newSsss(passphrase);
      case enc.BootstrapState.askWipeCrossSigning:
        await bootstrap.wipeCrossSigning(true);
      case enc.BootstrapState.askSetupCrossSigning:
        await bootstrap.setUpCrossSigning();
      case enc.BootstrapState.askWipeOnlineKeyBackup:
        bootstrap.wipeOnlineKeyBackup(true);
      case enc.BootstrapState.askSetupOnlineKeyBackup:
        await bootstrap.setUpOnlineKeyBackup();
      case enc.BootstrapState.done:
        final key = bootstrap.recoveryKey;
        if (key == null) {
          throw const KeyBackupException(
            'Encryption was set up, but Weft did not get the recovery key back '
            'to show you. Set it up again before you rely on it.',
          );
        }
        return key;
      case enc.BootstrapState.error:
        throw KeyBackupException(
          'Your homeserver refused to set up encryption: ${bootstrap.error}',
        );
      // Every remaining state needs a key this driver does not have. They are
      // reachable only by choosing to keep existing storage, which it never
      // does, so arriving at one means the machine changed under us.
      case enc.BootstrapState.loading:
      case enc.BootstrapState.askUseExistingSsss:
      case enc.BootstrapState.askUnlockSsss:
      case enc.BootstrapState.askBadSsss:
      case enc.BootstrapState.openExistingSsss:
        throw KeyBackupException(
          'Encryption setup stopped at an unexpected step '
          '(${bootstrap.state.name}). Nothing was changed.',
        );
    }
  }

  throw const KeyBackupException(
    'Encryption setup did not finish. Nothing was changed.',
  );
}

/// Cross-signing, key backup and the recovery key behind them.
///
/// An interface for the same reason [DeviceManager] is one: every method is a
/// homeserver round trip plus a key-store write, and a screen that can only be
/// exercised against a live Synapse is a screen that stops being exercised.
abstract class KeyBackup {
  /// What the account's backup looks like right now.
  Future<KeyBackupStatus> status();

  /// Sets up cross-signing and an online key backup, and returns the recovery
  /// key the user must save. Shown once and never retrievable again — this is
  /// the only moment it exists outside the key store.
  ///
  /// Throws [KeyBackupException] with [existingRecoveryMessage] when recovery
  /// already exists and [replaceExisting] is false.
  Future<String> createRecovery({
    String? passphrase,
    bool replaceExisting = false,
  });

  /// Unlocks this account's secret storage with a recovery key or passphrase
  /// and pulls the backed-up room keys down.
  Future<void> restore(String keyOrPassphrase);
}

/// [KeyBackup] over the Famedly SDK.
class MatrixKeyBackup implements KeyBackup {
  MatrixKeyBackup(this._client);

  final sdk.Client _client;

  enc.Encryption get _encryption {
    final encryption = _client.encryption;
    if (encryption == null) {
      throw const KeyBackupException(
        'Encryption is not available on this session, so there is nothing to '
        'back up.',
      );
    }
    return encryption;
  }

  @override
  Future<KeyBackupStatus> status() async {
    final encryption = _encryption;

    String? version;
    var keyCount = 0;
    var serverVersionExists = true;
    try {
      // Uncached: a status screen exists to be right now, and the SDK's cache
      // is five minutes deep — long enough to still show "no backup" to
      // somebody staring at the screen they just made one on.
      final info = await encryption.keyManager.getRoomKeysBackupInfo(false);
      version = info.version;
      keyCount = info.count;
    } on sdk.MatrixException {
      // M_NOT_FOUND. Only a Matrix-level refusal means "no backup"; a transport
      // failure is not an answer and is allowed to propagate.
      serverVersionExists = false;
    }

    final keyCached =
        serverVersionExists && await encryption.keyManager.isCached();
    final hasPendingKeys =
        keyCached &&
        (await _client.database.getInboundGroupSessionsToUpload()).isNotEmpty;

    return KeyBackupStatus(
      state: backupStateFrom(
        serverVersionExists: serverVersionExists,
        keyCached: keyCached,
        hasPendingKeys: hasPendingKeys,
      ),
      crossSigningEnabled: encryption.crossSigning.enabled,
      version: version,
      keyCount: keyCount,
    );
  }

  @override
  Future<String> createRecovery({
    String? passphrase,
    bool replaceExisting = false,
  }) {
    // No onUpdate: every transition this driver makes is either synchronous or
    // awaited, so the state has already settled by the time the call returns
    // and a callback would only be a second, racier way to read it.
    return runBootstrap(
      SdkBootstrapController(_encryption.bootstrap()),
      replaceExisting: replaceExisting,
      passphrase: passphrase,
    );
  }

  @override
  Future<void> restore(String keyOrPassphrase) async {
    final encryption = _encryption;

    final keyId = encryption.ssss.defaultKeyId;
    if (keyId == null) {
      throw const KeyBackupException(
        'This account has no recovery key set up, so there is nothing to '
        'restore from.',
      );
    }

    final enc.OpenSSSS handle;
    try {
      handle = encryption.ssss.open(keyId);
    } catch (error) {
      throw KeyBackupException(
        'Weft could not read this account\'s recovery settings: $error',
      );
    }

    try {
      await handle.unlock(keyOrPassphrase: keyOrPassphrase.trim());
    } on enc.InvalidPassphraseException {
      throw const KeyBackupException(
        'That is not the recovery key or passphrase for this account. Check '
        'for a mistyped character — the key is case-sensitive.',
      );
    }

    // Caches the cross-signing secrets too, which is what makes this device
    // trusted rather than merely able to read old messages.
    await handle.maybeCacheAll();

    final info = await encryption.keyManager.getRoomKeysBackupInfo(false);
    await encryption.keyManager.loadFromResponse(
      await _client.getRoomKeys(info.version),
    );
  }
}

/// [BootstrapController] over the SDK's own [enc.Bootstrap].
///
/// Thin on purpose: the two calls that carry arguments are the only decisions
/// it makes, and both are fixed rather than parameterised because
/// [runBootstrap] only ever wants the full set.
class SdkBootstrapController implements BootstrapController {
  SdkBootstrapController(this._bootstrap);

  final enc.Bootstrap _bootstrap;

  @override
  enc.BootstrapState get state => _bootstrap.state;

  @override
  String? get recoveryKey => _bootstrap.newSsssKey?.recoveryKey;

  @override
  Object? get error => _bootstrap.errorResult?.error;

  @override
  void wipeSsss(bool wipe) => _bootstrap.wipeSsss(wipe);

  @override
  Future<void> newSsss([String? passphrase]) => _bootstrap.newSsss(passphrase);

  @override
  Future<void> wipeCrossSigning(bool wipe) => _bootstrap.wipeCrossSigning(wipe);

  @override
  Future<void> setUpCrossSigning() => _bootstrap.askSetupCrossSigning(
    setupMasterKey: true,
    setupSelfSigningKey: true,
    setupUserSigningKey: true,
  );

  @override
  void wipeOnlineKeyBackup(bool wipe) => _bootstrap.wipeOnlineKeyBackup(wipe);

  @override
  Future<void> setUpOnlineKeyBackup() =>
      _bootstrap.askSetupOnlineKeyBackup(true);
}
