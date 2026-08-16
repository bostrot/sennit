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
