import 'dart:async';

import 'hlc.dart';
import 'sync_cipher.dart';
import 'sync_document.dart';
import 'sync_reconciler.dart';

/// Where the sealed document lives — Matrix account data in the app, a map in
/// tests.
abstract interface class SyncChannel {
  /// The account's key-backup secret, or null while this device cannot read
  /// the backup.
  Future<String?> backupSecret();

  /// The contents of account-data [type], or null.
  Map<String, Object?>? read(String type);

  Future<void> write(String type, Map<String, Object?> content);
}

/// This device's side: what it holds now, what it remembers sharing, and how
/// to take in what another device wrote.
abstract interface class SyncLocal {
  /// Every value device sync may share, keyed by sync key.
  Map<String, String> collect();

  Map<String, SyncRecord> loadState();
  void saveState(Map<String, SyncRecord> state);

  /// Writes what the shared document asks for. A null value removes.
  Future<void> apply(Map<String, String?> changes);
}

/// How the last round went.
enum SyncOutcome {
  /// Nothing to do, or done.
  synced,

  /// This device cannot read the key backup, so it has no key.
  noKey,

  /// The shared document is sealed with a key this device does not have —
  /// another backup. Overwriting it would cut the other devices off.
  otherKey,

  /// The shared document is damaged or forged. Not applied.
  corrupt,

  /// Some parts of the document have not arrived yet.
  waiting,

  /// The homeserver refused or could not be reached.
  failed,
}

/// Runs sync rounds one at a time.
class DeviceSync {
  DeviceSync({
    required this.channel,
    required this.local,
    required String deviceId,
    int Function()? now,
  }) : _clock = HlcClock(deviceId, now: now);

  final SyncChannel channel;
  final SyncLocal local;
  final HlcClock _clock;
  Future<SyncOutcome> _tail = Future.value(SyncOutcome.synced);
  bool _clockSeeded = false;

  /// Runs a round after the one in flight. [replace] seals this device's view
  /// over a document it cannot open — the user's explicit way out of
  /// [SyncOutcome.otherKey] and [SyncOutcome.corrupt].
  Future<SyncOutcome> run({bool replace = false}) =>
      _tail = _tail.then((_) => _round(replace: replace));

  Future<SyncOutcome> _round({required bool replace}) async {
    try {
      final secret = await channel.backupSecret();
      if (secret == null) return SyncOutcome.noKey;
      final cipher = await SyncCipher.fromBackupSecret(secret);

      final state = local.loadState();
      if (!_clockSeeded) {
        // A restart must not issue stamps older than ones already shared.
        for (final record in state.values) {
          _clock.receive(record.hlc);
        }
        _clockSeeded = true;
      }

      SyncDocument? remote;
      final manifest = channel.read(kSyncEventType);
      if (manifest != null && manifest.isNotEmpty) {
        try {
          remote = await cipher.open(
            manifest,
            (i) => channel.read('$kSyncEventType.$i'),
          );
        } on SyncOpenException catch (e) {
          switch (e.failure) {
            case SyncOpenFailure.incomplete:
              return SyncOutcome.waiting;
            case SyncOpenFailure.otherKey when !replace:
              return SyncOutcome.otherKey;
            case SyncOpenFailure.corrupt when !replace:
              return SyncOutcome.corrupt;
            case SyncOpenFailure.otherKey || SyncOpenFailure.corrupt:
              remote = null;
          }
        }
      }

      final result = reconcile(
        state: state,
        local: local.collect(),
        remote: remote,
        clock: _clock,
      );
      if (result.apply.isNotEmpty) await local.apply(result.apply);
      if (!_sameState(state, result.state)) local.saveState(result.state);
      if (result.upload || (replace && manifest != null)) {
        final sealed = await cipher.seal(result.document);
        // Parts first: a device that sees the new manifest must find them.
        for (var i = 0; i < sealed.parts.length; i++) {
          await channel.write('$kSyncEventType.$i', sealed.parts[i]);
        }
        await channel.write(kSyncEventType, sealed.manifest);
      }
      return SyncOutcome.synced;
    } on Object {
      return SyncOutcome.failed;
    }
  }

  static bool _sameState(Map<String, SyncRecord> a, Map<String, SyncRecord> b) {
    if (a.length != b.length) return false;
    for (final MapEntry(:key, :value) in a.entries) {
      if (b[key] != value) return false;
    }
    return true;
  }
}
