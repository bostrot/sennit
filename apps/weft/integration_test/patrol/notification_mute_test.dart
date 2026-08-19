import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'support/support.dart';

/// The two ways Weft stays quiet on purpose, and the one message that gets
/// through anyway.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/notification_mute_test.dart
///
/// Both scenarios assert an **absence**, which is the hardest thing in this
/// suite to assert honestly. Suppression leaves no trace: no event, no log line,
/// nothing on any screen. "No notification appeared" is therefore equally true
/// of a working mute and of a notification path that never ran at all — of a
/// session that stayed `unverified`, an ungranted permission, a homeserver that
/// stopped syncing. So every silence here is asserted next to a *control* that
/// had to be noisy in the same window, and the control is sent first and waited
/// for before the silence is believed. That is what [expectShadeSilent] is.
///
/// ## Where each setting is written from
///
/// - **Mute** goes through the inbox: long-press a conversation to enter
///   selection, then the *Mute* button in the selection bar, which is
///   `ChatRepository.setMuted` and a `dont_notify` push rule on every source
///   room of the chat. It comes back to `evaluateNotification` as `Chat.muted`,
///   read off `room.pushRuleState` in `MatrixChatRepository._chatFromRoom`. That
///   is the whole loop — the server rule stops the push, the mapped flag stops
///   the display — and driving it from the inbox is what puts the loop under
///   test rather than the flag.
/// - **Mentions-only** is the *global* switch on the notifications screen,
///   because that is the only mentions-only control the app has. Weft's policy
///   also carries a per-chat `ChatNotificationOverride.mentionsOnly`, and
///   `notifications_screen.dart` even says "A single chat can disagree with this
///   from its own screen" — but no screen writes it: nothing in `lib/` sets
///   `mentionsOnly` on an override. The scenario therefore exercises the switch
///   that exists, in a conversation, which is the same rule
///   (`rules.dart:734`) reached by its global half. The missing per-chat control
///   is a gap recorded rather than worked around.
///
/// ## Why a mention gets through a mute
///
/// `NotificationPolicy.mentionsBypassMute` defaults to true and its own switch
/// says why: "mute a busy group and still get paged in it". So the muted
/// scenario deliberately sends a message with nothing resembling the user's name
/// in it — a mention would have been the one thing that *should* break through,
/// and asserting silence on it would be asserting a bug.
void main() {
  patrolTest(
    'a muted conversation stays out of the shade while an unmuted one does not',
    ($) async {
      if (!shadeIsReachable) {
        markTestSkipped(
          'There is no shade this platform lets a test drive; see skip reason '
          '① in docs/quality/e2e-matrix.md.',
        );
        return;
      }

      final scenario = await ChatScenario.start(
        $,
        title: 'Muted',
        notifying: true,
      );
      final loud = await createJoinedRoom(
        creator: scenario.control,
        peer: scenario.bob,
        title: 'Not muted',
      );
      addTearDown(loud.dispose);

      await pumpUntil(
        $,
        () =>
            showing(find.text(scenario.room.title)) &&
            showing(find.text(loud.title)),
        within: kSyncDeadline,
        reason: 'both conversations to reach the inbox',
      );

      await muteChatFromInbox($, scenario.room.title);

      await backgroundApp($);

      // The control first, so that by the time the silence is believed the
      // pipeline has demonstrably posted something in the same window.
      final control = uniqueBody('from the unmuted conversation');
      await scenario.bob.sendText(loud.id, control);
      await scenario.bob.requireMessage(loud.id, control);

      // Nothing in this body resembles alice, her Matrix id or @room: a mention
      // is *supposed* to break through a mute, and asserting silence on one
      // would be asserting a bug.
      final silenced = uniqueBody('into the muted conversation');
      await scenario.bob.sendText(scenario.room.id, silenced);
      await scenario.bob.requireMessage(scenario.room.id, silenced);

      await expectShadeSilent(
        $,
        silent: silenced,
        control: control,
        reason:
            'the chat is muted on the homeserver, so `Chat.muted` is true and '
            '`evaluateNotification` suppresses it as `chatMuted`',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'mentions-only silences the chatter and lets a mention through',
    ($) async {
      if (!shadeIsReachable) {
        markTestSkipped(
          'There is no shade this platform lets a test drive; see skip reason '
          '① in docs/quality/e2e-matrix.md.',
        );
        return;
      }

      final scenario = await ChatScenario.start(
        $,
        title: 'Mentions only',
        notifying: true,
      );

      await setMentionsOnly($, on: true);
      // Put back even if an assertion below fails: the policy is one blob in
      // the settings database and it outlives the test, so a scenario that left
      // it on would silence every notification test that ran after it.
      addTearDown(() => setMentionsOnly($, on: false));

      await backgroundApp($);

      // The mention is the control here — the message that must arrive — and it
      // is sent first for the same reason as in the scenario above. Weft matches
      // mentions textually (`mentionsUser`), because `m.mentions` and the pill
      // markup in `formatted_body` are both dropped at mapping time and a
      // bridged mention never had them; the Matrix id is the form that cannot
      // be ambiguous.
      final mention = uniqueBody('${matrixUserId(kAppUser)} are you there');
      await scenario.bob.sendText(scenario.room.id, mention);
      await scenario.bob.requireMessage(scenario.room.id, mention);

      final chatter = uniqueBody('nobody in particular');
      await scenario.bob.sendText(scenario.room.id, chatter);
      await scenario.bob.requireMessage(scenario.room.id, chatter);

      await expectShadeSilent(
        $,
        silent: chatter,
        control: mention,
        reason:
            'mentions-only is on, and this message names nobody — '
            '`evaluateNotification` suppresses it as `mentionsOnly`',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}
