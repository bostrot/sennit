import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'package:weft/app/session_providers.dart';

/// `sessionSignedInProvider` is what the call layer waits on. It has to turn
/// true when the login becomes usable *after* something already read it —
/// reading a field once at startup is what left calling off for a whole run.
void main() {
  test('turns true when the login lands after the first read', () async {
    final states = StreamController<WeftSessionState>();
    addTearDown(states.close);
    final container = ProviderContainer(
      overrides: [sessionStateProvider.overrideWith((ref) => states.stream)],
    );
    addTearDown(container.dispose);

    final seen = <bool>[];
    container.listen(
      sessionSignedInProvider,
      (_, signedIn) => seen.add(signedIn),
      fireImmediately: true,
    );
    expect(seen, [false], reason: 'nothing restored yet');

    states.add(WeftSessionState.connecting);
    await pumpEventQueue();
    states.add(WeftSessionState.ready);
    await pumpEventQueue();

    expect(seen, [false, true]);
  });

  test('does not rebuild dependants between two signed-in states', () async {
    final states = StreamController<WeftSessionState>();
    addTearDown(states.close);
    final container = ProviderContainer(
      overrides: [sessionStateProvider.overrideWith((ref) => states.stream)],
    );
    addTearDown(container.dispose);

    final seen = <bool>[];
    container.listen(sessionSignedInProvider, (_, v) => seen.add(v));

    states.add(WeftSessionState.unverified);
    await pumpEventQueue();
    states.add(WeftSessionState.ready);
    await pumpEventQueue();
    expect(seen, [true], reason: 'a live call must survive verification');

    states.add(WeftSessionState.softLoggedOut);
    await pumpEventQueue();
    expect(seen, [true, false]);
  });
}
