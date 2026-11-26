import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/stores.dart';

/// The app lock's settings, all of this device's alone.
///
/// Under `lock.`, which device sync does not carry: a lock is a promise about
/// one device, and a PIN set on the laptop must not start guarding the phone.
abstract final class AppLockSettings {
  static const String enabled = 'lock.enabled';
  static const String biometrics = 'lock.biometrics';

  /// Seconds in the background before the lock comes back; 0 is at once.
  static const String afterSeconds = 'lock.after_seconds';

  /// The PIN's keychain name. Only a salted hash is ever written.
  static const String pinSecret = 'app_lock_pin';
}

/// What "Lock after" offers, in seconds.
const List<int> kAppLockAfterChoices = [0, 60, 300, 900];

/// One minute: long enough to fetch a photo from the gallery and come back,
/// short enough that a phone put down on a table is locked by the time
/// someone else picks it up.
const int kDefaultAppLockAfterSeconds = 60;

const int kAppLockPinMinLength = 4;
const int kAppLockPinMaxLength = 8;

/// Wrong PINs in a row before the lock makes you wait.
const int kAppLockMaxTries = 5;
const Duration kAppLockWait = Duration(seconds: 30);

bool isValidAppLockPin(String pin) =>
    pin.length >= kAppLockPinMinLength &&
    pin.length <= kAppLockPinMaxLength &&
    RegExp(r'^[0-9]+$').hasMatch(pin);

/// Whether the lock is on, read from [settings].
bool appLockEnabled(SettingsStore settings) =>
    settings.getBool(AppLockSettings.enabled);

/// Whether a stay in the background of [away] calls for the lock again.
bool appLockDueAfter(Duration away, int afterSeconds) =>
    away.inSeconds >= afterSeconds;

/// Where the PIN's hash is kept. An interface so tests need no keychain.
abstract class AppLockPinStore {
  Future<String?> read();
  Future<void> write(String? value);
}

class _KeychainPinStore implements AppLockPinStore {
  _KeychainPinStore(this._secrets);

  final SecretStore _secrets;

  @override
  Future<String?> read() => _secrets.read(AppLockSettings.pinSecret);

  @override
  Future<void> write(String? value) =>
      _secrets.write(AppLockSettings.pinSecret, value);
}

final appLockPinStoreProvider = Provider<AppLockPinStore>(
  (ref) => _KeychainPinStore(ref.watch(storesProvider).secrets),
);

/// A PIN turned into something safe to keep, and checked against it.
///
/// PBKDF2 with a random salt, so the keychain entry does not give the PIN
/// away even to someone who can read it. A short numeric PIN can still be
/// tried exhaustively offline; what really guards it is the keychain and the
/// wait after [kAppLockMaxTries] wrong guesses.
class AppLockPinHasher {
  const AppLockPinHasher({this.iterations = 20000});

  final int iterations;

  Future<String> hash(String pin) async {
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final digest = await _derive(pin, salt, iterations);
    return 'v1:$iterations:${base64Encode(salt)}:${base64Encode(digest)}';
  }

  Future<bool> verify(String pin, String stored) async {
    final parts = stored.split(':');
    if (parts.length != 4 || parts[0] != 'v1') return false;
    final rounds = int.tryParse(parts[1]);
    if (rounds == null) return false;
    final digest = await _derive(pin, base64Decode(parts[2]), rounds);
    final expected = base64Decode(parts[3]);
    if (digest.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < digest.length; i++) {
      diff |= digest[i] ^ expected[i];
    }
    return diff == 0;
  }

  static Future<List<int>> _derive(
    String pin,
    List<int> salt,
    int rounds,
  ) async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: rounds,
      bits: 256,
    ).deriveKeyFromPassword(password: pin, nonce: salt);
    return key.extractBytes();
  }
}

final appLockPinHasherProvider = Provider<AppLockPinHasher>(
  (ref) => const AppLockPinHasher(),
);

/// The system's own unlock — fingerprint, face, Windows Hello.
abstract class AppLockBiometrics {
  Future<bool> available();
  Future<bool> authenticate(String reason);
}

class _PlatformBiometrics implements AppLockBiometrics {
  final _auth = LocalAuthentication();

  static const _privacy = MethodChannel('com.bostrot.weft/privacy');

  @override
  Future<bool> available() async {
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.linux) return false;
    try {
      if (defaultTargetPlatform == TargetPlatform.android &&
          await _privacy.invokeMethod<bool>('canUseBiometrics') != true) {
        return false;
      }
      return await _auth.canCheckBiometrics && await _auth.isDeviceSupported();
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on Object {
      // Cancelled, locked out, no enrolment: the PIN is still there.
      return false;
    }
  }
}

final appLockBiometricsProvider = Provider<AppLockBiometrics>(
  (ref) => _PlatformBiometrics(),
);

/// Tells Android to leave the chats out of the recent-apps preview.
///
/// iOS and macOS get a cover drawn by the lock gate instead, since there the
/// snapshot is taken of whatever Flutter shows as the app goes inactive.
Future<void> applyHideInRecents({required bool hide}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await const MethodChannel(
      'com.bostrot.weft/privacy',
    ).invokeMethod<void>('setHideInRecents', {'hide': hide});
  } on Object {
    // An older build without the channel; nothing to hide with.
  }
}

/// Whether this run of the app has been unlocked, and when it went away.
@immutable
class AppLockSession {
  const AppLockSession({this.unlocked = false, this.awaySince});

  final bool unlocked;
  final DateTime? awaySince;
}

class AppLockSessionNotifier extends Notifier<AppLockSession> {
  @override
  AppLockSession build() => const AppLockSession();

  /// The PIN or the biometric prompt was answered.
  void unlock() => state = const AppLockSession(unlocked: true);

  /// The app left the screen; the clock for "Lock after" starts.
  ///
  /// With [afterSeconds] 0 the lock is drawn now rather than on return, so
  /// the last frame the system keeps of the app is already the lock.
  void wentAway(int afterSeconds) {
    if (state.awaySince != null) return;
    state = AppLockSession(
      unlocked: state.unlocked && afterSeconds > 0,
      awaySince: clock.now(),
    );
  }

  /// Back on screen: locks again when it was away for long enough.
  void cameBack(int afterSeconds) {
    final since = state.awaySince;
    if (since == null) return;
    final due = appLockDueAfter(clock.now().difference(since), afterSeconds);
    state = AppLockSession(unlocked: state.unlocked && !due);
  }
}

final appLockSessionProvider =
    NotifierProvider<AppLockSessionNotifier, AppLockSession>(
      AppLockSessionNotifier.new,
    );
