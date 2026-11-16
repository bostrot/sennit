import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../data/demo_account.dart';

/// Runs the app on in-memory fixtures instead of a homeserver.
///
///     flutter run --dart-define=WEFT_DEMO=true
///
/// Useful for UI work, screenshots and golden tests without credentials.
const bool kDemoMode = bool.fromEnvironment('WEFT_DEMO');

final matrixSessionProvider = Provider<WeftMatrixSession>((ref) {
  // The clientName stays 'Weft' — it keys the session database, and a
  // rename there is a logout. The device name is what other clients list.
  final session = WeftMatrixSession(deviceDisplayName: 'Sennit');
  ref.onDispose(session.dispose);
  return session;
});

/// Creates the client and restores a stored session. The app waits on this once
/// at startup; everything downstream reads [sessionStateProvider].
final sessionBootstrapProvider = FutureProvider<WeftSessionState>((ref) async {
  if (kDemoMode) return WeftSessionState.ready;
  return ref.watch(matrixSessionProvider).initialize();
});

/// True while this run's first sync is still on its way.
///
/// The inbox draws from the local database the moment the session restores,
/// which bought the startup its speed at the price of a silence: for the first
/// seconds the screen is last run's state, with nothing saying newer news is
/// coming. This is the sentence that fills the silence, and it ends itself —
/// once the first sync lands, updates stream in live and there is nothing left
/// to announce.
///
/// Yields nothing until the bootstrap resolves, so a build with no session —
/// tests, demo mode — settles on false without ever showing the label.
final catchingUpProvider = StreamProvider<bool>((ref) async* {
  if (!kDemoMode) {
    try {
      await ref.watch(sessionBootstrapProvider.future);
      final client = ref.read(matrixSessionProvider).client;
      final firstSync = client.firstSyncReceived;
      if (firstSync != null) {
        yield true;
        try {
          await firstSync;
        } on Object {
          // The first round failed — offline, or a server mid-restart. The
          // SDK's loop retries on its own; the label comes down with whichever
          // sync eventually lands, because "Updating…" over an inbox that is
          // not updating is worse than no label at all.
          await client.onSync.stream.first;
        }
      }
    } on Object {
      // No session to catch up: logged out, or a build without one.
    }
  }
  yield false;
});

/// This account's other logins, for the devices screen.
///
/// Built lazily, and deliberately not guarded against an uninitialised session:
/// reading it before login is a programming error, and the screen that reads it
/// reports the failure it gets rather than rendering an empty list that would
/// read as "you have no other devices".
///
/// [kDemoMode] is not that case and is why the branch is here. Demo mode never
/// calls `initialize()`, so `session.client` throws — and the screen's honest
/// report of that was a red `ProviderException` where Settings ▸ Devices should
/// be. Every other seam in demo mode is already a fixture; this one is now too.
/// The unguarded real path is unchanged.
final deviceManagerProvider = Provider<DeviceManager>((ref) {
  if (kDemoMode) return DemoDeviceManager();
  return MatrixDeviceManager(ref.watch(matrixSessionProvider).client);
});

/// Cross-signing, the online key backup and the recovery key behind them.
///
/// Same shape and same reasoning as [deviceManagerProvider]: an interface so
/// the security screen can be built against a fake, unguarded so reading it
/// before login fails loudly instead of reporting a healthy empty account, and
/// a fixture in demo mode so Settings ▸ Encryption is a screen rather than a
/// stack trace.
final keyBackupProvider = Provider<KeyBackup>((ref) {
  if (kDemoMode) return DemoKeyBackup();
  return MatrixKeyBackup(ref.watch(matrixSessionProvider).client);
});

/// Live session state. Seeded from the bootstrap result so there is no gap
/// between "restored" and "first state event".
final sessionStateProvider = StreamProvider<WeftSessionState>((ref) async* {
  if (kDemoMode) {
    yield WeftSessionState.ready;
    return;
  }

  final session = ref.watch(matrixSessionProvider);
  yield await ref.watch(sessionBootstrapProvider.future);
  yield* session.states;
});

/// Whether the client holds a usable login right now.
///
/// For providers that build something on top of the signed-in client — the
/// call layer is one. They must watch this, not read `session.isInitialized`:
/// that field turns true when the SDK's `Client` is constructed, which is
/// before a stored login has been restored, and Riverpod never recomputes a
/// provider because a field changed on an object it already returned. A
/// provider that looked once in that window stayed null for the whole run.
///
/// A bool rather than the state itself so that moving between two signed-in
/// states (verifying this device, say) does not rebuild — and so tear down —
/// whatever was built on it.
final sessionSignedInProvider = Provider<bool>((ref) {
  return switch (ref.watch(sessionStateProvider).value) {
    WeftSessionState.unverified || WeftSessionState.ready => true,
    null ||
    WeftSessionState.loggedOut ||
    WeftSessionState.connecting ||
    WeftSessionState.softLoggedOut => false,
  };
});
