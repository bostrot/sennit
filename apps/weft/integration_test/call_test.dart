import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:path/path.dart' as p;
import 'package:weft/services/call/call_service.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../test/support/call_fixtures.dart' show FakeMediaEngine, offerSdp;

/// A real call between two real accounts, on the local Synapse from
/// `tooling/docker`.
///
///   docker compose -f tooling/docker/compose.yaml up -d --wait
///   ./tooling/docker/seed.sh
///   cd apps/weft && flutter test integration_test/call_test.dart -d macos
///
/// **What is real here and what is not**, because the distinction is the whole
/// value of the file. Real: two logins, an encrypted room, and every
/// `m.call.*` event going out through `MatrixCallEventSink` — encrypted with a
/// live Olm/Megolm session — down the far end's `/sync`, back up through
/// `MatrixCallSignalling.signalsFrom` and into a second `CallStateMachine`.
/// Both `CallService`s are the production class. The homeserver's TURN endpoint
/// is asked the real question and its answer is asserted rather than mocked.
///
/// Not real: the media. Both engines are [FakeMediaEngine], so the SDP crossing
/// the wire is a fixture and no packet of audio is captured or sent. Opening a
/// microphone needs a TCC grant that only a person at the keyboard can give,
/// and a test that stops on a permission dialog is worse than one that says
/// plainly what it did not do. `webrtc_media_engine.dart` is covered by
/// `test/call_service_test.dart` against a fake peer connection; the one thing
/// nothing in this repository can prove is that two devices hear each other.
///
/// So: this establishes that Weft's signalling is wire-correct against a real
/// homeserver, including through encryption, and that a call ends up
/// `connected` on both sides for the right reasons.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const homeserver = String.fromEnvironment(
    'WEFT_HOMESERVER',
    defaultValue: 'localhost:8008',
  );
  const password = String.fromEnvironment(
    'WEFT_TEST_PASSWORD',
    defaultValue: 'weft-test-password',
  );

  // Own database file per session, for the reason `matrix_session_test.dart`
  // records: sqflite hands two `:memory:` opens the same database, and the
  // second client then restores the first one's stored session.
  final tempRoot = Directory.systemTemp.createTempSync('weft-call-it-');
  tearDownAll(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  var sessionCounter = 0;
  WeftMatrixSession newSession(String label) {
    final path = p.join(tempRoot.path, '$label-${sessionCounter++}.sqlite');
    return WeftMatrixSession(
      clientName: 'weft-call-$label',
      deviceDisplayName: 'Weft call integration test',
      databaseOverride: () async => sdk.MatrixSdkDatabase.init(
        'weft-call-$label',
        database: await openWeftSqfliteDatabase(path),
      ),
    );
  }

  Future<WeftMatrixSession> signIn(String user) async {
    final session = newSession(user);
    addTearDown(session.dispose);
    await session.initialize();
    await session.checkHomeserver(homeserver);
    await session.loginWithPassword(username: user, password: password);
    return session;
  }

  group('TURN', () {
    test(
      'the homeserver is asked, and its answer is a sentence',
      () async {
        final alice = await signIn('alice');
        final turn = MatrixTurnServers.forClient(alice.client);

        final ice = await turn.configuration();

        // Never a throw: a call with no relay still works on one network, so the
        // failure is a warning to show rather than a reason to refuse to dial.
        expect(ice.availability, isA<TurnAvailability>());
        if (ice.hasTurn) {
          expect(ice.servers, isNotEmpty);
          expect(ice.warning, isNull);
        } else {
          expect(ice.servers, isEmpty);
          expect(
            ice.warning,
            isNotNull,
            reason: 'a call that may not connect must say so',
          );
        }
        // ignore: avoid_print
        print(
          'TURN on $homeserver: ${ice.availability.name} '
          '(${ice.servers.length} server(s)) — ${ice.warning ?? 'no warning'}',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('a call between two accounts', () {
    test(
      'alice calls bob in an encrypted room and both sides connect',
      () async {
        final alice = await signIn('alice');
        final bob = await signIn('bob');

        final roomId = await alice.client.createRoom(
          invite: ['@bob:localhost'],
          isDirect: true,
          preset: sdk.CreateRoomPreset.trustedPrivateChat,
        );
        final aliceRoom = await _awaitRoom(alice.client, roomId);
        await aliceRoom.enableEncryption();
        await bob.client.joinRoomById(roomId);
        final bobRoom = await _awaitRoom(bob.client, roomId);
        // `m.room.encryption` is a state event and reaches both sides through
        // /sync like any other — alice's own included, so it is not there the
        // instant `enableEncryption` returns, nor the instant bob has joined.
        await _awaitCondition(
          () => aliceRoom.encrypted,
          'alice never saw the room turn encrypted',
        );
        await _awaitCondition(
          () => bobRoom.encrypted,
          'bob never saw the room turn encrypted',
        );

        final aliceCall = _Party(alice.client);
        final bobCall = _Party(bob.client);
        addTearDown(aliceCall.dispose);
        addTearDown(bobCall.dispose);

        // --- the invite -----------------------------------------------------
        final failure = await aliceCall.service.placeCall(
          roomId: roomId,
          peer: CallPeer(matrixUserId: '@bob:localhost', displayName: 'Bob'),
        );
        expect(failure, isNull, reason: 'the invite could not be placed');
        expect(aliceCall.state, CallState.outgoingRinging);

        await _awaitState(bobCall, CallState.ringing, 'bob never rang');
        expect(bobCall.session!.peer.matrixUserId, '@alice:localhost');
        expect(bobCall.session!.direction, CallDirection.incoming);
        expect(bobCall.session!.callId, aliceCall.session!.callId);

        // --- the answer -----------------------------------------------------
        await bobCall.service.accept();
        await _awaitState(
          aliceCall,
          CallState.connecting,
          'the answer never reached alice',
        );
        expect(
          aliceCall.engine.calls,
          contains('applyRemoteDescription(answer)'),
          reason: "bob's SDP must reach alice's peer connection",
        );

        // --- candidates, in both directions ---------------------------------
        aliceCall.engine.candidates.add(_candidate('alice-host'));
        bobCall.engine.candidates.add(_candidate('bob-host'));
        await _awaitCondition(
          () =>
              bobCall.engine.applied.contains('candidate:alice-host') &&
              aliceCall.engine.applied.contains('candidate:bob-host'),
          'candidates did not cross the wire',
        );

        // --- media, as the engines would report it --------------------------
        aliceCall.engine.states.add(MediaConnectionState.connected);
        bobCall.engine.states.add(MediaConnectionState.connected);
        await _awaitState(
          aliceCall,
          CallState.connected,
          'alice never connected',
        );
        await _awaitState(bobCall, CallState.connected, 'bob never connected');

        // --- hang up --------------------------------------------------------
        await aliceCall.service.hangUp();
        await _awaitCondition(
          () => bobCall.session?.state == CallState.ended,
          'the hangup never reached bob',
        );
        expect(bobCall.session!.endReason, CallEndReason.remoteHangup);
        expect(bobCall.engine.disposed, isTrue);
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'bob declines, and alice is told he declined',
      () async {
        final alice = await signIn('alice');
        final bob = await signIn('bob');

        final roomId = await alice.client.createRoom(
          invite: ['@bob:localhost'],
          isDirect: true,
          preset: sdk.CreateRoomPreset.trustedPrivateChat,
        );
        await _awaitRoom(alice.client, roomId);
        await bob.client.joinRoomById(roomId);
        await _awaitRoom(bob.client, roomId);

        final aliceCall = _Party(alice.client);
        final bobCall = _Party(bob.client);
        addTearDown(aliceCall.dispose);
        addTearDown(bobCall.dispose);

        await aliceCall.service.placeCall(
          roomId: roomId,
          peer: CallPeer(matrixUserId: '@bob:localhost'),
        );
        await _awaitState(bobCall, CallState.ringing, 'bob never rang');

        await bobCall.service.decline();
        await _awaitCondition(
          () => aliceCall.session?.state == CallState.ended,
          'the reject never reached alice',
        );
        // The whole point of `m.call.reject` over `m.call.hangup`: only this
        // tells the caller a person refused rather than a network gave up.
        expect(aliceCall.session!.endReason, CallEndReason.remoteReject);
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });
}

/// One end of a call: the production [CallService], with a fake peer
/// connection and the real Matrix signalling for the given client.
class _Party {
  _Party(sdk.Client client)
    : _signalling = MatrixCallSignalling.forClient(client),
      _turn = MatrixTurnServers.forClient(client) {
    service = CallService(
      signalling: _signalling,
      iceConfiguration: _turn.configuration,
      createEngine: (_) async => engine,
      signals: _signalling.signalsFrom(client.onCallEvents.stream),
    );
  }

  final MatrixCallSignalling _signalling;
  final MatrixTurnServers _turn;

  /// Audio-only on both sides. [FakeMediaEngine.createAnswer] answers with the
  /// two-section fixture, which the far end would read as a video call —
  /// `sdpOffersVideo` looks at the SDP rather than at a flag, exactly as the
  /// wire requires, so an audio call needs an audio answer.
  final _AudioOnlyEngine engine = _AudioOnlyEngine();

  late final CallService service;

  CallSession? get session => service.state.session;
  CallState? get state => session?.state;

  Future<void> dispose() async {
    await service.dispose();
    await engine.close();
  }
}

class _AudioOnlyEngine extends FakeMediaEngine {
  @override
  Future<SessionDescription> createAnswer(
    SessionDescription remoteOffer, {
    required bool video,
  }) async {
    await super.createAnswer(remoteOffer, video: video);
    return const SessionDescription.answer(offerSdp);
  }
}

IceCandidate _candidate(String name) =>
    IceCandidate(candidate: 'candidate:$name', sdpMid: '0', sdpMLineIndex: 0);

/// Waits for a room to appear in the client's room list after sync.
Future<sdk.Room> _awaitRoom(sdk.Client client, String roomId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final room = client.getRoomById(roomId);
    if (room != null) return room;
    await client.oneShotSync();
  }
  throw StateError('Room $roomId never arrived');
}

Future<void> _awaitState(_Party party, CallState state, String reason) =>
    _awaitCondition(() => party.state == state, '$reason (was ${party.state})');

/// Polls rather than listening, because what is being waited for arrives
/// through a real `/sync` and a real homeserver rather than through a
/// controller this test can pump.
Future<void> _awaitCondition(
  bool Function() ready,
  String reason, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail(reason);
}
