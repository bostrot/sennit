import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:weft/features/auth/verification_screen.dart';
import 'package:weft_matrix/weft_matrix.dart' show KeyVerificationState;

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

      // The other device has to be visible to this one before it can be verified:
      // its keys arrive over sync like everything else.
      await openInboxMenu($, 'Devices');
      await pumpUntil(
        $,
        () => showing(find.text(kControlDeviceName)),
        within: kSyncDeadline,
        reason: 'the helper session to appear in the devices list',
      );

      // Subscribed before the app is told to start, and deliberately not awaited
      // yet: the request is sent by the tap below, and a listener attached
      // afterwards would miss it.
      final pendingResponder = SasResponder.awaitRequest(control);

      final tile = find.ancestor(
        of: find.text(kControlDeviceName),
        matching: find.byType(ListTile),
      );
      await $.tap(
        find.descendant(
          of: tile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await $.tap(find.text('Verify'));
      await $.tap(find.text('Start verification'));

      final responder = await pendingResponder;
      final shownEmoji = await _compareEmojiOnScreen($);

      expect(
        await responder.finished,
        KeyVerificationState.done,
        reason: 'the other device has to reach done, not error',
      );
      expect(
        shownEmoji,
        isNotEmpty,
        reason:
            'the emoji comparison is the whole of what the user is asked to do; a '
            'flow that reached done without showing any is a flow that verified '
            'without asking',
      );
      expect(
        shownEmoji,
        responder.emojiNames,
        reason:
            'both ends must have derived the same short authentication string, in '
            'the same order — that is what the comparison proves',
      );

      // Back to the list, which is where a user would go to check.
      await $.tap(find.text('Continue'));
      await pumpUntil(
        $,
        () =>
            showing(find.descendant(of: tile, matching: find.text('Verified'))),
        within: kSyncDeadline,
        reason: 'the devices list to show the helper session as verified',
      );
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

/// Drives the app's half of an interactive verification, returning the emoji
/// names it was shown.
///
/// A loop over what is on screen rather than a fixed sequence of taps, because
/// the two ends advance each other: which step the app is on depends on what the
/// other device has just done, and the SDK deliberately skips the choice step
/// when only one method is possible. Each action is taken at most once — a
/// second `acceptSas` is a cancelled verification, not a no-op.
Future<List<String>> _compareEmojiOnScreen(
  PatrolIntegrationTester $, {
  Duration? within,
}) async {
  const success = 'This device is verified. Your history is unlocking now.';
  const failure = 'Verification failed or was cancelled.';

  final limit = within ?? kSyncDeadline;
  final deadline = DateTime.now().add(limit);
  var names = const <String>[];
  var chose = false;
  var accepted = false;

  while (DateTime.now().isBefore(deadline)) {
    if (showing(find.text(success))) return names;
    if (showing(find.text(failure))) fail('The app reported: $failure');

    if (!accepted && showing(find.text('They match'))) {
      // Read before tapping: the cells are gone the moment the state moves on,
      // and the names are what the two ends are being compared on.
      names = _sasEmojiNames($);
      await $.tap(find.text('They match'));
      accepted = true;
      continue;
    }
    if (!chose && showing(find.text('Compare emoji instead'))) {
      await $.tap(find.text('Compare emoji instead'));
      chose = true;
      continue;
    }
    if (!chose && showing(find.text('Compare emoji'))) {
      await $.tap(find.text('Compare emoji'));
      chose = true;
      continue;
    }
    await $.pump(const Duration(milliseconds: 200));
  }
  fail(
    'The verification never completed within ${limit.inSeconds}s '
    '(chose a method: $chose, confirmed the emoji: $accepted)',
  );
}

/// The names under the emoji currently on screen, in order.
///
/// `SasEmojiCell` is public for exactly this kind of reach: a `KeyVerification`
/// cannot be built without a live client, so the screen around it cannot be
/// pumped in a widget test at all.
List<String> _sasEmojiNames(PatrolIntegrationTester $) => [
  for (final element in find.byType(SasEmojiCell).evaluate())
    (element.widget as SasEmojiCell).name,
];
