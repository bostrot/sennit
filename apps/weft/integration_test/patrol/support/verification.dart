/// Making this device trusted, and with it making the session `ready`.
///
/// Two scenarios need it and they need it for opposite reasons. `login_test`
/// verifies a device because verifying is the thing under test — a person
/// comparing two rows of emoji, which is the only assertion in the suite whose
/// subject is a physical act. The notification scenarios verify because they
/// have no choice: `main.dart:299-315` starts the notification service on
/// `WeftSessionState.ready` and on nothing else, and a device that skipped
/// verification never reaches it.
///
/// > **Verifying against a second session is not, by itself, enough**, and this
/// > is the trap the file exists to hold. `needsVerification`
/// > (`session.dart:226-235`) asks whether *our own* device key reads as
/// > `verified`, while SAS marks the keys the **other** end sent
/// > (`key_verification.dart:786`) — never one's own. `DeviceKeys.verified` is
/// > `directVerified || crossVerified`, so on an account with no cross-signing
/// > identity neither half can ever become true and the device stays
/// > `unverified` for good. [makeSessionReady] mints the identity on the helper
/// > session first; the SAS then signs *this* device into it, which is the only
/// > route to `ready` that exists.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:weft/features/auth/verification_screen.dart';
import 'package:weft_matrix/weft_matrix.dart' show KeyVerificationState;

import 'accounts.dart';
import 'app.dart';
import 'environment.dart';

/// Signs the app in and leaves it on an inbox whose session has reached
/// `ready`.
///
/// [helper] is a second session of the app's own account — `TestAccount.control`
/// — and it does two things here that the app cannot do for itself: it holds the
/// cross-signing identity's private half, and it is the other end of the emoji
/// comparison.
///
/// Three steps, and the third is the one that is easy to leave out. Nothing
/// re-derives the session state after a verification: `_emit(_deriveState())` is
/// called from `initialize()` and from the login-state stream and from nowhere
/// else (`session.dart:114,186,202`), so a device that becomes verified while
/// the app is running stays `unverified` as far as every listener is concerned.
/// The relaunch is what turns the new trust into a `ready` the notification
/// service actually hears.
///
/// Idempotent, and cheaply so: the devices list is read first, and a device that
/// is already verified skips the identity, the comparison and the relaunch. That
/// matters because five scenarios in this suite call it and the work it skips is
/// two homeserver round trips and a full app restart.
Future<void> makeSessionReady(
  PatrolIntegrationTester $, {
  required TestAccount helper,
}) async {
  await ensureSignedIn($, wantsNotifications: true);

  await openDevicesList($);
  final alreadyVerified = deviceIsVerified(thisDeviceTile);
  await leaveSettingsScreen($);
  if (alreadyVerified) return;

  // Before the comparison, not after: the MAC the app receives has to carry a
  // master key for the app to verify, and the signature that ends up on the
  // app's own device is written by this session out of a private half it can
  // only have if it minted it.
  await helper.enableCrossSigning();

  await verifyThisDeviceAgainst($, helper);

  // The restart, for the reason in this function's header. Not through
  // `ensureSignedIn`: that passes the verification gate before returning, and
  // whether the gate is still being offered is precisely the assertion.
  await launchWeft($);
  await pumpUntil(
    $,
    () => showing(inbox) || showing(verificationGate),
    within: kSignInDeadline,
    reason: 'the restarted app to decide what this session is',
  );
  expect(
    showing(verificationGate),
    isFalse,
    reason:
        'this device was verified and the app was restarted, so the session '
        'should have derived ready. Still being offered the verification gate '
        "means its own device key did not become verified — the account's "
        'cross-signing identity is the thing to look at, not the emoji',
  );
  await answerNotificationRationale($, wanted: true, within: kUiDeadline);
}

/// Drives an interactive verification of this device against [helper], from the
/// devices screen, and asserts both ends agreed.
///
/// The app is the initiator and is worked through its own screens; [helper] has
/// no screen and is driven by [SasResponder]. Written as its own function
/// because `login_test` asserts on it as a feature and the notification
/// scenarios only need it to have happened.
Future<void> verifyThisDeviceAgainst(
  PatrolIntegrationTester $,
  TestAccount helper,
) async {
  await openDevicesList($);

  // The other device has to be visible to this one before it can be verified:
  // its keys arrive over sync like everything else.
  await pumpUntil(
    $,
    () => showing(find.text(kControlDeviceName)),
    within: kSyncDeadline,
    reason: 'the helper session to appear in the devices list',
  );

  // Subscribed before the app is told to start, and deliberately not awaited
  // yet: the request is sent by the tap below, and a listener attached
  // afterwards would miss it.
  final pendingResponder = SasResponder.awaitRequest(helper);

  final tile = deviceTile(kControlDeviceName);
  await chooseDeviceAction($, tile, 'Verify');
  await $.tap(find.text('Start verification'));

  final responder = await pendingResponder;
  final shownEmoji = await compareEmojiOnScreen($);

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
    () => deviceIsVerified(tile),
    within: kSyncDeadline,
    reason: 'the devices list to show the helper session as verified',
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
Future<List<String>> compareEmojiOnScreen(
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
      names = sasEmojiNames($);
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
List<String> sasEmojiNames(PatrolIntegrationTester $) => [
  for (final element in find.byType(SasEmojiCell).evaluate())
    (element.widget as SasEmojiCell).name,
];
