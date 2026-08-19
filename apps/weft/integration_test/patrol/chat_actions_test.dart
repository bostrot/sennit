import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:patrol/patrol.dart';

import 'support/support.dart';

/// Reply, react, edit and redact — Phase 05's four relations, driven from the
/// message actions sheet and asserted on the peer's timeline.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/chat_actions_test.dart
///
/// The peer assertion is what makes these worth running on a device. All four
/// actions render locally the instant they are tapped, and all four are *events
/// with a relation* — an `m.in_reply_to` that names an event id, an
/// `m.annotation` keyed to one, an `m.replace`, a redaction. A relation sent to
/// the wrong room is accepted by the homeserver and shown by nobody, including
/// the sender, which is exactly the failure a local-only assertion cannot see.
/// `MatrixChatRepository._findEvent` exists because of it.
///
/// Each scenario makes its own conversation and leaves it, so a failed run does
/// not poison the next one.
void main() {
  patrolTest(
    "a reply quotes the peer's message on the peer's timeline",
    ($) async {
      final scenario = await _ActionsScenario.start($);
      final target = await scenario.peerSays('reply to me');
      await openChat($, scenario.room.title);
      await awaitBubble($, target.body);

      final answer = uniqueBody('answering');
      await chooseMessageAction($, target.body, 'Reply');
      await pumpUntil(
        $,
        () => showing(find.textContaining('Replying to')),
        within: kUiDeadline,
        reason: 'the composer to say what the next send will do',
      );
      await sendFromComposer($, answer);
      await awaitBubble($, answer);

      final event = await scenario.bob.requireMessage(scenario.room.id, answer);
      expect(
        _replyTargetOf(event),
        target.eventId,
        reason:
            'the reply has to name the event it answers, and name it in the '
            'room that event actually lives in',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a reaction reaches the peer as an annotation on the right event',
    ($) async {
      final scenario = await _ActionsScenario.start($);
      final target = await scenario.peerSays('react to me');
      await openChat($, scenario.room.title);
      await awaitBubble($, target.body);

      await openMessageActions($, target.body);
      await $.tap(find.text(_reaction));

      // The sheet has to be gone before the chip is looked for: the quick-
      // reaction row it was tapped in holds the same glyph, and a sheet still
      // animating out would answer the question with itself.
      await pumpUntil(
        $,
        () => !showing(find.text('Reply')),
        within: kUiDeadline,
        reason: 'the actions sheet to close',
      );
      // The chip under the bubble, which is the only local sign it worked.
      await pumpUntil(
        $,
        () => showing(find.text(_reaction)),
        within: kSyncDeadline,
        reason: 'the reaction chip to appear under the message',
      );

      final annotation = await scenario.bob.requireEvent(
        scenario.room.id,
        (event) =>
            event.type == sdk.EventTypes.Reaction &&
            _annotationTarget(event) == target.eventId &&
            _annotationKey(event) == _reaction,
        description: 'a $_reaction annotation on ${target.eventId}',
      );
      expect(annotation.senderId, matrixUserId(kAppUser));
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    "an edit replaces the words on the peer's timeline",
    ($) async {
      final scenario = await _ActionsScenario.start($);
      await openChat($, scenario.room.title);

      final original = uniqueBody('first thoughts');
      await sendFromComposer($, original);
      await awaitBubble($, original);
      final sent = await scenario.bob.requireMessage(
        scenario.room.id,
        original,
      );

      final corrected = uniqueBody('second thoughts');
      await chooseMessageAction($, original, 'Edit');
      // The composer is pre-filled with the message's own words, so this is a
      // replacement rather than an append — which is what `enterText` does.
      await $.enterText(composerField.last, corrected);
      await $.tap(find.byTooltip('Save edit'));

      await awaitBubble($, corrected);
      await pumpUntil(
        $,
        () => showing(find.text('edited')),
        within: kUiDeadline,
        reason: 'the bubble to admit it was edited',
      );

      final replacement = await scenario.bob.requireEvent(
        scenario.room.id,
        (event) =>
            event.type == sdk.EventTypes.Message &&
            _replaceTargetOf(event) == sent.eventId &&
            _newBodyOf(event) == corrected,
        description: 'an m.replace of ${sent.eventId} reading "$corrected"',
      );
      expect(replacement.senderId, matrixUserId(kAppUser));
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a redaction removes the message for the peer as well',
    ($) async {
      final scenario = await _ActionsScenario.start($);
      await openChat($, scenario.room.title);

      final doomed = uniqueBody('regretted immediately');
      await sendFromComposer($, doomed);
      await awaitBubble($, doomed);
      final sent = await scenario.bob.requireMessage(scenario.room.id, doomed);

      await chooseMessageAction($, doomed, 'Delete');
      // A dialog rather than an undo toast, because a redaction reaches every
      // other client in the room and there is nothing left to undo.
      await pumpUntil(
        $,
        () => showing(find.text('Delete this message?')),
        within: kUiDeadline,
        reason: 'the redaction to be confirmed rather than assumed',
      );
      await $.tap(find.widgetWithText(TextButton, 'Delete'));

      await awaitNoBubble($, doomed);
      await pumpUntil(
        $,
        () => showing(find.text('Message deleted')),
        within: kSyncDeadline,
        reason: 'the tombstone the app leaves where the message was',
      );

      await pollUntilAsync(
        () async =>
            (await scenario.bob.eventById(
              scenario.room.id,
              sent.eventId,
            ))?.redacted ??
            false,
        reason: "the peer's copy of ${sent.eventId} to be redacted",
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}

/// The quick reaction the sheet offers first. From `kQuickReactions`, and
/// deliberately the plainest of the six: a key with a variation selector in it
/// is normalised on the way out (`normaliseReactionKey`), and a test asserting
/// on the raw string would be asserting on the wrong one.
const String _reaction = '👍';

/// The app signed in, a peer, and a conversation to act in.
class _ActionsScenario {
  _ActionsScenario._(this.control, this.bob, this.room);

  static Future<_ActionsScenario> start(PatrolIntegrationTester $) async {
    await ensureSignedIn($);

    final control = await TestAccount.control();
    addTearDown(control.dispose);
    final bob = await TestAccount.peer();
    addTearDown(bob.dispose);

    final room = await createJoinedRoom(
      creator: control,
      peer: bob,
      title: 'Chat actions',
    );
    addTearDown(room.dispose);

    return _ActionsScenario._(control, bob, room);
  }

  final TestAccount control;
  final TestAccount bob;
  final TestRoom room;

  /// Has the peer send something for the app to act on, and waits until the
  /// peer's own timeline holds it — so its event id is a fact rather than the
  /// return value of a request that may still be in flight.
  Future<({String eventId, String body})> peerSays(String prefix) async {
    final body = uniqueBody(prefix);
    await bob.sendText(room.id, body);
    final event = await bob.requireMessage(room.id, body);
    return (eventId: event.eventId, body: body);
  }
}

/// The event id an `m.in_reply_to` names, or null when the event is not a reply.
String? _replyTargetOf(sdk.Event event) {
  final relates = event.content['m.relates_to'];
  if (relates is! Map) return null;
  final inReplyTo = relates['m.in_reply_to'];
  if (inReplyTo is! Map) return null;
  final id = inReplyTo['event_id'];
  return id is String ? id : null;
}

/// The event id an `m.replace` replaces, or null.
String? _replaceTargetOf(sdk.Event event) {
  final relates = event.content['m.relates_to'];
  if (relates is! Map) return null;
  if (relates['rel_type'] != sdk.RelationshipTypes.edit) return null;
  final id = relates['event_id'];
  return id is String ? id : null;
}

/// The body an edit carries in `m.new_content`, or null.
String? _newBodyOf(sdk.Event event) {
  final content = event.content['m.new_content'];
  if (content is! Map) return null;
  final body = content['body'];
  return body is String ? body : null;
}

/// The event id an annotation is keyed to, or null.
String? _annotationTarget(sdk.Event event) {
  final relates = event.content['m.relates_to'];
  if (relates is! Map) return null;
  final id = relates['event_id'];
  return id is String ? id : null;
}

/// The key an annotation carries, or null.
String? _annotationKey(sdk.Event event) {
  final relates = event.content['m.relates_to'];
  if (relates is! Map) return null;
  final key = relates['key'];
  return key is String ? key : null;
}
