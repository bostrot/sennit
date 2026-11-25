import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_store/weft_store.dart';
import 'package:weft_sync/weft_sync.dart';

import '../data/matrix_chat_repository.dart';
import '../services/sync/matrix_sync_channel.dart';
import '../services/sync/store_sync_local.dart';
import 'draft_providers.dart';
import 'providers.dart';
import 'session_providers.dart';
import 'stores.dart';

/// Whether this device takes part in device sync.
final deviceSyncEnabledProvider = Provider<bool>((ref) {
  ref.watch(settingsRevisionProvider);
  return storesOrNull(ref)?.settings.getBool(WeftSettings.syncEnabled) ?? false;
});

/// How the last round went, and when. Null before the first round.
typedef DeviceSyncStatus = ({SyncOutcome outcome, DateTime at});

class DeviceSyncStatusNotifier extends Notifier<DeviceSyncStatus?> {
  @override
  DeviceSyncStatus? build() => null;

  void report(SyncOutcome outcome) =>
      state = (outcome: outcome, at: DateTime.now());
}

final deviceSyncStatusProvider =
    NotifierProvider<DeviceSyncStatusNotifier, DeviceSyncStatus?>(
      DeviceSyncStatusNotifier.new,
    );

/// Runs device sync while it is on: once at start, when another device
/// replaces the shared document, shortly after a setting or a draft changes
/// here, and once a minute for the edits nothing announces — a merge, a send
/// network.
///
/// Null while sync is off. `main` holds a listener on this once the session is
/// ready, which is what keeps it — and its timers — alive.
final deviceSyncRunnerProvider = Provider<DeviceSyncRunner?>((ref) {
  if (!ref.watch(deviceSyncEnabledProvider)) return null;
  final stores = ref.watch(storesProvider);
  final client = ref.watch(matrixSessionProvider).client;
  final channel = MatrixSyncChannel(client);
  final local = StoreSyncLocal(
    stores,
    onSettingsChanged: () => ref.read(settingsRevisionProvider.notifier).bump(),
    onMergesChanged: () {
      final repository = ref.read(chatRepositoryProvider);
      if (repository is MatrixChatRepository) {
        repository.reloadSyncedPreferences();
      }
    },
    onDraftsChanged: () => ref.read(draftsProvider.notifier).reload(),
  );
  final runner = DeviceSyncRunner(
    DeviceSync(
      channel: channel,
      local: local,
      deviceId: _deviceId(stores.settings),
    ),
    report: (outcome) =>
        ref.read(deviceSyncStatusProvider.notifier).report(outcome),
  );
  runner.start(channel.changes);
  // A setting written here — including by sync itself, which is harmless: the
  // round finds nothing new — is shared a few seconds later.
  ref.listen(settingsRevisionProvider, (_, _) => runner.soon());
  // So is a draft, once the chat it was typed in is left.
  ref.listen(draftsProvider, (_, _) => runner.soon());
  ref.onDispose(runner.dispose);
  return runner;
});

String _deviceId(SettingsStore settings) {
  final existing = settings.getString(WeftSettings.syncDeviceId);
  if (existing != null && existing.isNotEmpty) return existing;
  final rng = Random.secure();
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final id = String.fromCharCodes([
    for (var i = 0; i < 10; i++) alphabet.codeUnitAt(rng.nextInt(36)),
  ]);
  settings.setString(WeftSettings.syncDeviceId, id);
  return id;
}

/// Schedules [DeviceSync] rounds.
class DeviceSyncRunner {
  DeviceSyncRunner(this._sync, {required this.report});

  final DeviceSync _sync;
  final void Function(SyncOutcome) report;
  StreamSubscription<void>? _changes;
  Timer? _periodic;
  Timer? _debounce;
  bool _disposed = false;

  void start(Stream<void> changes) {
    _changes = changes.listen((_) => soon());
    _periodic = Timer.periodic(const Duration(minutes: 1), (_) => now());
    unawaited(now());
  }

  /// A round in a few seconds, folding a burst of edits into one upload.
  void soon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), now);
  }

  /// A round now. [replace] overwrites a shared document this device cannot
  /// open — only ever on the user's say-so.
  Future<SyncOutcome> now({bool replace = false}) async {
    final outcome = await _sync.run(replace: replace);
    if (!_disposed) report(outcome);
    return outcome;
  }

  void dispose() {
    _disposed = true;
    unawaited(_changes?.cancel());
    _periodic?.cancel();
    _debounce?.cancel();
  }
}
