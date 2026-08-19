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
///
/// [wantsNotifications] is the answer given to the rationale sheet if it turns
/// up. False — *Not now* — for every scenario that is not about notifications,
/// because the sheet is modal and the OS prompt behind it is spent exactly once
/// per install; the notification scenarios pass true, which is the only way this
/// suite ever gets the permission. See [answerNotificationRationale].
Future<void> ensureSignedIn(
  PatrolIntegrationTester $, {
  String username = kAppUser,
  String password = kTestPassword,
  bool wantsNotifications = false,
}) async {
  await launchWeft($);
  await pumpUntil(
    $,
    () => showing(loginScreen) || showing(verificationGate) || showing(inbox),
    within: kSignInDeadline,
    reason: 'Weft to decide whether it already has a session',
  );

  if (showing(loginScreen)) {
    await signIn(
      $,
      username: username,
      password: password,
      wantsNotifications: wantsNotifications,
    );
    return;
  }
  await passVerificationGate($);
  await answerNotificationRationale($, wanted: wantsNotifications);
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
  bool wantsNotifications = false,
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
  await answerNotificationRationale($, wanted: wantsNotifications);
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
}) => answerNotificationRationale($, wanted: false, within: within);

/// The rationale sheet's headline, which is the only text on it that is
/// unambiguously its own.
final Finder notificationRationale = find.text('Get told when someone writes');

/// Answers the rationale sheet if it appears, and says whether it did.
///
/// [wanted] true taps *Turn on notifications*, which is what spends the OS
/// prompt — `main.dart:229-243` shows the system dialog only on that answer, and
/// only once ever, because `WeftSettings.notifyPermissionAsked` records that the
/// one prompt an app gets has been used. False taps *Not now*, which costs
/// nothing and leaves the prompt unspent.
///
/// Bounded and optional because the sheet genuinely may not appear: it is gated
/// on the platform needing a runtime permission, on the prompt never having been
/// spent, *and* on the session reaching `ready`. Returning false is therefore
/// information rather than a failure — the caller decides whether a device that
/// was never asked is a device that already holds the permission or one that
/// never got as far as asking.
Future<bool> answerNotificationRationale(
  PatrolIntegrationTester $, {
  required bool wanted,
  Duration within = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (showing(notificationRationale)) {
      await $.tap(find.text(wanted ? 'Turn on notifications' : 'Not now'));
      return true;
    }
    await $.pump(const Duration(milliseconds: 100));
  }
  return false;
}

// ---------------------------------------------------------- the devices list

/// Opens the devices screen and waits for the list to arrive.
///
/// *This device* is always in it, so it is what the wait is for: an empty
/// `ListView` and a list still being fetched look identical.
Future<void> openDevicesList(PatrolIntegrationTester $) async {
  await openInboxMenu($, 'Devices');
  await pumpUntil(
    $,
    () => showing(find.text('This device')),
    within: kSyncDeadline,
    reason: 'the devices list to load',
  );
}

/// The row for the session this app is signed in on.
///
/// Found by the *This device* chip rather than by a device id or a name: the id
/// is not known to a test that did not watch the login, and an account this
/// suite has run against a few times holds several sessions all called "Weft".
Finder get thisDeviceTile => find
    .ancestor(of: find.text('This device'), matching: find.byType(ListTile))
    .first;

/// The row for another session, by the name it gave itself.
Finder deviceTile(String deviceName) =>
    find.ancestor(of: find.text(deviceName), matching: find.byType(ListTile));

/// Whether the devices list is currently calling [tile] verified.
///
/// The word rather than the icon: `trustLabel` in `devices.dart` is the single
/// source of *Verified* / *Not verified*, and the icon beside it differs only in
/// colour. For [thisDeviceTile] this is exactly the gate
/// `WeftMatrixSession.needsVerification` opens — `DeviceTrust` is computed from
/// the same `DeviceKeys.verified` — which makes it the one place in the UI where
/// a test can read whether the session will ever reach `ready`.
bool deviceIsVerified(Finder tile) =>
    showing(find.descendant(of: tile, matching: find.text('Verified')));

/// Waits until the devices list calls [deviceName] verified, scrolling to find
/// it.
///
/// The scroll is not a convenience, and leaving it out is a wrong-answer bug
/// rather than a flake. Two facts about the screen combine:
///
/// 1. `ListView(children: ...)` builds a `SliverChildListDelegate`, so only the
///    rows inside the viewport exist as elements at all. `showing` reads
///    `Finder.evaluate()`, which cannot see a row that was never built.
/// 2. `sortDevices` puts everything that `needsAttention` above everything that
///    does not (`devices.dart:152`), and *verified* is the one trust state that
///    does not need attention.
///
/// So verifying a device **moves it down past every unverified session on the
/// account** — and this suite leaves one behind per run, so that is a dozen and
/// counting on a homeserver a few runs old. Observed against the live emulator:
/// the helper row was on screen before the verification and off the built range
/// after it, which made a name-anchored finder match nothing and read exactly
/// like a verification that never took. The trust was correct the whole time.
///
/// Polled rather than scrolled once, because the reload that re-sorts the list
/// is the async `_load()` the verification screen runs after it pops.
Future<void> pumpUntilDeviceVerified(
  PatrolIntegrationTester $,
  String deviceName, {
  Duration? within,
  required String reason,
}) async {
  final label = find.text(deviceName);
  final deadline = DateTime.now().add(within ?? kSyncDeadline);

  while (DateTime.now().isBefore(deadline)) {
    if (deviceIsVerified(deviceTile(deviceName))) return;
    if (!showing(label)) {
      try {
        await $.scrollUntilVisible(finder: label, maxScrolls: 40);
      } on Object {
        // Not in the list yet, or not yet where the sort will leave it. The
        // next turn of the loop looks again; the deadline is what gives up.
      }
    }
    await $.pump(const Duration(milliseconds: 200));
  }

  fail(
    'Timed out after ${(within ?? kSyncDeadline).inSeconds}s waiting for '
    '$reason. The row for "$deviceName" '
    '${showing(label) ? 'is on screen and does not say Verified' : 'was not '
              'found even after scrolling the list'}.',
  );
}

/// Opens the actions menu of a device row and chooses [entry].
Future<void> chooseDeviceAction(
  PatrolIntegrationTester $,
  Finder tile,
  String entry,
) async {
  await $.tap(
    find.descendant(of: tile, matching: find.byType(PopupMenuButton<String>)),
  );
  await $.tap(find.text(entry));
}

/// Leaves the screen the inbox menu pushed, back to the inbox.
///
/// The `AppBar`'s own back button, by the tooltip `MaterialLocalizations` gives
/// it — not the platform's Back, which on Android would also be the way out of
/// the app itself if the route stack were shorter than expected.
Future<void> leaveSettingsScreen(PatrolIntegrationTester $) async {
  await $.tap(find.byTooltip('Back'));
  await pumpUntil(
    $,
    () => showing(inbox),
    within: kUiDeadline,
    reason: 'the inbox after leaving a settings screen',
  );
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
  await openDevicesList($);

  await chooseDeviceAction($, thisDeviceTile, 'Sign out');
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

/// Mutes the conversation titled [title] the way the inbox offers it.
///
/// Long-press to enter selection, then the *Mute* button in the selection bar.
/// That is `ChatRepository.setMuted`, which writes a `dont_notify` push rule on
/// every source room of the chat — so what is exercised is the whole loop the
/// mute rides on: the rule reaches the homeserver, comes back through sync,
/// `MatrixChatRepository._chatFromRoom` reads it off `room.pushRuleState` into
/// `Chat.muted`, and `evaluateNotification` suppresses on that. Setting a flag
/// would test none of it.
///
/// The wait at the end is for the selection to clear, which `_SelectionBar._apply`
/// does once every selected chat has been through the action — so it is also the
/// wait for the homeserver having answered.
Future<void> muteChatFromInbox(PatrolIntegrationTester $, String title) async {
  await pumpUntil(
    $,
    () => showing(find.text(title)),
    within: kSyncDeadline,
    reason: 'the conversation "$title" to appear in the inbox',
  );
  await $.longPress(find.text(title).first);
  await pumpUntil(
    $,
    () => showing(find.byTooltip('Mute')),
    within: kUiDeadline,
    reason: 'the inbox selection bar',
  );
  await $.tap(find.byTooltip('Mute'));
  await pumpUntil(
    $,
    () => !showing(find.byTooltip('Mute')),
    within: kSyncDeadline,
    reason: 'the mute to be applied and the selection to clear',
  );
}

// -------------------------------------------------------- notification policy

/// Puts the global *Only notify for mentions* switch into [on], and leaves the
/// notifications screen.
///
/// The global one because it is the only one the app has. `NotificationPolicy`
/// carries a per-chat `mentionsOnly` override and the screen's own subtitle
/// promises that "a single chat can disagree with this from its own screen" —
/// but nothing in `lib/` ever writes one, so there is no screen to drive. The
/// rule reached is the same either way (`rules.dart:734`).
///
/// Reads the switch before touching it: the policy is one blob in the settings
/// database and it outlives a test, so a scenario cannot assume which way it was
/// left.
Future<void> setMentionsOnly(
  PatrolIntegrationTester $, {
  required bool on,
}) async {
  await openInboxMenu($, 'Notifications');
  final row = find.widgetWithText(SwitchListTile, 'Only notify for mentions');
  await pumpUntil(
    $,
    () => showing(row),
    within: kUiDeadline,
    reason: 'the notifications screen',
  );

  final current = (row.evaluate().first.widget as SwitchListTile).value;
  if (current != on) {
    await $.tap(find.text('Only notify for mentions'));
    await pumpUntil(
      $,
      () => (row.evaluate().first.widget as SwitchListTile).value == on,
      within: kUiDeadline,
      reason: 'the mentions-only switch to read $on',
    );
  }
  await leaveSettingsScreen($);
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
