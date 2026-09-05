import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'support/support.dart';

/// The notification shade: what Weft posts into it, where a tap lands, and what
/// the two buttons beside the tap actually do.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/notification_test.dart
///
/// The first file in the suite whose subject is entirely outside the Flutter
/// view. A posted notification is a parcel handed to the system's notification
/// service; there is no widget for it, no semantics node, and no `flutter test`
/// however live its engine can see one. Everything read here is read through the
/// platform automator, and `support/shade.dart` holds the three rules that
/// shapes — chiefly that nothing may pump a frame while Weft is backgrounded.
///
/// ## Two things that have to be true before any of this can post
///
/// 1. **The session has to be `ready`.** `main.dart:299-315` starts the
///    notification service on that state and on no other, and a device that
///    took the *Continue without verifying* door stays `unverified` forever.
///    What task 3 recorded as "verify the device first" is only half of it:
///    verifying against a second session marks the keys the *other* end sent
///    (`key_verification.dart:786`), never one's own, so on an account with no
///    cross-signing identity `needsVerification` can never become false.
///    `ChatScenario.start(notifying: true)` mints the identity on the control
///    session, drives the emoji comparison through the app's own screens so the
///    control signs this device into it, and restarts Weft — because nothing
///    re-derives the session state in place either. All of it is in
///    `support/verification.dart`.
/// 2. **The OS permission has to be granted.** Weft raises it once per install,
///    behind the rationale sheet, and remembers that it did. `e2e.sh` runs
///    `pm clear` before the suite for that reason; without it the second run on
///    a device finds nothing to answer and every assertion here fails on an
///    empty shade.
///
/// ## What is *not* asserted here
///
/// **The killed-process path.** Weft notifies from sync while it is running, and
/// being notified while *closed* needs a push gateway and a Firebase project —
/// neither exists in this repository. These scenarios background the app rather
/// than killing it, which is a real state and the one desktop Weft has always
/// been in; the gateway leg is not-executed on every row of the matrix and is
/// recorded as such rather than as a pass.
///
/// **That the conversation a tap opens is a *merged* one.** The link a
/// notification carries is `weft://chat/<Chat.id>`, and for a merged contact
/// that id is `merged:<contactId>` rather than a room — which is exactly what
/// makes one notification thread out of two legs. Building a merge takes the
/// suggestion flow, and that is `merge_test`'s subject. What is asserted here is
/// the property the merged case rests on: the tap lands in the conversation the
/// message arrived in and not merely in whichever one is on top.
void main() {
  patrolTest(
    'a backgrounded Weft posts to the shade, and the tap opens that chat',
    ($) async {
      if (!shadeIsReachable) {
        markTestSkipped(
          'There is no shade this platform lets a test drive. macOS has '
          'Notification Center and no automator; see skip reason ① in '
          'docs/quality/e2e-matrix.md.',
        );
        return;
      }

      final scenario = await ChatScenario.start(
        $,
        title: 'Notifications',
        notifying: true,
      );

      // A second conversation, so "the right one opened" is a claim with
      // something to get wrong. The notification tapped below is the *older* of
      // the two, and the newer one is what a router that simply opened the top
      // of the inbox would land in.
      final second = await createJoinedRoom(
        creator: scenario.control,
        peer: scenario.bob,
        title: 'Notifications second',
      );
      addTearDown(second.dispose);

      // Neither conversation is opened before the app goes away, and that is
      // deliberate: `evaluateNotification`'s `alreadyRead` rule suppresses
      // anything not newer than the read marker, and Weft posts a read receipt
      // from the inbox row's tap handler. A test that looked at a chat first
      // would be asserting on a message the policy had already ruled out.
      await backgroundApp($);

      // From here to the tap, nothing pumps. See `support/shade.dart`.
      final wanted = await scenario.peerSays('while Weft was away');
      final decoy = uniqueBody('in the other conversation');
      await scenario.bob.sendText(second.id, decoy);
      await scenario.bob.requireMessage(second.id, decoy);

      // The body is the assertion, and the *title* deliberately is not:
      // `MessagingStyle.setConversationTitle` is ignored for a non-group
      // conversation from API 28 up, so what SystemUI draws above a 1:1 is the
      // sender rather than `chat.title`. One string asserted across both shapes
      // would fail on a perfectly correct app.
      await awaitNotification($, wanted.body);

      await tapNotification($, wanted.body, iosTitle: scenario.room.title);

      // The bubble is the assertion. Every body this suite sends is unique for
      // the run, so a bubble carrying this one can only be drawn by the room it
      // was sent to — which is the whole of "the correct conversation opened".
      await awaitBubble($, wanted.body);
      expect(
        showing(bubbleFor(decoy)),
        isFalse,
        reason:
            'the newer conversation is the one a router that ignored the link '
            'would have opened',
      );
      expect(
        deliveryStateFor($, wanted.body),
        isNull,
        reason: 'a delivery tick belongs to the sender, not to the recipient',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a reply typed into the shade reaches the peer',
    ($) async {
      if (!shadeActionsAreReachable) {
        markTestSkipped(
          'Notification actions are Android-only in this suite. Weft registers '
          '`UNTextInputNotificationAction` on iOS and it is a real feature '
          'there, but reaching it means long-pressing a banner and Patrol '
          'exposes no such gesture; see skip reason ⑤ in '
          'docs/quality/e2e-matrix.md.',
        );
        return;
      }

      final scenario = await ChatScenario.start(
        $,
        title: 'Notification reply',
        notifying: true,
      );

      await backgroundApp($);
      final incoming = await scenario.peerSays('worth answering');
      await awaitNotification($, incoming.body);

      await expandNotification($, incoming.body);
      final answer = uniqueBody('answered from the shade');
      await replyFromShade($, answer);

      // The half that cannot be faked locally: the message the user typed into
      // a system surface is on the homeserver, in the room the notification was
      // for, sent by the app's account.
      final delivered = await scenario.bob.requireMessage(
        scenario.room.id,
        answer,
      );
      expect(delivered.senderId, matrixUserId(kAppUser));

      // Answering is reading. `NotificationActionHandler._reply` marks the chat
      // read after a successful send, and the receipt is what takes the same
      // notification down on the user's other devices — so it is asserted where
      // it is visible, on the peer.
      await awaitReadReceipt(
        scenario.bob,
        roomId: scenario.room.id,
        eventId: incoming.eventId,
        reader: matrixUserId(kAppUser),
      );

      // Weft is in the foreground, because it has to be: all three actions
      // carry `showsUserInterface: true`, since a broadcast action is delivered
      // only to a background isolate and every one of them needs the Matrix
      // client that lives in the main one. The suite asserts that rather than
      // working around it.
      await pumpUntil(
        $,
        () => showing(inbox) || showing(composerField),
        within: kUiDeadline,
        reason: 'Weft to be on screen after the reply action',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'marking read from the shade posts a receipt and clears the notification',
    ($) async {
      if (!shadeActionsAreReachable) {
        markTestSkipped(
          'Notification actions are Android-only in this suite; see skip '
          'reason ⑤ in docs/quality/e2e-matrix.md.',
        );
        return;
      }

      final scenario = await ChatScenario.start(
        $,
        title: 'Notification mark read',
        notifying: true,
      );

      await backgroundApp($);
      final incoming = await scenario.peerSays('already seen');
      await awaitNotification($, incoming.body);

      await expandNotification($, incoming.body);
      await pressNotificationAction($, 'Mark read');
      await awaitWeftForeground($);

      // The receipt is the point of the action. Dismissing the notification is
      // local bookkeeping; the `m.read` is what the sender's client sees and
      // what makes the user's laptop take its own notification down.
      await awaitReadReceipt(
        scenario.bob,
        roomId: scenario.room.id,
        eventId: incoming.eventId,
        reader: matrixUserId(kAppUser),
      );

      // And the notification itself is gone. `NotificationActionHandler`
      // dismisses only after the work succeeded — `cancelNotification` is false
      // on all three actions precisely so a failed one leaves its notification
      // standing.
      await backgroundApp($);
      await openShade($);
      await pollUntilAsync(
        () async => !await shadeShows($, incoming.body),
        reason: 'the notification for "${incoming.body}" to be taken down',
        within: kNotificationDeadline,
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'opening the conversation takes its notifications out of the shade',
    ($) async {
      if (!shadeIsReachable) {
        markTestSkipped(
          'There is no shade this platform lets a test drive; see skip reason '
          '① in docs/quality/e2e-matrix.md.',
        );
        return;
      }

      // The one surface `flutter test` cannot draw, which is why this scenario
      // is here rather than in `chat_open_read_test.dart`. That test asserts
      // that opening a chat *calls* the dismisser; whether the row actually
      // leaves the system's notification service is a question only the
      // platform automator can answer, and the failure it catches — a cancel
      // aimed at an id or a tag the row was never posted under — looks
      // identical from inside the app.
      final scenario = await ChatScenario.start(
        $,
        title: 'Notification clearing',
        notifying: true,
      );

      // Two messages, so the assertion is about the *conversation* being
      // cleared rather than about one row happening to go: Weft groups a
      // chat's notifications under one key, and a dismissal that took only the
      // summary down would leave the individual rows behind on Android.
      await backgroundApp($);
      final first = await scenario.peerSays('the first one');
      final second = await scenario.peerSays('and the second');
      await awaitNotification($, second.body);
      expect(
        await shadeShows($, first.body),
        isTrue,
        reason:
            'both messages are in the shade before the conversation is opened. '
            'The shade holds: ${await describeShade($)}',
      );

      // Through the app rather than through the notification's own tap: a tap
      // routes to the deep-link handler, which is one door of several, and the
      // door being tested here is the ordinary one. Opening from the inbox is
      // what a user does when they saw the badge rather than the banner.
      await closeShade($);
      await foregroundApp($);
      await openChat($, scenario.room.title);
      await awaitBubble($, second.body);

      await backgroundApp($);
      await openShade($);
      await pollUntilAsync(
        () async =>
            !await shadeShows($, first.body) &&
            !await shadeShows($, second.body),
        reason:
            'every notification for the conversation to be taken down once it '
            'has been read',
        within: kNotificationDeadline,
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}
