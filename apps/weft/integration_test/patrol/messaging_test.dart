import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'support/support.dart';

/// Two accounts exchanging encrypted messages, one of them through the app.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/messaging_test.dart
///
/// Every assertion here has two ends, and that is the point. A send is asserted
/// on the *peer's* timeline as well as in the app, because a silently-failed
/// send renders a perfectly convincing local bubble; a read is asserted as a
/// receipt the peer receives, because "the badge went away" is a statement about
/// one device.
///
/// Three sessions run in this process — the app's, the peer's, and the app
/// account's own control session — which is why `TestAccount` gives each a
/// database *file* of its own. Two sessions asking sqflite for `:memory:` are
/// handed the same database, and the second login then fails with "User is
/// already logged in".
void main() {
  patrolTest(
    'an encrypted message reaches the peer and settles as delivered',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Messaging');
      await openChat($, scenario.room.title);

      final body = uniqueBody('from the app');
      await sendFromComposer($, body);

      // The bubble is drawn before the homeserver has heard of it: the send is
      // optimistic, and a composer that waited for a round trip would feel
      // broken on a train.
      await awaitBubble($, body);

      final states = await observeDeliveryStates($, body);
      _expectMonotonic(states);
      expect(
        states.last,
        'Delivered',
        reason: 'synced is the strongest guarantee a Matrix send has',
      );

      // The half that cannot be faked locally.
      final received = await scenario.bob.requireMessage(
        scenario.room.id,
        body,
      );
      expect(received.senderId, matrixUserId(kAppUser));

      final room = await scenario.bob.awaitRoom(scenario.room.id);
      expect(
        room.encrypted,
        isTrue,
        reason: 'the round trip has to have gone through megolm, not around it',
      );

      // And it maps onto Weft's own model the way the peer's inbox would read
      // it — the same check `matrix_session_test.dart` makes, now of a message
      // that was typed into a composer rather than pushed through the SDK.
      final mapped = mapEvent(
        received,
        network: networkForRoom(room),
        ownUserId: scenario.bob.client.userID,
        timeline: await scenario.bob.timeline(scenario.room.id),
      );
      expect(mapped, isNotNull);
      expect(mapped!.body, body);
      expect(mapped.isOwn, isFalse);
      expect(mapped.kind, MessageKind.text);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a message from the peer is read, and the peer sees the receipt',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Messaging');

      // Sent *before* the conversation is opened, and that ordering is the
      // whole scenario. Weft posts a read receipt from one place only — the
      // inbox row's tap handler, which calls `ChatRepository.markRead` — so a
      // message that arrives while the conversation is already open is never
      // receipted at all. That is a real gap, recorded rather than worked
      // around; what is asserted here is the path the app does have.
      final body = uniqueBody('from the peer');
      final sentId = await scenario.bob.sendText(scenario.room.id, body);
      expect(sentId, isNotNull, reason: "the peer's own send has to succeed");

      await pumpUntil(
        $,
        () => showing(find.text(body)),
        within: kSyncDeadline,
        reason: "the message to reach the app's inbox",
      );

      await openChat($, scenario.room.title);

      // Decrypted, not a "could not decrypt" placeholder: the app's device was
      // in this room before the peer ever sent to it, so it is in the megolm
      // session. Finding the bubble by its plaintext is what proves that.
      await awaitBubble($, body);
      expect(
        deliveryStateFor($, body),
        isNull,
        reason: 'a delivery tick belongs to the sender, not to the recipient',
      );

      await pollUntilAsync(
        () async => (await scenario.bob.readersOf(
          scenario.room.id,
          sentId!,
        )).contains(matrixUserId(kAppUser)),
        reason: 'the peer to receive a read receipt from the app account',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'the inbox reorders when an older conversation gets the newest message',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Messaging');

      // A second conversation, made after the first.
      final second = await createJoinedRoom(
        creator: scenario.control,
        peer: scenario.bob,
        title: 'Messaging second',
      );
      addTearDown(second.dispose);

      final titles = [scenario.room.title, second.title];
      String? topmost() {
        final order = inboxOrder($, titles);
        return order.isEmpty ? null : order.first;
      }

      await pumpUntil(
        $,
        () =>
            showing(find.text(scenario.room.title)) &&
            showing(find.text(second.title)),
        within: kSyncDeadline,
        reason: 'both conversations to reach the inbox',
      );

      // Nudge the newer one so the starting order is a fact rather than an
      // assumption about how the homeserver ordered two rooms created a moment
      // apart.
      await scenario.bob.sendText(second.id, uniqueBody('in the second chat'));
      await pumpUntil(
        $,
        () => topmost() == second.title,
        within: kSyncDeadline,
        reason: 'the second conversation to reach the top of the inbox',
      );

      // Now the *older* one gets the newest message.
      await scenario.bob.sendText(
        scenario.room.id,
        uniqueBody('in the first chat'),
      );
      await pumpUntil(
        $,
        () => topmost() == scenario.room.title,
        within: kSyncDeadline,
        reason: 'the first conversation to move back to the top of the inbox',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}

/// The order Weft's delivery states are allowed to move in.
const List<String> _deliveryOrder = ['Sending', 'Sent', 'Delivered', 'Read'];

/// Asserts a delivery state sequence only ever moved forward.
///
/// Not "these exact states, in this exact order": against a homeserver on the
/// same machine `Sending` can be over before the next frame, so a test that
/// demanded to see it would pass on a slow server and fail on a fast one. What
/// a broken send cannot do, at any speed, is go backwards or report `Not sent`.
void _expectMonotonic(List<String> states) {
  expect(
    states,
    isNot(contains('Not sent')),
    reason: 'the homeserver refused the event',
  );
  var previous = -1;
  for (final state in states) {
    final rank = _deliveryOrder.indexOf(state);
    expect(rank, isNonNegative, reason: 'unknown delivery state "$state"');
    expect(
      rank,
      greaterThanOrEqualTo(previous),
      reason: 'delivery went backwards: ${states.join(' → ')}',
    );
    previous = rank;
  }
}
