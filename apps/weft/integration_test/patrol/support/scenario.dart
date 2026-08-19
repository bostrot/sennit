/// The world a conversation scenario needs, made once: the app signed in, a
/// peer with a client of its own, and one encrypted room the two share.
///
/// Every scenario file in the suite opened with the same twenty lines — sign
/// in, bring up a control session, bring up a peer, make a room, register four
/// teardowns in the right order — and the order is the part that is easy to get
/// wrong and expensive to debug. It is written down once here instead.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'accounts.dart';
import 'app.dart';
import 'environment.dart';

/// The app, a peer, and an encrypted conversation between them.
///
/// The order of [start] is load-bearing rather than incidental: the app signs
/// in *first*, so its device keys are published before the room exists and
/// before the peer encrypts anything into it. A room created against an account
/// whose device has not appeared yet is a room the peer shares its megolm
/// session with every device except the one under test, and the symptom is an
/// undecryptable bubble that reads as an encryption bug.
class ChatScenario {
  ChatScenario._(this.control, this.bob, this.room);

  /// Signs the app in, brings up both helper sessions, and makes the room.
  ///
  /// [title] names the conversation in the app's inbox. It is made unique per
  /// run by [createJoinedRoom], because the homeserver is shared across a whole
  /// matrix and a test that opened "Attachments" could otherwise open one an
  /// hour old from a different device.
  static Future<ChatScenario> start(
    PatrolIntegrationTester $, {
    required String title,
  }) async {
    await ensureSignedIn($);

    final control = await TestAccount.control();
    addTearDown(control.dispose);
    final bob = await TestAccount.peer();
    addTearDown(bob.dispose);

    final room = await createJoinedRoom(
      creator: control,
      peer: bob,
      title: title,
    );
    // Registered last so it runs first: teardowns are LIFO, and a room has to
    // be left before the accounts that are in it log out.
    addTearDown(room.dispose);

    return ChatScenario._(control, bob, room);
  }

  /// The app account's own second session. Setup only — see `accounts.dart`.
  final TestAccount control;

  /// The other participant, headless, in this process.
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
