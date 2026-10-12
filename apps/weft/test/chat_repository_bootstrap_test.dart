import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart' show Chat;
import 'package:weft_matrix/weft_matrix.dart';

import 'package:weft/app/providers.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/app/stores.dart';

/// What happens when the inbox is asked for before there is a session.
///
/// It is asked for: a share intent delivered into a cold start, a push, any
/// listener installed above the auth gate. The answer has to be "not yet" —
/// and, crucially, it has to stop being that answer once the session is up.
/// [chatRepositoryProvider] is a plain `Provider`, so a build that threw is
/// kept as its state and rethrown at every later read; before this it was the
/// same session object before and after `initialize()`, so nothing ever marked
/// the provider dirty again and signing in led to a red `ProviderException`
/// where the inbox should be, for the rest of the process.
void main() {
  late Completer<WeftSessionState> bootstrap;
  late WeftStores stores;
  late ProviderContainer container;

  setUp(() {
    bootstrap = Completer<WeftSessionState>();
    stores = WeftStores.inMemory();
    container = ProviderContainer(
      overrides: [
        storesBootstrapProvider.overrideWith((ref) => stores),
        // Never completed by the session itself: the point of these tests is
        // the window between the app's first frame and the session's, so the
        // test opens and closes that window by hand.
        sessionBootstrapProvider.overrideWith((ref) => bootstrap.future),
        // Off the merged inbox's path and a method channel away, so it is not
        // what these tests are measuring.
        smsRepositoryProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(stores.dispose);
  });

  /// The error a read produces, or null when it produced a repository.
  String? errorOf(ProviderContainer container) {
    try {
      container.read(chatRepositoryProvider);
      return null;
    } on Object catch (error) {
      return '$error';
    }
  }

  test('refuses while the session is still starting', () {
    expect(
      errorOf(container),
      contains('before the session finished starting'),
    );
  });

  test('and stops refusing once the bootstrap lands', () async {
    // The regression: this first read is the one that used to decide the fate
    // of the whole run.
    expect(
      errorOf(container),
      contains('before the session finished starting'),
    );

    bootstrap.complete(WeftSessionState.loggedOut);
    await container.read(sessionBootstrapProvider.future);

    // A *different* failure — the session in this container was never
    // initialised, so building the repository reaches the client and says so.
    // Which is the whole point: the provider was rebuilt rather than replaying
    // the refusal above, and a real session would have produced a repository.
    final second = errorOf(container);
    expect(second, isNot(contains('before the session finished starting')));
    expect(second, contains('initialize() has not been called'));
  });

  test('a premature look at the inbox is an empty answer, not a crash', () {
    // What a cold-start share does: it asks whether there are conversations to
    // share into, and holds the payload when there are not. It must get an
    // answer rather than an exception, or the share is lost with the process.
    final chats = container.read(chatsProvider);

    expect(chats.value, isNull);
    expect(chats.hasError, isTrue);
  });

  test('and the inbox is asked again once the session lands', () async {
    // The other half of holding a share: something has to tell the app to look
    // again. `chatsProvider` reaches the session through this provider, so the
    // refusal has to travel back out as a second emission — without it the
    // held payload waits for a signal that never comes and the share is lost
    // with the process after all.
    final emissions = <AsyncValue<List<Chat>>>[];
    container.listen(
      chatsProvider,
      (_, next) => emissions.add(next),
      fireImmediately: true,
    );
    expect(emissions, hasLength(1));

    bootstrap.complete(WeftSessionState.loggedOut);
    await container.read(sessionBootstrapProvider.future);
    await Future<void>.delayed(Duration.zero);

    expect(emissions, hasLength(2));
  });
}
