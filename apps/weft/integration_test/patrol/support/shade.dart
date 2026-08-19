/// The notification shade: getting permission to write to it, reading what is
/// in it, tapping it, and answering it without opening the app first.
///
/// The one surface in this suite that Flutter has no view of at all. A posted
/// notification is a parcel handed to the system's notification service and
/// drawn by SystemUI — there is no widget to find, no semantics tree to read,
/// and the only handle a test has on it is the platform automator.
///
/// Three constraints shape everything here, and none of them is negotiable:
///
/// 1. **Do not pump while the app is backgrounded.** `pumpUntil` and every
///    `$.tap` underneath it end at `LiveTestWidgetsFlutterBinding.pump`, which
///    schedules a frame and then awaits `_pendingFrame`
///    (`flutter_test/src/binding.dart:2994-3016`) — a completer only a *drawn*
///    frame completes, with no timeout on it. A stopped Android activity draws
///    nothing, so a pump between [backgroundApp] and the app coming back is a
///    hang rather than a failure. Everything in that window is either an
///    automator call or a `pollUntil`, which waits on a `Timer` and does not
///    care whether anything is on screen.
/// 2. **Read the shade as a view tree, not as `getNotifications()`.** Patrol's
///    reader looks for `android:id/title` and `android:id/text`
///    (`Automator.kt:558-570`), which are the ids of the *classic* notification
///    layout. Weft posts `MessagingStyle` with a `shortcutId`, which from API 30
///    is drawn by SystemUI's conversation layout with ids of its own — so the
///    reader can legitimately come back with two empty strings for a
///    notification that is plainly on screen. [shadeText] walks
///    `getNativeViews` instead and sees whatever is actually rendered.
///    `getNotifications()` is still called, but only to put something readable
///    in a failure message.
/// 3. **An absence is only worth asserting next to a presence.** A test that
///    waits ten seconds and reports "no notification appeared" passes just as
///    happily when notifications are broken outright as when the mute under test
///    works. [expectShadeSilent] therefore takes the positive control with it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'accounts.dart';
import 'environment.dart';
import 'media.dart' show awaitWeftForeground;

// ------------------------------------------------------------- the permission

/// How long to wait for a notification that should arrive.
///
/// The whole chain has to run inside it: the peer's send reaches the
/// homeserver, the app's sync brings the event down, it is decrypted, evaluated
/// against the policy, rendered, and handed to the platform. On a cold emulator
/// with the app in the background that is seconds, not milliseconds.
const Duration kNotificationDeadline = Duration(seconds: 90);

/// How long to wait before concluding that nothing is going to be posted.
///
/// Shorter than [kNotificationDeadline] on purpose: it is spent in full on
/// every negative assertion, and the positive control beside it is what makes a
/// short window honest — the control message is sent *first* and its
/// notification has to arrive before the silence is believed.
const Duration kSilenceWindow = Duration(seconds: 20);

/// Whether this platform has a shade a test can drive at all.
///
/// Android and iOS have one and Patrol reaches both. macOS has Notification
/// Center and no automator, which is skip reason ① of the matrix.
bool get shadeIsReachable =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Whether this platform lets a test press a notification's *action* buttons.
///
/// Android only. Weft registers `UNTextInputNotificationAction` on iOS and it
/// is a real feature there, but reaching it means long-pressing a banner to
/// expand it and Patrol's automator exposes no such gesture — so the iOS rows
/// run the tap half of `notification_test` and skip the action half. Skip
/// reason ⑤.
bool get shadeActionsAreReachable =>
    defaultTargetPlatform == TargetPlatform.android;

/// Grants the OS notification permission, if this platform asks for one and it
/// has not been granted already.
///
/// The prompt is raised by Weft rather than by the test: `main.dart:229-243`
/// spends it once ever, behind the rationale sheet, and records that it has been
/// spent in `WeftSettings.notifyPermissionAsked`. So by the time this is called
/// the dialog is either already up, about to be, or was answered on an earlier
/// scenario of the same run — which is why the dialog is *waited for* and its
/// absence is not a failure.
///
/// `tooling/scripts/e2e.sh` runs `pm clear` before the suite, so a run starts
/// with the permission ungranted and the setting unwritten. Without that clear
/// the first scenario of the second run finds nothing to answer and every
/// assertion in this file fails on an empty shade.
Future<void> grantNotificationPermission(PatrolIntegrationTester $) async {
  if (!shadeIsReachable) return;
  final automator = $.platformAutomator.mobile;
  if (await automator.isPermissionDialogVisible(timeout: _kPromptWindow)) {
    await automator.grantPermissionWhenInUse();
    await awaitWeftForeground($);
  }
}

/// How long to wait for the OS permission dialog before deciding there is not
/// going to be one.
///
/// Short, and deliberately not [kNativeDeadline]: the caller has just answered
/// the rationale sheet, so the dialog is either already being raised or is never
/// coming — and "never coming" is the ordinary case from the second scenario of
/// a run onwards. Waiting a minute for it each time would cost more than every
/// assertion in these files put together.
const Duration _kPromptWindow = Duration(seconds: 20);

// -------------------------------------------------------------- the app's own
//                                                                  foreground

/// Sends Weft to the background, where a notification is worth posting.
///
/// Home rather than Back: Back on the inbox would finish the activity, and a
/// finished activity takes the Dart isolate — and with it the test — down with
/// it. Home stops the activity and leaves the process running, which is exactly
/// the state Weft notifies from: sync keeps arriving, the pipeline keeps
/// deciding, and `flutter_local_notifications` keeps posting. Nothing here needs
/// a push gateway, and that is why the suite can assert on notifications at all
/// without sygnal and a Firebase project.
///
/// After this returns, **do not pump** until [foregroundApp] or a notification
/// tap has brought Weft back. See this library's header.
///
/// The teardown is not tidiness. `flutter_test` unmounts the tree between tests
/// and the next scenario's [launchWeft] pumps for its first frame — from a
/// stopped activity that is the hang described above, in a test that did nothing
/// wrong. A scenario that backgrounds Weft therefore always brings it back,
/// whether it reached its own last line or failed on its first assertion.
Future<void> backgroundApp(PatrolIntegrationTester $) async {
  addTearDown(() => foregroundApp($));
  await $.platformAutomator.mobile.pressHome();
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

/// Brings Weft back without going through a notification.
Future<void> foregroundApp(PatrolIntegrationTester $) async {
  await $.platformAutomator.mobile.openApp();
  await awaitWeftForeground($);
  await $.pumpAndTrySettle();
}

// ----------------------------------------------------------- reading the shade

/// Opens the shade and leaves it open.
Future<void> openShade(PatrolIntegrationTester $) async {
  await $.platformAutomator.mobile.openNotifications();
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

/// Closes the shade, tolerating a shade that is already closed.
///
/// On Android `closeNotifications` is a Back press, which on a closed shade goes
/// somewhere else entirely — so a caller that is not sure should not call this.
/// Callers here always are: it is only used to leave a shade this file opened.
Future<void> closeShade(PatrolIntegrationTester $) async {
  await $.platformAutomator.mobile.closeNotifications();
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

/// Every piece of text the automator can currently see, shade included.
///
/// A flat list off the whole native view tree rather than Patrol's
/// `getNotifications()`, for the reason in this library's header: the reader
/// looks for two resource ids that a conversation-style notification does not
/// have. Both `text` and `contentDescription` are collected — an action button
/// often carries its label only in the description, and an avatar its sender's
/// name.
Future<List<String>> shadeText(PatrolIntegrationTester $) {
  final automator = $.platformAutomator;
  return automator.action(
    android: () async {
      final views = await automator.android.getNativeViews(null);
      final out = <String>[];
      void walk(AndroidNativeView view) {
        if (view.text case final String text when text.isNotEmpty) {
          out.add(text);
        }
        if (view.contentDescription case final String label
            when label.isNotEmpty) {
          out.add(label);
        }
        view.children.forEach(walk);
      }

      views.roots.forEach(walk);
      return out;
    },
    ios: () async {
      final views = await automator.ios.getNativeViews(null);
      final out = <String>[];
      void walk(IOSNativeView view) {
        for (final value in [view.label, view.title, ?view.value]) {
          if (value.isNotEmpty) out.add(value);
        }
        view.children.forEach(walk);
      }

      views.roots.forEach(walk);
      return out;
    },
  );
}

/// Whether anything on screen contains [needle].
Future<bool> shadeShows(PatrolIntegrationTester $, String needle) async =>
    (await shadeText($)).any((text) => text.contains(needle));

/// Opens the shade and waits until it shows [needle], or fails saying what it
/// did show.
///
/// [needle] is normally the message body, which `uniqueBody` has already made
/// unique across the whole matrix run — so a match is this message and not one
/// a previous row left in the shade of a device that was never wiped.
Future<void> awaitNotification(
  PatrolIntegrationTester $,
  String needle, {
  Duration? within,
}) async {
  final limit = within ?? kNotificationDeadline;
  final deadline = DateTime.now().add(limit);
  await openShade($);
  while (DateTime.now().isBefore(deadline)) {
    if (await shadeShows($, needle)) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail(
    'No notification containing "$needle" appeared within ${limit.inSeconds}s. '
    'The shade holds: ${await describeShade($)}',
  );
}

/// What is in the shade, in a sentence a failure message can carry.
///
/// This is where `getNotifications()` earns its keep: it comes back as
/// title/content pairs, which read far better in a failure than a flat list of
/// every string SystemUI has on screen. When it comes back empty — which a
/// conversation-style notification can make it do — the flat list is printed
/// instead, so the message is never simply "nothing".
Future<String> describeShade(PatrolIntegrationTester $) async {
  try {
    final posted = await $.platformAutomator.mobile.getNotifications();
    if (posted.isNotEmpty) {
      return posted
          .map((n) => '${n.appName ?? '?'}: "${n.title}" / "${n.content}"')
          .join(' · ');
    }
    final text = await shadeText($);
    return text.isEmpty ? '<nothing>' : text.join(' · ');
  } on Object catch (error) {
    return '<could not be read: $error>';
  }
}

/// Asserts that [silent] never produces a notification, while [control] does.
///
/// The two halves are one assertion. Suppression is invisible — there is no
/// event, no log line and nothing on screen — so "nothing appeared" is equally
/// true of a working mute and of a notification path that is not running at all,
/// and only the control tells them apart. The control is *sent first* and waited
/// for, so by the time the silence is believed the pipeline has demonstrably
/// posted something in the same window.
///
/// Both bodies must already be on the homeserver: the caller sends them, this
/// only reads the shade.
Future<void> expectShadeSilent(
  PatrolIntegrationTester $, {
  required String silent,
  required String control,
  String? reason,
}) async {
  await awaitNotification($, control);
  // The control is up, so the pipeline reached the shade in this window. The
  // suppressed one had at least as long to get there and did not.
  await Future<void>.delayed(kSilenceWindow);
  expect(
    await shadeShows($, silent),
    isFalse,
    reason:
        reason ??
        'a suppressed message must not reach the shade. The shade holds: '
            '${await describeShade($)}',
  );
}

// ------------------------------------------------------------ acting on one

/// Taps the notification containing [needle] and waits for Weft to come up.
///
/// `tapOnNotificationBySelector` rather than a plain automator tap because it
/// waits for the shade to actually hold the thing first (`Automator.kt:609-616`)
/// — the tap itself lands on the matched view's centre, which for a body
/// `TextView` inside a notification is inside the row that carries the content
/// intent.
///
/// [iosTitle] exists because Patrol honours only `titleContains` on iOS, and the
/// title of a Weft notification is the *conversation*, not the message:
/// `NotificationPresentation` passes `content.title` as the title and the sender
/// as the subtitle. So Android is aimed at the body — unique per run, and
/// therefore unambiguous about which notification is meant — and iOS at the
/// conversation, which is the most specific thing it will match on.
Future<void> tapNotification(
  PatrolIntegrationTester $,
  String needle, {
  required String iosTitle,
  Duration? timeout,
}) async {
  final automator = $.platformAutomator;
  await automator.action(
    android: () => automator.android.tapOnNotificationBySelector(
      AndroidSelector(textContains: needle),
      timeout: timeout ?? kNativeDeadline,
    ),
    ios: () => automator.ios.tapOnNotificationBySelector(
      IOSSelector(titleContains: iosTitle),
      timeout: timeout ?? kNativeDeadline,
    ),
  );
  await awaitWeftForeground($);
  await $.pumpAndTrySettle();
}

/// Presses one of the three action buttons on a notification.
///
/// [action] is the label `notification_channels.dart` gives it — *Reply*,
/// *Mark read* or *Mute for 1 hour*.
///
/// The notification has to be expanded first, by [expandNotification]: a
/// collapsed row draws none of its actions, and whether the topmost
/// notification arrives expanded is a device and a version decision rather than
/// something a test may assume.
Future<void> pressNotificationAction(
  PatrolIntegrationTester $,
  String action, {
  Duration? timeout,
}) async {
  await $.platformAutomator.mobile.tap(
    Selector(text: action),
    timeout: timeout ?? kNativeDeadline,
  );
}

/// Expands the notification containing [needle] so its actions are drawn.
///
/// A downward drag starting *inside that notification*, which is the gesture a
/// person makes. Deliberately not a tap on `android:id/expand_button`: that
/// selector matches the chevron of whichever notification the automator finds
/// first, and the shade of an emulator is rarely Weft's alone — "USB debugging
/// connected" sits above it more often than not. Aiming at the row that carries
/// the message body is the only way to be sure which notification is being
/// opened.
///
/// Coordinates come from the view tree, which reports pixels, while `swipe`
/// takes fractions of the screen — so the screen's own extent is taken from the
/// same tree rather than from a `MediaQuery` that describes Weft's window and
/// not SystemUI's.
///
/// A notification that is already expanded is dragged a little and stays
/// expanded, which is why this is safe to call unconditionally. Not reachable on
/// iOS at all, where the actions this exists for are not reachable either.
Future<void> expandNotification(
  PatrolIntegrationTester $,
  String needle,
) async {
  if (!shadeActionsAreReachable) return;

  final automator = $.platformAutomator;
  final views = await automator.android.getNativeViews(null);

  var screen = 0.0;
  var width = 0.0;
  Point2D? centre;
  void walk(AndroidNativeView view) {
    if (view.visibleBounds.maxY > screen) screen = view.visibleBounds.maxY;
    if (view.visibleBounds.maxX > width) width = view.visibleBounds.maxX;
    final text = '${view.text ?? ''} ${view.contentDescription ?? ''}';
    if (centre == null && text.contains(needle)) centre = view.visibleCenter;
    view.children.forEach(walk);
  }

  views.roots.forEach(walk);

  final from = centre;
  if (from == null || screen <= 0 || width <= 0) {
    fail(
      'Could not find "$needle" in the shade to expand it. '
      'The shade holds: ${await describeShade($)}',
    );
  }

  final y = (from.y / screen).clamp(0.05, 0.7);
  await automator.mobile.swipe(
    from: Offset((from.x / width).clamp(0.05, 0.95), y.toDouble()),
    to: Offset((from.x / width).clamp(0.05, 0.95), (y + 0.2).toDouble()),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

/// Types [body] into a notification's inline reply and sends it.
///
/// The two SystemUI ids are AOSP's own (`remote_input.xml`): `remote_input_text`
/// is the `EditText` `RemoteInput` collects into and `remote_input_send` is the
/// arrow beside it. They are the only handles there are — the field has no text
/// to match on and the button no label — and they are the part of this file most
/// likely to want adjusting on a heavily-skinned device, which is why they are
/// named here rather than inline at the call site.
///
/// Weft's reply action carries `showsUserInterface: true`, so sending brings the
/// app to the foreground: Android delivers a broadcast action only to a
/// background isolate, and every one of Weft's actions needs the Matrix client
/// that lives in the main one (`notification_channels.dart:74-101`). The wait
/// for the foreground is therefore part of the action, not a tidy-up after it.
Future<void> replyFromShade(
  PatrolIntegrationTester $,
  String body, {
  Duration? timeout,
}) async {
  final automator = $.platformAutomator.mobile;
  await pressNotificationAction($, 'Reply', timeout: timeout);
  await automator.enterText(
    Selector(resourceId: _remoteInputText),
    text: body,
    timeout: timeout ?? kNativeDeadline,
  );
  await automator.tap(
    Selector(resourceId: _remoteInputSend),
    timeout: timeout ?? kNativeDeadline,
  );
  await awaitWeftForeground($);
  await $.pumpAndTrySettle();
}

/// SystemUI's inline reply field.
const String _remoteInputText = 'com.android.systemui:id/remote_input_text';

/// The arrow that submits it.
const String _remoteInputSend = 'com.android.systemui:id/remote_input_send';

// --------------------------------------------------------------- the account

/// Waits for [reader] to have posted an `m.read` receipt for [eventId].
///
/// The half of *Mark read* that is not a screen. Dismissing the notification is
/// local bookkeeping; the receipt is the thing the sender's client sees and the
/// thing that makes the user's other devices take their own notification down,
/// which is what `NotificationActionHandler._markRead` says the action is for.
Future<void> awaitReadReceipt(
  TestAccount peer, {
  required String roomId,
  required String eventId,
  required String reader,
}) => pollUntilAsync(
  () async => (await peer.readersOf(roomId, eventId)).contains(reader),
  reason: '$reader to post a read receipt for $eventId',
  within: kNotificationDeadline,
);

/// Whether this run is on a platform whose OS predates the notification
/// permission, and therefore never shows a dialog to grant.
///
/// API 33 is where `POST_NOTIFICATIONS` arrived — skip reason ③ of the matrix.
/// Read off the device rather than assumed from the row, because a row is a
/// label in a document and this is the machine the test is on.
Future<bool> osPredatesNotificationPermission(
  PatrolIntegrationTester $,
) async =>
    defaultTargetPlatform == TargetPlatform.android &&
    await $.platformAutomator.mobile.getOsVersion() < 33;
