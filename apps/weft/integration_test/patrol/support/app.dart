/// Driving Weft itself: launching it, signing in and out, opening a
/// conversation, sending, and reading back what the screen says.
///
/// Everything here goes through the app's own UI. That is the whole point of
/// the suite — a repository call from a test proves the repository, not the
/// screen — so nothing in this file reaches into a provider or a session to make
/// something happen. It reaches into exactly one thing that is not a pixel: the
/// *accessible name* of a widget, which is a surface the a11y phase deliberately
/// built and is the only place several of Weft's states exist in words at all. A
/// delivery tick is a 13dp glyph whose "delivered" and "read" forms differ only
/// in colour; the label beside it is what a test — and a screen reader — can
/// actually read.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:weft/features/settings/settings_section.dart';
import 'package:weft/main.dart' as app;
import 'package:weft_design/weft_design.dart';

import 'environment.dart';

// ---------------------------------------------------------------- primitives

/// Whether anything currently on screen matches [finder].
///
/// `skipOffstage` stays at its default: a route pushed over the inbox puts the
/// inbox in the overlay's offstage children, and a phone row must not match a
/// chat tile that is behind the conversation it opened.
bool showing(Finder finder) => finder.evaluate().isNotEmpty;

/// Pumps frames until [ready] holds, or fails saying what it was waiting for.
///
/// The suite's basic wait. `pumpAndSettle` cannot serve here for two reasons:
/// Weft has legitimately infinite animations on screen during startup and
/// sending, so settling is not a state it reaches; and the thing being waited
/// for is usually a homeserver round trip rather than an animation, which no
/// number of frames brings closer. Pumping is what lets both the frame loop and
/// the network make progress on a live binding.
Future<void> pumpUntil(
  PatrolIntegrationTester $,
  bool Function() ready, {
  required String reason,
  Duration? within,
  Duration interval = const Duration(milliseconds: 100),
}) async {
  final limit = within ?? kUiDeadline;
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (ready()) return;
    await $.pump(interval);
  }
  if (ready()) return;
  fail('Timed out after ${limit.inSeconds}s waiting for $reason');
}

// --------------------------------------------------------------- the screens

/// The login screen's wordmark tagline.
///
/// Deliberately not "Weft", which is also the window title and the default
/// device name, and deliberately not the empty detail pane's *"Every network,
/// one thread."* — the two straplines differ by one word and the wrong one would
/// make a signed-in two-pane window read as signed out.
final Finder loginScreen = find.text('Every conversation, one thread.');

/// The inbox header. Only shown with no rail filter applied, which is how every
/// scenario starts.
final Finder inbox = find.text('Conversations');

/// The auth gate's verification step, shown after a login on a device the
/// account has never verified.
final Finder verificationGate = find.text('Continue without verifying');

/// The sign-in error banner, by the accessible name that is its whole purpose.
///
/// `_ErrorBanner` is private and its message is one `Text` among several on the
/// screen; the banner's own node is a live region labelled
/// `'Sign-in failed. '` followed by the message, which is unambiguous and
/// carries the message with it.
final Finder signInFailure = find.bySemanticsLabel(
  RegExp(r'^Sign-in failed\.'),
);

/// The message bubbles currently on screen.
///
/// A bubble is the one `WeftFocusable` Weft builds with `button: false` — it is
/// a *group* naming who spoke rather than a control, because the links and
/// mention pills in the body have to stay individually reachable. An inbox row
/// is a control, so this tells the two apart on a two-pane window where both are
/// on screen and both contain the same words, without either growing a
/// test-only key.
final Finder messageBubbles = find.byWidgetPredicate(
  (widget) => widget is WeftFocusable && !widget.button,
);

/// The bubble whose body is exactly [body].
///
/// Deliberately not narrowed with `.first`: a `first` finder throws rather than
/// coming back empty when nothing matches, and every wait in this file asks
/// "is it there yet?" of a finder that is usually not there yet. Narrowing
/// belongs at the tap, where something has already been seen.
Finder bubbleFor(String body) =>
    find.ancestor(of: find.text(body), matching: messageBubbles);

// ------------------------------------------------------------------ lifecycle

bool _launchedBefore = false;

/// Starts Weft, exactly as the launcher would.
///
/// `main()` rather than pumping `WeftApp` directly: `main` awaits
/// `initializeDateFormatting()` before `runApp`, and every row of the inbox
/// formats a timestamp on its first frame — a `DateFormat` built for a locale
/// whose data has not arrived throws. Pumping the widget would skip that and
/// produce a crash the app does not have.
Future<void> launchWeft(PatrolIntegrationTester $) async {
  if (_launchedBefore) await Future<void>.delayed(kRelaunchGrace);
  _launchedBefore = true;

  // Not awaited, and it cannot be: `main` is declared `void`. It reaches
  // `runApp` a microtask later, which the pump below is waiting for.
  app.main();

  await pumpUntil(
    $,
    () => showing(find.byType(app.WeftApp)),
    within: kUiDeadline,
    reason: 'Weft to build its first frame',
  );
  await $.pumpAndTrySettle();
}

/// Launches Weft and leaves it on the inbox, signing in if it has to.
///
/// The stored session outlives a test — it is a database file in the app's own
/// support directory, and only a sign-out removes it — so a scenario cannot
/// assume either state. This is what makes each file independently runnable:
/// run `messaging_test.dart` alone and it signs in; run it after `login_test`
/// and it finds a session already there.
Future<void> ensureSignedIn(
  PatrolIntegrationTester $, {
  String username = kAppUser,
  String password = kTestPassword,
}) async {
  await launchWeft($);
  await pumpUntil(
    $,
    () => showing(loginScreen) || showing(verificationGate) || showing(inbox),
    within: kSignInDeadline,
    reason: 'Weft to decide whether it already has a session',
  );

  if (showing(loginScreen)) {
    await signIn($, username: username, password: password);
    return;
  }
  await passVerificationGate($);
  await dismissNotificationRationale($);
}

/// Launches Weft and leaves it on the login screen, signing out if it has to.
Future<void> ensureSignedOut(PatrolIntegrationTester $) async {
  await launchWeft($);
  await pumpUntil(
    $,
    () => showing(loginScreen) || showing(verificationGate) || showing(inbox),
    within: kSignInDeadline,
    reason: 'Weft to decide whether it already has a session',
  );
  if (showing(loginScreen)) return;

  await passVerificationGate($);
  await dismissNotificationRationale($);
  await signOutThisDevice($);
}

/// Resolves the homeserver, then signs in, from the login screen.
///
/// Two steps and not one, because that is what the screen does: the server is
/// validated on its own so that a wrong address is never reported as a wrong
/// password.
Future<void> signIn(
  PatrolIntegrationTester $, {
  String username = kAppUser,
  String password = kTestPassword,
  String homeserver = kHomeserver,
}) async {
  await _resolveHomeserver($, homeserver);
  await _submitCredentials($, username, password);

  await pumpUntil(
    $,
    () => showing(inbox) || showing(verificationGate) || showing(signInFailure),
    within: kSignInDeadline,
    reason: 'the sign-in to resolve',
  );
  _failOnSignInError($, 'signing $username in');

  await passVerificationGate($);
  await dismissNotificationRationale($);
}

/// Resolves [homeserver] on the login screen, unless it already is.
///
/// The idempotence matters: a refused sign-in leaves the screen with the server
/// resolved and the address field *disabled*, and typing into a disabled field
/// is not something a user can do — so a second attempt has to pick up where the
/// first one left off, exactly as a person would.
Future<void> _resolveHomeserver(
  PatrolIntegrationTester $,
  String homeserver,
) async {
  await pumpUntil(
    $,
    () => showing(loginScreen),
    within: kUiDeadline,
    reason: 'the login screen',
  );
  if (find.byType(TextField).evaluate().length >= 3) return;

  // The fields are found by position and it is stable by construction: the form
  // renders one `TextField` until the server resolves and three afterwards, in
  // the order server, username, password. There is no other `TextField` on the
  // screen — the inbox's search box is an `InputDecorator` with nothing in it,
  // precisely so it does not announce itself as somewhere to type.
  await $.enterText(find.byType(TextField).first, homeserver);
  await $.tap(find.text('Continue'));

  await pumpUntil(
    $,
    () =>
        find.byType(TextField).evaluate().length >= 3 || showing(signInFailure),
    within: kSyncDeadline,
    reason: 'the homeserver $homeserver to resolve',
  );
  _failOnSignInError($, 'resolving $homeserver');
}

Future<void> _submitCredentials(
  PatrolIntegrationTester $,
  String username,
  String password,
) async {
  await $.enterText(find.byType(TextField).at(1), username);
  await $.enterText(find.byType(TextField).at(2), password);
  await $.tap(find.text('Sign in'));
}

/// Attempts a sign-in that is expected to be refused, and returns what the
/// screen said about it.
///
/// The refusal is the assertion, so this returns rather than failing: the
/// wrong-password path is already covered against the SDK by
/// `matrix_session_test.dart`, and what this suite adds is that the *screen*
/// says so.
Future<String> signInExpectingRefusal(
  PatrolIntegrationTester $, {
  required String username,
  required String password,
  String homeserver = kHomeserver,
}) async {
  await _resolveHomeserver($, homeserver);
  await _submitCredentials($, username, password);

  await pumpUntil(
    $,
    () => showing(signInFailure),
    within: kSignInDeadline,
    reason: 'the sign-in to be refused on screen',
  );
  return signInFailureMessage($)!;
}

/// What the sign-in error banner currently says, or null when there is none.
String? signInFailureMessage(PatrolIntegrationTester $) {
  if (!showing(signInFailure)) return null;
  // The label is "Sign-in failed. <message>"; the caller wants the message.
  final label = $.tester.getSemantics(signInFailure.first).label;
  return label.replaceFirst(RegExp(r'^Sign-in failed\.\s*'), '');
}

void _failOnSignInError(PatrolIntegrationTester $, String what) {
  final message = signInFailureMessage($);
  if (message != null) fail('Weft refused while $what: $message');
}

/// Skips the verification step if the gate is showing it.
///
/// Skipped rather than performed, everywhere except `login_test`'s verification
/// scenario. Verifying needs a second device of the same account and several
/// round trips, and a scenario about sending a message should not carry that.
/// The consequence is stated rather than hidden: the session stays in Weft's
/// `unverified` state until something verifies it, and `main.dart` starts the
/// notification service only on `ready` — so an unverified Weft never registers
/// a pusher at all. That is a real gap, and it belongs to the notification
/// scenarios rather than to this helper.
Future<void> passVerificationGate(PatrolIntegrationTester $) async {
  if (showing(verificationGate)) await $.tap(verificationGate);
  await pumpUntil(
    $,
    () => showing(inbox),
    within: kSyncDeadline,
    reason: 'the inbox',
  );
}

/// Dismisses the notification rationale sheet if it appears.
///
/// It is shown once per install, before the OS permission dialog, and it is
/// modal — so a scenario that ignored it would fail on its next tap with a
/// message about the wrong widget. Bounded and optional because it genuinely
/// may not appear at all: it is gated on the platform needing a runtime
/// permission, on the prompt never having been spent, *and* on the session
/// reaching `ready`, which a device that has skipped verification never does.
Future<void> dismissNotificationRationale(
  PatrolIntegrationTester $, {
  Duration within = const Duration(seconds: 5),
}) async {
  final headline = find.text('Get told when someone writes');
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (showing(headline)) {
      await $.tap(find.text('Not now'));
      return;
    }
    await $.pump(const Duration(milliseconds: 100));
  }
}

/// Signs the current device out through the devices screen.
///
/// The only way out of a session in Weft's UI: there is no "sign out" in a menu.
/// The devices list is where every session on the account is, and the one marked
/// *This device* is this one — which is what makes it findable without knowing
/// the device id, and correct on an account that has accumulated half a dozen
/// sessions called "Weft" from earlier runs.
Future<void> signOutThisDevice(
  PatrolIntegrationTester $, {
  String password = kTestPassword,
}) async {
  await openInboxMenu($, 'Devices');
  await pumpUntil(
    $,
    () => showing(find.text('This device')),
    within: kSyncDeadline,
    reason: 'the devices list to load',
  );

  final tile = find
      .ancestor(of: find.text('This device'), matching: find.byType(ListTile))
      .first;
  await $.tap(
    find.descendant(of: tile, matching: find.byType(PopupMenuButton<String>)),
  );
  await $.tap(find.text('Sign out'));
  await $.tap(find.widgetWithText(FilledButton, 'Sign out'));

  // Synapse puts device deletion behind user-interactive auth, so the password
  // prompt is the normal path rather than an edge case. Waited for rather than
  // assumed: a homeserver configured without UIA would go straight out.
  await pumpUntil(
    $,
    () => showing(find.byType(TextPromptDialog)) || showing(loginScreen),
    within: kSyncDeadline,
    reason: 'the re-authentication prompt, or the sign-out to complete',
  );
  if (showing(find.byType(TextPromptDialog))) {
    await $.enterText(
      find.descendant(
        of: find.byType(TextPromptDialog),
        matching: find.byType(TextField),
      ),
      password,
    );
    await $.tap(find.text('Confirm'));
  }

  await pumpUntil(
    $,
    () => showing(loginScreen),
    within: kSyncDeadline,
    reason: 'Weft to return to the login screen',
  );
}

// ------------------------------------------------------------------ the inbox

/// Opens an entry of the inbox's overflow menu.
Future<void> openInboxMenu(PatrolIntegrationTester $, String entry) async {
  await $.tap(find.byTooltip('More'));
  await $.tap(find.text(entry));
}

/// Opens the conversation titled [title], waiting for it to arrive first.
///
/// The wait is the important half. A room created moments ago reaches the app
/// through sync, and on a cold emulator that is seconds after the test asked
/// for it.
Future<void> openChat(PatrolIntegrationTester $, String title) async {
  await pumpUntil(
    $,
    () => showing(find.text(title)),
    within: kSyncDeadline,
    reason: 'the conversation "$title" to appear in the inbox',
  );
  await $.tap(find.text(title).first);
  await pumpUntil(
    $,
    () => showing(composerField),
    within: kUiDeadline,
    reason: 'the conversation "$title" to open',
  );
}

/// Where the chat's ranked position in the inbox can be read.
///
/// Returns the visible conversation titles in the order the inbox draws them,
/// which is what "the recipient's inbox reorders" is a statement about. Read off
/// the rows themselves rather than off a provider, so a sort that is correct in
/// the model and wrong on screen still fails.
List<String> inboxOrder(PatrolIntegrationTester $, List<String> titles) {
  final positions = <String, double>{};
  for (final title in titles) {
    final rows = find
        .ancestor(of: find.text(title), matching: find.byType(ChatTile))
        .evaluate();
    if (rows.isEmpty) continue;
    positions[title] = $.tester.getTopLeft(find.byWidget(rows.first.widget)).dy;
  }
  final ordered = positions.keys.toList()
    ..sort((a, b) => positions[a]!.compareTo(positions[b]!));
  return ordered;
}

// ------------------------------------------------------------ a conversation

/// Every text field on screen, which in an open conversation is the composer.
///
/// The composer is the *last* of them, and that is not a coincidence: the panes
/// are laid out rail, inbox, conversation, so on a two-pane window the
/// conversation is the last of the three and the inbox contributes no field at
/// all — its search box is an `InputDecorator` with nothing inside it. The
/// narrowing is applied where the field is typed into rather than here, because
/// a `last` finder throws instead of coming back empty and this one is waited on
/// before it exists.
final Finder composerField = find.byType(TextField);

/// Types [text] into the composer and sends it.
Future<void> sendFromComposer(PatrolIntegrationTester $, String text) async {
  await $.enterText(composerField.last, text);
  await $.tap(find.byTooltip('Send'));
}

/// Waits for a message with [body] to be drawn in the open conversation.
Future<void> awaitBubble(
  PatrolIntegrationTester $,
  String body, {
  Duration? within,
}) => pumpUntil(
  $,
  () => showing(bubbleFor(body)),
  within: within ?? kSyncDeadline,
  reason: 'the message "$body" to appear in the conversation',
);

/// Waits for [body] to *stop* being drawn — a redaction replacing it.
Future<void> awaitNoBubble(
  PatrolIntegrationTester $,
  String body, {
  Duration? within,
}) => pumpUntil(
  $,
  () => !showing(bubbleFor(body)),
  within: within ?? kSyncDeadline,
  reason: 'the message "$body" to disappear from the conversation',
);

/// The metadata line under [body]'s bubble, as a screen reader hears it.
///
/// "Sent 14:32, Delivered". The time and the tick are one node by design: a
/// delivery state is otherwise a 13dp glyph whose delivered and read forms
/// differ only in colour, which is the one distinction a colour-blind reader
/// cannot make and no test can assert on.
String? metaLabelFor(PatrolIntegrationTester $, String body) {
  final meta = find.descendant(
    of: bubbleFor(body),
    matching: find.bySemanticsLabel(RegExp(r'^Sent ')),
  );
  if (!showing(meta)) return null;
  return $.tester.getSemantics(meta.first).label;
}

/// [body]'s delivery state in the word the app uses for it, or null.
///
/// One of Sending, Sent, Delivered, Read or Not sent — `deliveryStateLabel` in
/// `weft_design` is the single source of those words, which is what keeps this
/// from drifting into a vocabulary of the test's own.
String? deliveryStateFor(PatrolIntegrationTester $, String body) {
  final label = metaLabelFor($, body);
  if (label == null) return null;
  final comma = label.indexOf(', ');
  return comma < 0 ? null : label.substring(comma + 2);
}

/// Watches [body]'s delivery state until it reaches [target], and reports every
/// state it passed through on the way.
///
/// The states are collected rather than asserted one by one for a reason worth
/// stating: against a homeserver on the same machine, `Sending` can be over
/// before the next frame, so a test that demanded to *see* it would fail on a
/// fast server and pass on a slow one. What is asserted instead is that the
/// sequence only ever moves forward and ends where it should, which is a claim
/// a broken send cannot satisfy however fast the server is.
Future<List<String>> observeDeliveryStates(
  PatrolIntegrationTester $,
  String body, {
  String target = 'Delivered',
  Duration? within,
}) async {
  final seen = <String>[];
  final limit = within ?? kSyncDeadline;
  final deadline = DateTime.now().add(limit);

  while (DateTime.now().isBefore(deadline)) {
    final state = deliveryStateFor($, body);
    if (state != null && (seen.isEmpty || seen.last != state)) seen.add(state);
    if (state == target) return seen;
    await $.pump(const Duration(milliseconds: 50));
  }
  fail(
    'The message "$body" never reached "$target" within ${limit.inSeconds}s. '
    'Seen: ${seen.isEmpty ? '<no bubble>' : seen.join(' → ')}',
  );
}

/// Long-presses [body]'s bubble and waits for the actions sheet.
Future<void> openMessageActions(PatrolIntegrationTester $, String body) async {
  await $.longPress(bubbleFor(body));
  await pumpUntil(
    $,
    () => showing(find.text('Reply')),
    within: kUiDeadline,
    reason: 'the message actions sheet for "$body"',
  );
}

/// Long-presses [body] and chooses [action] from the sheet.
Future<void> chooseMessageAction(
  PatrolIntegrationTester $,
  String body,
  String action,
) async {
  await openMessageActions($, body);
  await $.tap(find.text(action));
}
