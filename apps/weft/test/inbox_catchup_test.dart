import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'package:weft/app/session_providers.dart';
import 'package:weft/features/inbox/inbox_shell.dart';

import 'support/golden_harness.dart';

/// The sentence that fills the gap the fast start opened.
///
/// Startup used to hold the splash until the homeserver answered a full sync —
/// thirty seconds of spinner on a bridged account. Now the inbox draws from
/// the local database immediately, which trades that spinner for a silence:
/// the first seconds on screen are last run's state, and nothing said newer
/// news was still on its way. "Updating…" is that sentence, and the promise
/// under test is that it appears only then and takes itself down.
void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('the inbox says it is catching up while it is', (tester) async {
    await pumpWeft(tester, const InboxShell(), catchingUp: true);

    expect(find.text('Updating…'), findsOneWidget);
  });

  testWidgets('and says nothing once it has caught up', (tester) async {
    await pumpWeft(tester, const InboxShell());

    expect(find.text('Updating…'), findsNothing);
  });

  testWidgets('the Mac list toolbar carries the same sentence', (tester) async {
    await pumpWeft(
      tester,
      const InboxShell(),
      surface: WeftSurface.mac,
      catchingUp: true,
    );

    expect(find.text('Updating…'), findsOneWidget);
  });

  // A plain test, not a testWidgets: the provider is real async end to end,
  // and under the widget binding's fake clock its future never resolved — ten
  // minutes of nothing, twice, before this sentence was written.
  test('a logged-out launch settles quietly on false', () async {
    // The bootstrap resolves, there is no client behind it, and reading one
    // throws. The guard turns that into "nothing is catching up" rather than
    // an error — the login screen must not wear an updating label.
    final container = ProviderContainer(
      overrides: [
        sessionBootstrapProvider.overrideWith(
          (ref) async => WeftSessionState.loggedOut,
        ),
      ],
    );
    addTearDown(container.dispose);

    // Listened, not just read: Riverpod pauses a provider nobody listens to,
    // and a paused stream's future waits forever.
    container.listen(catchingUpProvider, (_, _) {});
    final value = await container
        .read(catchingUpProvider.future)
        .timeout(const Duration(seconds: 5));
    expect(value, isFalse);
  });
}
