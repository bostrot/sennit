import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/call/call_audio.dart';
import 'package:weft/services/call/call_service.dart';
import 'package:weft/services/call/sdp_codecs.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// A deliberately small suite, in the shape `weft_call`'s own smoke test took:
/// it exists so this layer is not committed unexecuted, and it does **not**
/// pre-empt the four app-level suites the phase asks for next
/// (`call_service_test.dart`, `call_screen_test.dart`, `incoming_call_test.dart`
/// and `call_availability_test.dart`), which subsume it.
///
/// What is worth pinning here is the seam rather than the rules: the rules are
/// `weft_call`'s and already have 114 tests. These assert that the intents come
/// out of the machine and land on the right collaborator — the wire, the engine,
/// the audio session — and that the two deadlines the machine deliberately
/// leaves open are actually closed by this layer.
void main() {
  group('outgoing call', () {
    test('places, connects and hangs up', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      final failure = await harness.service.placeCall(roomId: room, peer: peer);
      await pumpEventQueue();

      expect(failure, isNull);
      expect(harness.engine.calls, contains('createOffer(video: false)'));

      // The invite is the whole contract with the far end: the right room, an
      // offer, a party id and an invitee, which is what stops a bridge bot in
      // the room from being rung as well.
      final invite = harness.sink.sent.single;
      expect(invite.type, 'm.call.invite');
      expect(invite.roomId, room);
      expect(invite.content['call_id'], 'call-1');
      expect(invite.content['party_id'], 'DEVICE');
      expect(invite.content['invitee'], peer.matrixUserId);
      expect((invite.content['offer']! as Map)['type'], 'offer');

      harness.signal(
        CallAnswerSignal(
          callId: 'call-1',
          partyId: 'THEIRS',
          senderId: peer.matrixUserId,
          answer: const SessionDescription.answer(answerSdp),
        ),
      );
      await pumpEventQueue();

      // Committing to one answering device before anything else is what stops
      // a second device of theirs from staying in the call.
      expect(harness.sink.types, ['m.call.invite', 'm.call.select_answer']);
      expect(harness.service.state.session?.state, CallState.connecting);

      harness.engine.codecs = const CodecSummary(audio: 'opus');
      harness.engine.states.add(MediaConnectionState.connected);
      await pumpEventQueue();

      final connected = harness.service.state.session!;
      expect(connected.state, CallState.connected);
      expect(connected.codecs?.audio, 'opus');

      await harness.service.hangUp();
      await pumpEventQueue();

      expect(harness.sink.types.last, 'm.call.hangup');
      expect(harness.engine.disposed, isTrue);
      expect(harness.service.state.session?.state, CallState.ended);
      expect(
        harness.service.state.session?.endReason,
        CallEndReason.userHangup,
      );
    });

    test('a second call is refused while one is in progress', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      expect(await harness.service.placeCall(roomId: room, peer: peer), isNull);
      await pumpEventQueue();

      expect(
        await harness.service.placeCall(
          roomId: '!other:example.org',
          peer: peer,
        ),
        CallStartFailure.busy,
      );
      // Nothing reached the wire for the second attempt.
      expect(harness.sink.types, ['m.call.invite']);
    });

    test('a homeserver with no relay is a warning, not a refusal', () async {
      final harness = CallHarness(
        ice: const IceConfiguration(
          availability: TurnAvailability.notConfigured,
          warning: 'Your homeserver provides no call relay.',
        ),
      );
      addTearDown(harness.dispose);

      expect(await harness.service.placeCall(roomId: room, peer: peer), isNull);
      await pumpEventQueue();

      // The call is placed anyway — it still works on one network — but the
      // sentence the SDK swallows is on the state the call screen reads.
      expect(harness.sink.types, ['m.call.invite']);
      expect(harness.service.state.warning, contains('no call relay'));
      expect(harness.service.state.ice?.hasTurn, isFalse);
    });
  });

  group('incoming call', () {
    test('rings, answers and puts the answer in the invite\'s room', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.signal(harness.invite());
      await pumpEventQueue();

      // Ringing opens nothing: the microphone is not touched until the call is
      // answered.
      expect(harness.service.state.session?.state, CallState.ringing);
      expect(harness.engine.calls, isEmpty);

      await harness.service.accept();
      await pumpEventQueue();

      expect(harness.engine.calls.first, 'createAnswer(video: false)');
      expect(harness.sink.types, ['m.call.answer']);
      expect(harness.sink.sent.single.roomId, room);
    });

    test('a second invite is rejected in its own room, not the call\'s', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: peer);
      await pumpEventQueue();

      // The busy reject is the one outbound event that belongs to a *different*
      // room from the active call. Addressing it to the call's room would leave
      // the second caller ringing until their invite expired.
      harness.signal(
        harness.invite(callId: 'call-2', roomId: '!elsewhere:example.org'),
      );
      await pumpEventQueue();

      final reject = harness.sink.sent.last;
      expect(reject.type, 'm.call.reject');
      expect(reject.roomId, '!elsewhere:example.org');
      expect(reject.content['call_id'], 'call-2');
      expect(reject.content['reason'], 'user_busy');
      // The call in progress is untouched.
      expect(harness.service.state.session?.callId, 'call-1');
    });
  });

  group('deadlines the state machine leaves open', () {
    test('a call that never connects is ended as an ICE failure', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: peer);
      await pumpEventQueue();
      harness.signal(
        CallAnswerSignal(
          callId: 'call-1',
          partyId: 'THEIRS',
          senderId: peer.matrixUserId,
          answer: const SessionDescription.answer(answerSdp),
        ),
      );
      await pumpEventQueue();
      expect(harness.service.state.session?.state, CallState.connecting);

      // Nothing in `weft_call` ends a call stuck here; without this layer's
      // timeout it would ring silently forever.
      harness.advance(const Duration(seconds: 31));
      await harness.tick();

      expect(harness.service.state.session?.endReason, CallEndReason.iceFailed);
      expect(harness.sink.types.last, 'm.call.hangup');
      expect(harness.sink.sent.last.content['reason'], 'ice_failed');
    });

    test('a disconnected peer connection is given time to heal', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: peer);
      await pumpEventQueue();
      harness.signal(
        CallAnswerSignal(
          callId: 'call-1',
          partyId: 'THEIRS',
          senderId: peer.matrixUserId,
          answer: const SessionDescription.answer(answerSdp),
        ),
      );
      await pumpEventQueue();
      harness.engine.states.add(MediaConnectionState.connected);
      await pumpEventQueue();

      harness.engine.states.add(MediaConnectionState.disconnected);
      await pumpEventQueue();
      harness.advance(const Duration(seconds: 5));
      await harness.tick();
      // A phone changing network does this every time. Ending here would drop
      // calls that were about to recover.
      expect(harness.service.state.session?.state, CallState.connected);

      harness.engine.states.add(MediaConnectionState.connected);
      await pumpEventQueue();
      harness.advance(const Duration(seconds: 60));
      await harness.tick();
      expect(harness.service.state.session?.state, CallState.connected);
    });
  });

  group('audio routing', () {
    test('a voice call uses the earpiece and the proximity sensor', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: peer);
      await pumpEventQueue();

      expect(harness.audio.applied.last, CallAudioRoute.earpiece);
      expect(harness.service.state.audio.proximityActive, isTrue);
      expect(harness.audio.proximity, isTrue);
    });

    test('a video call uses the speaker and leaves the screen on', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: peer, video: true);
      await pumpEventQueue();

      expect(harness.audio.applied.last, CallAudioRoute.speaker);
      expect(harness.service.state.audio.proximityActive, isFalse);
      // The session's own speaker flag follows the route, so the call screen's
      // speaker button cannot disagree with where the sound is going.
      expect(harness.service.state.session?.speakerOn, isTrue);
    });

    test('unplugging a headset falls back instead of shouting', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.audio.routes.add({
        CallAudioRoute.earpiece,
        CallAudioRoute.speaker,
        CallAudioRoute.wiredHeadset,
      });
      await pumpEventQueue();
      await harness.service.placeCall(roomId: room, peer: peer);
      await pumpEventQueue();
      expect(harness.audio.applied.last, CallAudioRoute.wiredHeadset);

      harness.audio.routes.add({
        CallAudioRoute.earpiece,
        CallAudioRoute.speaker,
      });
      await pumpEventQueue();

      expect(harness.audio.applied.last, CallAudioRoute.earpiece);
      expect(harness.service.state.audio.route, CallAudioRoute.earpiece);
    });

    test('the audio session is released when the call ends', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: peer);
      await pumpEventQueue();
      await harness.service.hangUp();
      await pumpEventQueue();

      expect(harness.audio.stopped, isTrue);
      expect(harness.audio.proximity, isFalse);
    });
  });

  group('route policy', () {
    test('an attached headset outranks both defaults', () {
      expect(
        resolveCallAudioRoute(
          video: true,
          available: const {
            CallAudioRoute.earpiece,
            CallAudioRoute.speaker,
            CallAudioRoute.bluetooth,
          },
        ),
        CallAudioRoute.bluetooth,
      );
    });

    test('an explicit choice wins while the route exists', () {
      const available = {CallAudioRoute.earpiece, CallAudioRoute.speaker};
      expect(
        resolveCallAudioRoute(
          video: true,
          available: available,
          preferred: CallAudioRoute.earpiece,
        ),
        CallAudioRoute.earpiece,
      );
      // The same choice against a device that no longer offers it: the call
      // falls back rather than routing at nothing.
      expect(
        resolveCallAudioRoute(
          video: false,
          available: available,
          preferred: CallAudioRoute.bluetooth,
        ),
        CallAudioRoute.earpiece,
      );
    });

    test('a device with no receiver still has an answer', () {
      expect(
        resolveCallAudioRoute(
          video: false,
          available: const {CallAudioRoute.speaker},
        ),
        CallAudioRoute.speaker,
      );
    });

    test('platform device labels read as routes', () {
      expect(
        callAudioRouteForDevice('Bluetooth SCO'),
        CallAudioRoute.bluetooth,
      );
      expect(
        callAudioRouteForDevice('Wired Headphones'),
        CallAudioRoute.wiredHeadset,
      );
      expect(callAudioRouteForDevice('Speakerphone'), CallAudioRoute.speaker);
      expect(callAudioRouteForDevice('Earpiece'), CallAudioRoute.earpiece);
      // An unrecognised output is null rather than a guess — offering a route
      // that turns out to be a virtual sound card is worse than not offering
      // it.
      expect(callAudioRouteForDevice('Loopback (virtual)'), isNull);
    });
  });

  group('negotiated codecs', () {
    test('are read from the answer, per media section', () {
      final codecs = codecSummaryFromSdp(answerSdp);
      expect(codecs?.audio, 'opus');
      expect(codecs?.video, 'VP8');
      expect(codecs?.label, 'opus / VP8');
    });

    test('a rejected media section names no codec', () {
      const downgraded = '''
v=0
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=rtpmap:111 opus/48000/2
m=video 0 UDP/TLS/RTP/SAVPF 96
a=rtpmap:96 VP8/90000
''';
      final codecs = codecSummaryFromSdp(downgraded);
      expect(codecs?.audio, 'opus');
      expect(codecs?.video, isNull);
    });

    test('unreadable SDP leaves the existing summary alone', () {
      expect(codecSummaryFromSdp('v=0\r\no=- 0 0 IN IP4 0.0.0.0'), isNull);
    });
  });
}

const String room = '!room:example.org';
const CallPeer peer = CallPeer(
  matrixUserId: '@bob:example.org',
  displayName: 'Bob',
);

const String offerSdp = '''
v=0
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=rtpmap:111 opus/48000/2
''';

const String answerSdp = '''
v=0
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=rtpmap:111 opus/48000/2
m=video 9 UDP/TLS/RTP/SAVPF 96
a=rtpmap:96 VP8/90000
''';

/// The service, its collaborators and the clock it reads, in one place.
///
/// The same trick `weft_call`'s `CallHarness` plays and for the same reason:
/// every deadline in a call is tens of seconds long, so a test that used real
/// time would take a minute per assertion.
class CallHarness {
  CallHarness({IceConfiguration ice = _turnAvailable}) {
    service = CallService(
      signalling: MatrixCallSignalling(
        localUserId: '@me:example.org',
        localPartyId: 'DEVICE',
        sink: sink,
      ),
      iceConfiguration: () async => ice,
      createEngine: (_) async => engine,
      signals: signals.stream,
      audio: audio,
      ticks: ticks.stream,
      clock: () => now,
      generateCallId: () => 'call-1',
    );
  }

  static const IceConfiguration _turnAvailable = IceConfiguration(
    availability: TurnAvailability.available,
    servers: [
      {
        'urls': ['turn:relay.example.org'],
        'username': 'u',
        'credential': 'p',
      },
    ],
  );

  DateTime now = DateTime.utc(2026, 8, 19, 12);

  final RecordingSink sink = RecordingSink();
  final FakeMediaEngine engine = FakeMediaEngine();
  final RecordingAudio audio = RecordingAudio();
  final StreamController<CallSignal> signals =
      StreamController<CallSignal>.broadcast();
  final StreamController<void> ticks = StreamController<void>.broadcast();

  late final CallService service;

  void signal(CallSignal signal) => signals.add(signal);

  /// An invite from the far end, sent just now so it has not expired.
  CallInviteSignal invite({String callId = 'call-9', String roomId = room}) =>
      CallInviteSignal(
        callId: callId,
        partyId: 'THEIRS',
        senderId: peer.matrixUserId,
        roomId: roomId,
        offer: const SessionDescription.offer(offerSdp),
        sentAt: now,
      );

  void advance(Duration by) => now = now.add(by);

  Future<void> tick() async {
    ticks.add(null);
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    await service.dispose();
    await signals.close();
    await ticks.close();
    await engine.close();
    await audio.close();
  }
}

/// One event as it reached the wire.
class SentEvent {
  const SentEvent(this.roomId, this.type, this.content);

  final String roomId;
  final String type;
  final Map<String, Object?> content;
}

class RecordingSink implements MatrixCallEventSink {
  final List<SentEvent> sent = [];

  List<String> get types => [for (final event in sent) event.type];

  @override
  Future<void> send({
    required String roomId,
    required String type,
    required Map<String, Object?> content,
  }) async {
    sent.add(SentEvent(roomId, type, content));
  }
}

class FakeMediaEngine implements MediaEngine {
  final List<String> calls = [];
  final StreamController<IceCandidate> candidates =
      StreamController<IceCandidate>.broadcast();
  final StreamController<MediaConnectionState> states =
      StreamController<MediaConnectionState>.broadcast();

  bool disposed = false;
  CodecSummary? codecs;

  @override
  CodecSummary? get negotiatedCodecs => codecs;

  @override
  Stream<IceCandidate> get localCandidates => candidates.stream;

  @override
  Stream<MediaConnectionState> get connectionState => states.stream;

  @override
  Future<SessionDescription> createOffer({required bool video}) async {
    calls.add('createOffer(video: $video)');
    return SessionDescription.offer(video ? answerSdp : offerSdp);
  }

  @override
  Future<SessionDescription> createAnswer(
    SessionDescription remoteOffer, {
    required bool video,
  }) async {
    calls.add('createAnswer(video: $video)');
    return const SessionDescription.answer(answerSdp);
  }

  @override
  Future<void> applyRemoteDescription(SessionDescription description) async {
    calls.add('applyRemoteDescription(${description.type.wireType})');
  }

  @override
  Future<void> addCandidate(IceCandidate candidate) async {
    calls.add('addCandidate(${candidate.candidate})');
  }

  @override
  Future<void> setMute(bool muted) async => calls.add('setMute($muted)');

  @override
  Future<void> setVideo(bool enabled) async => calls.add('setVideo($enabled)');

  @override
  Future<void> switchCamera() async => calls.add('switchCamera()');

  @override
  Future<void> dispose() async {
    disposed = true;
    calls.add('dispose()');
  }

  Future<void> close() async {
    await candidates.close();
    await states.close();
  }
}

class RecordingAudio implements CallAudioController {
  final List<CallAudioRoute> applied = [];
  final StreamController<Set<CallAudioRoute>> routes =
      StreamController<Set<CallAudioRoute>>.broadcast();

  Set<CallAudioRoute> offered = const {
    CallAudioRoute.earpiece,
    CallAudioRoute.speaker,
  };
  bool proximity = false;
  bool stopped = false;

  @override
  Stream<Set<CallAudioRoute>> get available => routes.stream;

  @override
  Future<Set<CallAudioRoute>> refresh() async => offered;

  @override
  Future<void> apply(CallAudioRoute route) async => applied.add(route);

  @override
  Future<void> setProximityEnabled({required bool enabled}) async {
    proximity = enabled;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    proximity = false;
  }

  @override
  Future<void> dispose() async {}

  Future<void> close() async => routes.close();
}
