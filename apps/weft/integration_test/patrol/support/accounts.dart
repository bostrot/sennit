/// Headless Matrix accounts for the device suite: the peer the app talks to,
/// and the second session of the app's own account that stands in for the
/// affordances Weft does not have yet.
///
/// The app is one account driven through its own UI. Everything a *second*
/// participant has to do — create the room, join it, answer, react, read, verify
/// — is done here by a `WeftMatrixSession` with no widgets attached, in the same
/// process as the app. That is deliberate on both counts:
///
/// - **The peer must be a real Matrix client**, because the point of asserting
///   on it is that a silently-failed send renders a perfectly convincing local
///   bubble. A test that only looked at the app would pass on a message the
///   homeserver never accepted.
/// - **The setup account must be Weft itself**, not a bare SDK client, because
///   it is the same session class the app runs and therefore the same E2EE, the
///   same database layer and the same failure modes.
///
/// > **Weft cannot start a conversation.** There is no start-chat flow —
/// > `main.dart:260-263` matches `OpenUserLink` and only `debugPrint`s — and no
/// > accept-invite affordance anywhere in the app: nothing reads
/// > `Membership.invite`, and `MatrixChatRepository` renders every room the
/// > client knows about without distinguishing an invitation from a joined room.
/// > So a scenario that needs a conversation cannot make one through the UI, and
/// > pretending otherwise would mean asserting a screen the app has never drawn.
/// > [TestAccount.control] is the honest answer: the app account's *own* second
/// > session creates the room, which makes the app a member from the first
/// > moment rather than an invitee waiting for a button that does not exist.
/// > It is used for setup and for protocol-level assertions only, and never to
/// > stand in for something the user would have done on screen.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'environment.dart';

/// What a helper session calls its device on the homeserver.
///
/// Visible to anyone the account shares an encrypted room with, and — the
/// reason it is not just "Weft" — visible in the devices list `login_test`
/// drives. An account this suite has run against a few times holds several
/// sessions all called "Weft", and a test that picked one of those would pick a
/// different one each run.
String helperDeviceName(String label) => 'Weft E2E $label';

/// The label [TestAccount.control] runs under.
const String kControlLabel = 'control';

/// [TestAccount.control]'s device name, which is how it is found on screen.
final String kControlDeviceName = helperDeviceName(kControlLabel);

/// One signed-in Matrix session with no UI attached.
class TestAccount {
  TestAccount._(this.localpart, this.session, this._databasePath);

  /// Signs [localpart] in on a database of its own.
  ///
  /// The database is a *file* under a temporary directory and never
  /// `inMemoryDatabasePath`. sqflite caches open databases by path, so two
  /// sessions asking for `:memory:` in one process are handed the same database:
  /// the second client then restores the first one's stored session and login
  /// fails with "User is already logged in". Every scenario in this suite runs
  /// at least two sessions in the app's process — the app's own and this one —
  /// so it is not a hypothetical.
  ///
  /// [label] separates two sessions of the *same* user, which is what
  /// [TestAccount.control] is.
  static Future<TestAccount> signIn(
    String localpart, {
    String label = 'peer',
  }) async {
    final serial = _serial++;
    final name = 'weft-e2e-$localpart-$label-$serial';
    final directory = await _databaseDirectory();
    final path = p.join(directory.path, '$name.sqlite');

    final session = WeftMatrixSession(
      clientName: name,
      deviceDisplayName: helperDeviceName(label),
      databaseOverride: () async => sdk.MatrixSdkDatabase.init(
        name,
        database: await openWeftSqfliteDatabase(path),
      ),
    );

    await session.initialize();
    await session.checkHomeserver(kHomeserver);
    await session.loginWithPassword(
      username: localpart,
      password: kTestPassword,
    );

    expect(
      session.encryptionEnabled,
      isTrue,
      reason:
          'vodozemac should be available on this platform — on Android this is '
          'the Rust cross-compile from the README, and it is the most likely '
          'reason a first device run fails in a way that looks like a Matrix bug',
    );

    return TestAccount._(localpart, session, path);
  }

  /// A second session of the account the *app* is signed in as.
  ///
  /// See this library's header for why it exists. It is also the other device
  /// `login_test`'s verification scenario verifies against: an interactive
  /// verification needs two sessions of one account, and the matrix has one
  /// device per row.
  static Future<TestAccount> control() =>
      signIn(kAppUser, label: kControlLabel);

  /// The peer the app exchanges messages with.
  static Future<TestAccount> peer() => signIn(kPeerUser);

  final String localpart;
  final WeftMatrixSession session;
  final String _databasePath;

  sdk.Client get client => session.client;

  String get userId => matrixUserId(localpart);

  /// This session's device on the homeserver.
  String get deviceId => client.deviceID!;

  /// Timelines are cached per room: `getTimeline` installs subscriptions, and a
  /// poll loop that opened a new one on every round would leak one per second.
  final Map<String, sdk.Timeline> _timelines = {};

  /// Creates an encrypted direct room and invites [invitee] to it.
  ///
  /// Encryption is enabled after creation rather than through `initialState`
  /// because that is what Weft's own code does, and the whole point of the
  /// suite is to exercise the paths the app takes.
  ///
  /// [name] is what the conversation is *called* in the app's inbox, and the
  /// suite always gives one. A nameless direct chat is titled from its other
  /// member, so every room the suite makes would be called "bob" — and a test
  /// that opens "bob" on a homeserver shared across eleven matrix rows cannot
  /// say which "bob" it opened. It stays a direct chat regardless: `isDirect`
  /// writes `m.direct`, which is what `Room.isDirectChat` reads, and a name is
  /// a separate state event.
  Future<String> createDirectRoom(
    TestAccount invitee, {
    required String name,
    bool encrypted = true,
  }) async {
    final roomId = await client.createRoom(
      name: name,
      invite: [invitee.userId],
      isDirect: true,
      preset: sdk.CreateRoomPreset.trustedPrivateChat,
    );
    final room = await awaitRoom(roomId);
    if (encrypted) await room.enableEncryption();
    return roomId;
  }

  /// Joins [roomId] and waits until the homeserver agrees this account is in it.
  Future<void> join(String roomId) async {
    await client.joinRoomById(roomId);
    await pollUntil(
      () => client.getRoomById(roomId)?.membership == sdk.Membership.join,
      within: kSyncDeadline,
      reason: '$localpart to join $roomId',
    );
  }

  /// The room, once sync has heard of it.
  Future<sdk.Room> awaitRoom(String roomId, {Duration? within}) async {
    await pollUntil(
      () => client.getRoomById(roomId) != null,
      within: within ?? kSyncDeadline,
      reason: '$localpart to see room $roomId',
    );
    return client.getRoomById(roomId)!;
  }

  /// The room's timeline, opened once and reused.
  Future<sdk.Timeline> timeline(String roomId) async {
    final open = _timelines[roomId];
    if (open != null) return open;
    final timeline = await (await awaitRoom(roomId)).getTimeline();
    _timelines[roomId] = timeline;
    return timeline;
  }

  Future<String?> sendText(String roomId, String body) async =>
      (await awaitRoom(roomId)).sendTextEvent(body);

  /// Posts a read receipt for [eventId], as a client whose user has read it.
  ///
  /// `mRead` as well as the read *marker*: the marker is private bookkeeping and
  /// nobody else can see it, and it is the `m.read` receipt that the sender's
  /// client observes. `MatrixChatRepository.markRead` sends both for the same
  /// reason.
  Future<void> markRead(String roomId, String eventId) async {
    await (await awaitRoom(roomId)).setReadMarker(eventId, mRead: eventId);
  }

  /// Everyone the homeserver says has read [eventId], by user id.
  Future<Set<String>> readersOf(String roomId, String eventId) async {
    final event = await eventById(roomId, eventId);
    if (event == null) return const {};
    return event.receipts.map((receipt) => receipt.user.id).toSet();
  }

  /// The event with [eventId] as this session currently holds it, or null.
  ///
  /// Off the open timeline rather than `Room.getEventById`, because the timeline
  /// is what decrypts, what aggregates edits and reactions onto their target,
  /// and what applies a redaction. A fetched event is the raw one.
  Future<sdk.Event?> eventById(String roomId, String eventId) async {
    final timeline = await this.timeline(roomId);
    for (final event in timeline.events) {
      if (event.eventId == eventId) return event;
    }
    return null;
  }

  /// Waits for an event in [roomId] that [matches], driving sync as it goes.
  ///
  /// Sync is *driven* rather than awaited: `oneShotSync` on a deadline is what
  /// `matrix_session_test.dart` does and for the same reason — a device is
  /// slower than a laptop and an emulator slower again, so the deadline is a
  /// parameter rather than a constant.
  Future<sdk.Event?> awaitEvent(
    String roomId,
    bool Function(sdk.Event event) matches, {
    Duration? within,
  }) async {
    final timeline = await this.timeline(roomId);
    final deadline = DateTime.now().add(within ?? kSyncDeadline);
    while (DateTime.now().isBefore(deadline)) {
      for (final event in timeline.events) {
        if (matches(event)) return event;
      }
      await client.oneShotSync();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    // One last look: the final sync above may have delivered it.
    for (final event in timeline.events) {
      if (matches(event)) return event;
    }
    return null;
  }

  /// [awaitEvent], but a miss is a failure with something to read.
  Future<sdk.Event> requireEvent(
    String roomId,
    bool Function(sdk.Event event) matches, {
    required String description,
    Duration? within,
  }) async {
    final event = await awaitEvent(roomId, matches, within: within);
    if (event != null) return event;
    fail(
      '$localpart never received $description in $roomId within '
      '${(within ?? kSyncDeadline).inSeconds}s',
    );
  }

  /// A text message with exactly this body, decrypted.
  Future<sdk.Event> requireMessage(
    String roomId,
    String body, {
    Duration? within,
  }) => requireEvent(
    roomId,
    (event) => event.type == sdk.EventTypes.Message && event.body == body,
    description: 'the message "$body"',
    within: within,
  );

  /// A file event of [msgtype] that actually carries an attachment, decrypted.
  ///
  /// The `hasAttachment` half is what makes this worth asserting on rather than
  /// the msgtype alone: an upload that failed after the event was composed, or
  /// a client that sent the caption and abandoned the file, produces an
  /// `m.image` with no `url` and no `file` block — which renders as a text
  /// message and is exactly the silent failure this suite exists to catch.
  ///
  /// Matched by kind rather than by name because a picked file's name is the
  /// content provider's to choose: a photo taken by the camera, or one handed
  /// over by a documents picker, arrives under a name the test did not pick.
  /// Every scenario makes a room of its own, so one image in it is unambiguous.
  Future<sdk.Event> requireAttachment(
    String roomId, {
    String msgtype = sdk.MessageTypes.Image,
    Duration? within,
  }) => requireEvent(
    roomId,
    (event) =>
        event.type == sdk.EventTypes.Message &&
        event.messageType == msgtype &&
        event.hasAttachment,
    description: 'a $msgtype attachment',
    within: within,
  );

  /// Every attachment of [msgtype] this session currently holds in [roomId].
  ///
  /// For the shares that send more than one file, where the assertion is a
  /// count as much as a presence.
  Future<List<sdk.Event>> attachments(
    String roomId, {
    String msgtype = sdk.MessageTypes.Image,
  }) async => [
    for (final event in (await timeline(roomId)).events)
      if (event.type == sdk.EventTypes.Message &&
          event.messageType == msgtype &&
          event.hasAttachment)
        event,
  ];

  /// Whether this account has a cross-signing identity at all.
  ///
  /// The question [enableCrossSigning] is asked before doing anything, and the
  /// reason the notification scenarios can reach `ready` at all — see that
  /// method.
  bool get crossSigningEnabled => session.crossSigningExists;

  /// Mints a cross-signing identity for the account, from *this* session.
  ///
  /// The same call the Encryption screen's "Set up a recovery key" makes
  /// (`MatrixKeyBackup.createRecovery`), run headlessly because the account
  /// needs the identity before the app can be signed into it and the app has
  /// no screen that does this to *another* device.
  ///
  /// It exists because of a gap task 3 recorded only half of. An unverified
  /// session never starts notifications — `main.dart:299-315` starts the
  /// service on `ready` only — and an interactive verification against a second
  /// session **does not on its own make this device `ready`**:
  /// `WeftMatrixSession.needsVerification` asks whether *our own* device key is
  /// `verified`, and SAS marks the keys the *other* end sent
  /// (`key_verification.dart:786`), never one's own. `DeviceKeys.verified` is
  /// `directVerified || crossVerified`, so on an account with no cross-signing
  /// identity there is no route to either: the device stays `unverified`
  /// forever and no notification is ever posted.
  ///
  /// With an identity minted here, the SAS the app drives does reach it. This
  /// session holds the private halves it has just created, so when the
  /// verification completes it signs the app's device with the self-signing key
  /// (`key_verification.dart:805-810`); the app meanwhile has verified this
  /// account's *master* key over the same exchange, which is what turns that
  /// signature into a valid chain. `needsVerification` is then false — on the
  /// next `initialize()`, because nothing re-derives the session state in
  /// place.
  ///
  /// The recovery key is discarded. It is the one thing this returns that a
  /// user would keep, and a test has nothing to restore.
  Future<void> enableCrossSigning() async {
    // `replaceExisting` because a kept container (`e2e.sh --keep`) leaves an
    // account whose identity was minted by a session that is long gone, and a
    // private half nobody holds cannot sign anything. Re-minting is the only
    // way back to a signable account, and it is what `runBootstrap` does for
    // the user in the same situation.
    await MatrixKeyBackup(client).createRecovery(replaceExisting: true);
  }

  /// Every device id the homeserver currently lists for this account.
  Future<Set<String>> deviceIds() async {
    final devices = await client.getDevices();
    return (devices ?? const <sdk.Device>[])
        .map((device) => device.deviceId)
        .toSet();
  }

  /// Whether this session considers [otherDeviceId] of its *own* account
  /// verified.
  ///
  /// Polled rather than read once: the signature that makes a device verified
  /// arrives over `/sendToDevice` and lands through sync like anything else.
  Future<bool> sawDeviceVerified(
    String otherDeviceId, {
    Duration? within,
  }) async {
    final deadline = DateTime.now().add(within ?? kSyncDeadline);
    while (DateTime.now().isBefore(deadline)) {
      final keys = client.userDeviceKeys[userId]?.deviceKeys[otherDeviceId];
      if (keys?.verified ?? false) return true;
      await client.oneShotSync();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return client.userDeviceKeys[userId]?.deviceKeys[otherDeviceId]?.verified ??
        false;
  }

  /// Leaves and forgets [roomId], swallowing whatever the server says about it.
  ///
  /// Cleanup, and cleanup must not be able to fail a test that has already made
  /// its assertions: a room this account was never in, or one the previous
  /// teardown already forgot, is not news.
  Future<void> leaveAndForget(String roomId) async {
    try {
      final room = client.getRoomById(roomId);
      if (room == null) return;
      if (room.membership != sdk.Membership.leave) await room.leave();
      await room.forget();
    } on Object catch (error) {
      debugPrint('weft e2e: could not clean up $roomId for $localpart: $error');
    }
  }

  /// Signs out and closes everything.
  ///
  /// `logout` and not only `dispose`: this session is a device on a real
  /// account, and a suite that left one behind per test would be a suite that
  /// grows a device list all day — which is precisely what `login_test` asserts
  /// the app does not do.
  Future<void> dispose() async {
    for (final timeline in _timelines.values) {
      timeline.cancelSubscriptions();
    }
    _timelines.clear();
    try {
      await session.logout();
    } on Object catch (error) {
      debugPrint('weft e2e: logout failed for $localpart: $error');
    }
    await session.dispose();
    try {
      final file = File(_databasePath);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // The database was never created, or the platform is holding it. Neither
      // affects the next run: every session gets a path of its own.
    }
  }

  static int _serial = 0;

  /// Where helper databases live.
  ///
  /// `path_provider`'s temporary directory rather than `Directory.systemTemp`:
  /// on Android the latter is the process's idea of `/tmp`, which is not a
  /// directory an app is allowed to write to. The integration tests in `../`
  /// get away with it because they only ever run on a desktop.
  static Future<Directory> _databaseDirectory() async {
    final temporary = await getTemporaryDirectory();
    final directory = Directory(p.join(temporary.path, 'weft-e2e'));
    if (!directory.existsSync()) directory.createSync(recursive: true);
    return directory;
  }
}

/// A room made by a test, and the accounts that have to leave it afterwards.
///
/// Every scenario cleans up the rooms it made, because the homeserver is shared
/// across a whole matrix run: a room left behind is a row in the next row's
/// inbox, on a different device, where the failure is much harder to read.
class TestRoom {
  TestRoom(this.id, this.title, this.members);

  final String id;

  /// What the app's inbox calls this conversation.
  final String title;

  final List<TestAccount> members;

  Future<void> dispose() async {
    for (final member in members) {
      await member.leaveAndForget(id);
    }
  }
}

/// Creates an encrypted conversation between [creator] and [peer], joined.
///
/// [creator] is the app's own control session, so the app's device is a member
/// from the moment the room exists. Ordering matters and is not incidental: the
/// app must already be signed in before this is called, or its device keys will
/// not have been published and [peer] will encrypt the first messages to every
/// device *except* the one under test.
Future<TestRoom> createJoinedRoom({
  required TestAccount creator,
  required TestAccount peer,
  String title = 'E2E',
}) async {
  final name = uniqueBody(title);
  final roomId = await creator.createDirectRoom(peer, name: name);
  await peer.join(roomId);
  return TestRoom(roomId, name, [creator, peer]);
}

/// Drives the *responding* end of an interactive verification to completion.
///
/// The app is the initiator and is driven through its screen; this is the other
/// device, and it has no screen. Written as a state machine over `onUpdate`
/// rather than as a script because the two sides advance each other: which state
/// this end is in at any moment depends on what the app has just done, and a
/// fixed sequence would deadlock the first time the SDK skipped a step — which
/// it does, deliberately, when only one method is possible.
class SasResponder {
  SasResponder(this.verification) {
    verification.onUpdate = () => unawaited(_advance());
    unawaited(_advance());
  }

  /// Attaches to the next verification request [account] receives.
  ///
  /// Call it *before* the app starts verifying and await the returned future
  /// afterwards. The subscription is made synchronously — an async function's
  /// body runs up to its first `await`, and `.first` has already been evaluated
  /// by then — so a request that arrives while the tap is still settling is
  /// caught rather than missed.
  static Future<SasResponder> awaitRequest(
    TestAccount account, {
    Duration? within,
  }) async {
    final limit = within ?? kSyncDeadline;
    final request = await account.client.onKeyVerificationRequest.stream.first
        .timeout(
          limit,
          onTimeout: () => fail(
            '${account.localpart} never received a verification request '
            'within ${limit.inSeconds}s',
          ),
        );
    return SasResponder(request);
  }

  final KeyVerification verification;

  final Completer<KeyVerificationState> _finished =
      Completer<KeyVerificationState>();

  /// The names of the emoji this end was shown, in order.
  ///
  /// Empty until the SAS step. Names rather than glyphs because the name is
  /// what the app puts under each cell and what a screen reader announces — the
  /// two ends agreeing on "seven, screwdriver, cat" is the assertion, and it is
  /// stronger than agreeing on two identical pictures.
  List<String> emojiNames = const [];

  /// Completes with `done` or `error`, whichever the flow reaches.
  Future<KeyVerificationState> get finished => _finished.future;

  bool _acting = false;

  Future<void> _advance() async {
    // `onUpdate` can fire while an action from the previous one is still in
    // flight, and two `acceptSas` calls are a cancelled verification.
    if (_acting || _finished.isCompleted) return;
    _acting = true;
    try {
      switch (verification.state) {
        case KeyVerificationState.askAccept:
          await verification.acceptVerification();
          return;
        case KeyVerificationState.askChoice:
          // Emoji, always: the other end is a screen being tapped by a test,
          // and there is no camera on either side of this exchange.
          await chooseVerification(verification, VerificationChoice.emoji);
          return;
        case KeyVerificationState.askSSSS:
          // Cross-signing exists on the account but its secrets are not on this
          // device. Skipping still verifies the two devices against each other,
          // which is what the scenario is about; what it gives up is signing
          // them into the account's chain of trust.
          await verification.openSSSS(skip: true);
          return;
        case KeyVerificationState.askSas:
        case KeyVerificationState.waitingSas:
          emojiNames = verification.sasEmojis
              .map((emoji) => emoji.name)
              .toList(growable: false);
          if (verification.state == KeyVerificationState.askSas) {
            await verification.acceptSas();
          }
          return;
        case KeyVerificationState.done:
        case KeyVerificationState.error:
          if (!_finished.isCompleted) _finished.complete(verification.state);
          return;
        case KeyVerificationState.waitingAccept:
        case KeyVerificationState.showQRSuccess:
        case KeyVerificationState.confirmQRScan:
          // Nothing for this end to do; the app is being tapped.
          return;
      }
    } on Object catch (error) {
      if (!_finished.isCompleted) {
        _finished.completeError(
          StateError(
            'verification responder failed at ${verification.state}: $error',
          ),
        );
      }
    } finally {
      _acting = false;
    }
  }
}

/// The one device id that appeared on [account] since [before] was taken.
///
/// How a test learns which session on the homeserver is the app's, without
/// reaching into the app to ask. Insisting on *exactly* one is the point: two
/// would mean something else logged in during the window and the answer would be
/// a guess.
Future<String> newDeviceId(TestAccount account, Set<String> before) async {
  var added = const <String>{};
  await pollUntilAsync(() async {
    added = (await account.deviceIds()).difference(before);
    return added.length == 1;
  }, reason: 'exactly one new device to appear on ${account.userId}');
  return added.single;
}

/// Polls [ready] until it holds, or fails with [reason].
///
/// The counterpart to the UI's `pumpUntil`, for conditions that live below the
/// widget tree: a membership, a device list, a decrypted event. It yields to the
/// event loop rather than pumping frames, because the thing it waits on is a
/// socket and not a rebuild.
Future<void> pollUntil(
  bool Function() ready, {
  required String reason,
  Duration? within,
  Duration interval = const Duration(milliseconds: 200),
}) async {
  final limit = within ?? kSyncDeadline;
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (ready()) return;
    await Future<void>.delayed(interval);
  }
  if (ready()) return;
  fail('Timed out after ${limit.inSeconds}s waiting for $reason');
}

/// [pollUntil] for a condition that is itself a round trip.
Future<void> pollUntilAsync(
  Future<bool> Function() ready, {
  required String reason,
  Duration? within,
  Duration interval = const Duration(milliseconds: 500),
}) async {
  final limit = within ?? kSyncDeadline;
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (await ready()) return;
    await Future<void>.delayed(interval);
  }
  if (await ready()) return;
  fail('Timed out after ${limit.inSeconds}s waiting for $reason');
}
