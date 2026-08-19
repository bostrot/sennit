import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'support/support.dart';

/// Getting into and out of Weft, on a device.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/login_test.dart
///
/// Three things `matrix_session_test.dart` cannot say anything about, because
/// all three are screens:
///
/// 1. **A homeserver is resolved as its own step**, and a refusal is reported
///    where the user is looking. The SDK-level wrong-password case is already
///    covered (`matrix_session_test.dart:110`); what is untested until here is
///    that the sign-in *screen* says so rather than appearing to do nothing.
/// 2. **A device is verified interactively.** This needs two sessions of one
///    account and a dozen round trips between them, and it is the only scenario
///    in the suite whose assertion is a physical act — a person comparing two
///    rows of emoji. The other session is a headless `TestAccount.control` in
///    this process, driven by `SasResponder`.
/// 3. **A sign-out leaves no session behind.** Asserted against the homeserver
///    rather than against the screen: an access token is invisible, and a
///    client that has merely forgotten its own session while the server still
///    honours it looks identical from the app.
///
/// Every scenario is independently runnable. The stored session is a database
/// file that outlives a test, so each one puts the app into the state it needs
/// rather than assuming the previous test left it there.
void main() {
  patrolTest(
    'refuses a wrong password on the screen, then signs in',
    ($) async {
      await ensureSignedOut($);

      final refusal = await signInExpectingRefusal(
        $,
        username: kAppUser,
        password: 'not-the-password',
      );
      expect(
        refusal,
        contains('Incorrect username or password'),
        reason:
            'the screen has to name what went wrong; "Something went wrong" with '
            'an M_FORBIDDEN behind it is how people conclude their account is '
            'broken',
      );

      // The form is still usable afterwards — the refusal is a banner, not a dead
      // end — and the same fields take the right password.
      await signIn($);
      expect(showing(inbox), isTrue);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'verifies this device against another session of the same account',
    ($) async {
      await ensureSignedIn($);

      final control = await TestAccount.control();
      addTearDown(control.dispose);

      // The whole scenario, and it lives in `support/verification.dart` because
      // the notification tests need the same drive for a different reason —
      // they cannot post anything until this device is trusted. Every assertion
      // it makes is this test's: the two ends reach `done`, emoji were shown,
      // and both derived the same ones in the same order.
      await verifyThisDeviceAgainst($, control);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'signing this device out leaves no session behind',
    ($) async {
      final control = await TestAccount.control();
      addTearDown(control.dispose);

      // From a known place, so the device that appears next is unambiguously the
      // one this test signed in.
      await ensureSignedOut($);
      final before = await control.deviceIds();

      await signIn($);
      final appDevice = await newDeviceId(control, before);

      await signOutThisDevice($);
      expect(
        showing(loginScreen),
        isTrue,
        reason: 'the app has to land back on the login screen',
      );

      // The half no screen can show: the homeserver no longer honours that
      // session. A client that had only forgotten its token would look identical
      // from the app's side.
      await pollUntilAsync(
        () async => !(await control.deviceIds()).contains(appDevice),
        reason: 'the homeserver to stop listing device $appDevice',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}
