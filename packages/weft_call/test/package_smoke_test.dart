import 'package:test/test.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_domain/weft_domain.dart';

UnifiedContact _matrixContact() => const UnifiedContact(
  id: 'c1',
  displayName: 'Anna',
  handles: [
    NetworkHandle(
      id: 'h1',
      network: ChatNetwork.matrix,
      remoteId: '@anna:example.org',
      matrixUserId: '@anna:example.org',
      roomId: '!r:example.org',
    ),
  ],
);

UnifiedContact _bridgedOnlyContact() => const UnifiedContact(
  id: 'c2',
  displayName: 'Bea',
  handles: [
    NetworkHandle(
      id: 'h2',
      network: ChatNetwork.whatsapp,
      remoteId: '4915112345678',
      matrixUserId: '@whatsapp_4915112345678:example.org',
      roomId: '!w:example.org',
    ),
  ],
);

/// A deliberately small check that the package hangs together: an outgoing call
/// reaching `connected`, an incoming one reaching `connected`, glare picking a
/// winner, and the candidate buffer flushing in order.
///
/// The exhaustive suites the phase calls for — `state_machine_test.dart`,
/// `glare_test.dart`, `candidates_test.dart`, `negotiate_test.dart` — are the
/// next task. This one exists so the package is not committed unexecuted.
void main() {
  final t0 = DateTime.utc(2026, 8, 19, 12);
  var now = t0;
  DateTime clock() => now;

  CallStateMachine machineFor(String party) => CallStateMachine(
    localUserId: '@me:example.org',
    localPartyId: party,
    clock: clock,
  );

  const offer = SessionDescription.offer('v=0 offer');
  const answer = SessionDescription.answer('v=0 answer');
  const peer = CallPeer(matrixUserId: '@anna:example.org');

  setUp(() => now = t0);

  test('outgoing call reaches connected and pins the wire events', () {
    final machine = machineFor('DEV1');

    final placed = machine.handle(
      const PlaceCall(callId: 'abc', roomId: '!r:example.org', peer: peer),
    );
    expect(machine.state, CallState.outgoingRinging);
    expect(placed.media.single, isA<CreateOffer>());

    final invited = machine.handle(const LocalDescriptionReady(offer));
    final sendInvite = invited.signalling.single as SendInvite;
    expect(sendInvite.callId, 'abc');
    expect(sendInvite.partyId, 'DEV1');
    expect(sendInvite.lifetime, kDefaultInviteLifetime);

    final answered = machine.handle(
      const CallAnswerSignal(
        callId: 'abc',
        partyId: 'THEIRS',
        senderId: '@anna:example.org',
        answer: answer,
      ),
    );
    expect(answered.signalling.single, isA<SendSelectAnswer>());
    expect(
      (answered.signalling.single as SendSelectAnswer).selectedPartyId,
      'THEIRS',
    );
    expect(machine.state, CallState.connecting);

    now = t0.add(const Duration(seconds: 3));
    machine.handle(const MediaConnected(codecs: CodecSummary(audio: 'opus')));
    expect(machine.state, CallState.connected);
    expect(machine.session!.connectedAt, t0.add(const Duration(seconds: 3)));

    now = t0.add(const Duration(seconds: 63));
    expect(machine.session!.durationAt(now), const Duration(seconds: 60));

    final hungUp = machine.handle(const HangUp());
    expect((hungUp.signalling.single as SendHangup).reason.wireReason,
        'user_hangup');
    expect(machine.state, CallState.ending);
    machine.handle(const MediaDisposed());
    expect(machine.state, CallState.ended);
    expect(machine.session!.endReason, CallEndReason.userHangup);
  });

  test('incoming call rings, answers, and buffers early candidates in order', () {
    final machine = machineFor('DEV1');
    const early = [
      IceCandidate(candidate: 'host', sdpMid: '0', sdpMLineIndex: 0),
      IceCandidate(candidate: 'srflx', sdpMid: '0', sdpMLineIndex: 0),
      IceCandidate(candidate: 'relay', sdpMid: '0', sdpMLineIndex: 0),
    ];

    machine.handle(
      CallInviteSignal(
        callId: 'abc',
        partyId: 'THEIRS',
        senderId: '@anna:example.org',
        roomId: '!r:example.org',
        offer: offer,
        sentAt: t0,
      ),
    );
    expect(machine.state, CallState.ringing);

    // Candidates ahead of the answer are held, not dropped.
    final buffered = machine.handle(
      const CallCandidatesSignal(
        callId: 'abc',
        partyId: 'THEIRS',
        senderId: '@anna:example.org',
        candidates: early,
      ),
    );
    expect(buffered.media, isEmpty);
    expect(machine.bufferedRemoteCandidates.length, 3);

    final accepted = machine.handle(const AcceptCall());
    expect(accepted.media.first, isA<CreateAnswer>());
    expect(
      accepted.media.whereType<AddRemoteCandidate>().map((i) => i.candidate),
      orderedEquals(early),
    );

    final sent = machine.handle(const LocalDescriptionReady(answer));
    expect(sent.signalling.single, isA<SendAnswer>());

    machine.handle(const MediaConnected());
    expect(machine.state, CallState.connected);
  });

  test('glare leaves exactly one call alive, and both sides agree which', () {
    // 'aaa' < 'bbb', so the call with id 'aaa' survives on both sides.
    final lower = machineFor('DEV-A');
    lower.handle(
      const PlaceCall(callId: 'aaa', roomId: '!r:example.org', peer: peer),
    );
    lower.handle(const LocalDescriptionReady(offer));

    final higher = machineFor('DEV-B');
    higher.handle(
      const PlaceCall(callId: 'bbb', roomId: '!r:example.org', peer: peer),
    );
    higher.handle(const LocalDescriptionReady(offer));

    // A receives B's invite: theirs is higher, so A kills theirs and keeps 'aaa'.
    final atA = lower.handle(
      CallInviteSignal(
        callId: 'bbb',
        partyId: 'DEV-B',
        senderId: '@anna:example.org',
        roomId: '!r:example.org',
        offer: offer,
        sentAt: t0,
      ),
    );
    expect((atA.signalling.single as SendHangup).callId, 'bbb');
    expect(lower.state, CallState.outgoingRinging);
    expect(lower.session!.callId, 'aaa');

    // B receives A's invite: theirs is lower, so B abandons 'bbb' and rings.
    final atB = higher.handle(
      CallInviteSignal(
        callId: 'aaa',
        partyId: 'DEV-A',
        senderId: '@anna:example.org',
        roomId: '!r:example.org',
        offer: offer,
        sentAt: t0,
      ),
    );
    expect((atB.signalling.single as SendHangup).callId, 'bbb');
    expect(higher.state, CallState.ringing);
    expect(higher.session!.callId, 'aaa');
  });

  test('an invite older than its lifetime never rings', () {
    final machine = machineFor('DEV1');
    now = t0.add(const Duration(minutes: 5));
    final result = machine.handle(
      CallInviteSignal(
        callId: 'abc',
        partyId: 'THEIRS',
        senderId: '@anna:example.org',
        roomId: '!r:example.org',
        offer: offer,
        sentAt: t0,
      ),
    );
    expect(result.isNoOp, isTrue);
    expect(machine.state, CallState.idle);
  });

  test('candidates after hangup are discarded and counted', () {
    final machine = machineFor('DEV1');
    machine.handle(
      const PlaceCall(callId: 'abc', roomId: '!r:example.org', peer: peer),
    );
    machine.handle(const LocalDescriptionReady(offer));
    machine.handle(const HangUp());

    final late = machine.handle(
      const CallCandidatesSignal(
        callId: 'abc',
        partyId: 'THEIRS',
        senderId: '@anna:example.org',
        candidates: [IceCandidate(candidate: 'relay')],
      ),
    );
    expect(late.media, isEmpty);
    expect(machine.bufferedRemoteCandidates.droppedCount, 1);
  });

  test('an audio call upgraded to video survives a failed renegotiation', () {
    final machine = machineFor('DEV1');
    machine.handle(
      const PlaceCall(callId: 'abc', roomId: '!r:example.org', peer: peer),
    );
    machine.handle(const LocalDescriptionReady(offer));
    machine.handle(
      const CallAnswerSignal(
        callId: 'abc',
        partyId: 'THEIRS',
        senderId: '@anna:example.org',
        answer: answer,
      ),
    );
    machine.handle(const MediaConnected());

    final asked = machine.handle(const RequestVideoUpgrade());
    expect(asked.media.map((i) => i.runtimeType),
        containsAll(<Type>[ApplyVideo, CreateOffer]));

    final negotiated = machine.handle(
      const LocalDescriptionReady(SessionDescription.offer('v=0 video')),
    );
    expect(negotiated.signalling.single, isA<SendNegotiate>());
    expect(machine.session!.videoEnabled, isFalse, reason: 'not yet agreed');

    machine.handle(const NegotiationFailed());
    expect(machine.state, CallState.connected);
    expect(machine.session!.videoEnabled, isFalse);
  });

  test('CallPeer.forContact refuses a contact with no Matrix leg', () {
    expect(CallPeer.forContact(_bridgedOnlyContact()), isNull);
    expect(
      CallPeer.forContact(_matrixContact())!.matrixUserId,
      '@anna:example.org',
    );
  });
}
