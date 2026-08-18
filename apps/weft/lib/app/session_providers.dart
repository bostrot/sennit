import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// Runs the app on in-memory fixtures instead of a homeserver.
///
///     flutter run --dart-define=WEFT_DEMO=true
///
/// Useful for UI work, screenshots and golden tests without credentials.
const bool kDemoMode = bool.fromEnvironment('WEFT_DEMO');

final matrixSessionProvider = Provider<WeftMatrixSession>((ref) {
  final session = WeftMatrixSession();
  ref.onDispose(session.dispose);
  return session;
});

/// Creates the client and restores a stored session. The app waits on this once
/// at startup; everything downstream reads [sessionStateProvider].
final sessionBootstrapProvider = FutureProvider<WeftSessionState>((ref) async {
  if (kDemoMode) return WeftSessionState.ready;
  return ref.watch(matrixSessionProvider).initialize();
});

/// This account's other logins, for the devices screen.
///
/// Built lazily, and deliberately not guarded against an uninitialised session:
/// reading it before login is a programming error, and the screen that reads it
/// reports the failure it gets rather than rendering an empty list that would
/// read as "you have no other devices".
final deviceManagerProvider = Provider<DeviceManager>(
  (ref) => MatrixDeviceManager(ref.watch(matrixSessionProvider).client),
);

/// Cross-signing, the online key backup and the recovery key behind them.
///
/// Same shape and same reasoning as [deviceManagerProvider]: an interface so
/// the security screen can be built against a fake, and unguarded so reading it
/// before login fails loudly instead of reporting a healthy empty account.
final keyBackupProvider = Provider<KeyBackup>(
  (ref) => MatrixKeyBackup(ref.watch(matrixSessionProvider).client),
);

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
