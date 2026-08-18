import 'package:weft_call/weft_call.dart';

/// The instant every call in this suite starts from.
///
/// Pinned rather than taken from the wall clock because an invite's lifetime is
/// measured from the moment it was *sent*, and a suite whose result depended on
/// how long the test runner took to get here would be worse than no suite.
final DateTime t0 = DateTime.utc(2026, 8, 19, 12);

const String localUserId = '@me:example.org';

/// This device. MSC2746 identifies devices by `party_id`, so the tests use two
/// obviously different strings rather than anything that could be mistaken for
/// a user id.
const String localParty = 'DEVICE_A';

/// A second device of *this* user, for the multi-device answering tests.
const String otherLocalParty = 'DEVICE_B';

const String peerUserId = '@anna:example.org';
const String peerParty = 'THEIRS';

/// A second device of the *far end*, for the party-latching tests.
const String otherPeerParty = 'THEIRS_2';

const String roomId = '!room:example.org';
const String otherRoomId = '!other:example.org';

/// The same value as [roomId] under a second name, so a builder can take a
/// `roomId` parameter that defaults to it without shadowing it.
const String fixtureRoomId = roomId;

const CallPeer peer = CallPeer(matrixUserId: peerUserId, displayName: 'Anna');

const SessionDescription offerSdp = SessionDescription.offer('v=0 offer');
const SessionDescription answerSdp = SessionDescription.answer('v=0 answer');

/// The offer and answer of a renegotiation, kept distinct from the originals so
/// an assertion can tell which exchange a description belongs to.
const SessionDescription reofferSdp = SessionDescription.offer('v=0 reoffer');
const SessionDescription reanswerSdp = SessionDescription.answer(
  'v=0 reanswer',
);

/// A candidate named after the kind it stands in for, so an ordering assertion
/// reads as `[host, srflx, relay]` — which is also the order that matters.
IceCandidate ice(String name, {String mid = '0', int index = 0}) =>
    IceCandidate(
      candidate: 'candidate:$name',
      sdpMid: mid,
      sdpMLineIndex: index,
    );

/// MSC2746's end-of-candidates sentinel. Forwarded rather than dropped: a peer
/// that never learns gathering finished waits out its own ICE timeout.
const IceCandidate endOfCandidates = IceCandidate(candidate: '');

/// A [CallStateMachine] and the clock it reads.
///
/// Every deadline in a call is tens of seconds long, so no test may wait one.
/// [advance] is the whole reason this class exists: the machine is handed
/// `() => now` at construction and the test moves `now` by hand.
class CallHarness {
  CallHarness({
    this.partyId = localParty,
    this.userId = localUserId,
    Set<String> supportedVersions = const {'0', '1'},
    Duration endingGrace = const Duration(seconds: 5),
  }) {
    machine = CallStateMachine(
      localUserId: userId,
      localPartyId: partyId,
      clock: () => now,
      supportedVersions: supportedVersions,
      endingGrace: endingGrace,
    );
  }

  final String partyId;
  final String userId;

  DateTime now = t0;

  late final CallStateMachine machine;

  CallState get state => machine.state;

  CallSession? get session => machine.session;

  IceCandidateBuffer get remoteBuffer => machine.bufferedRemoteCandidates;

  void advance(Duration by) => now = now.add(by);

  CallTransition handle(CallInput input) => machine.handle(input);

  CallTransition tick() => machine.tick();

  // -------------------------------------------------------------------------
  // Drives. Each stops exactly where its name says, so a test that cares about
  // one step does not have to re-state the five before it.
  // -------------------------------------------------------------------------

  /// Place a call and get the invite on the wire. Returns the transition that
  /// carried [SendInvite].
  CallTransition placeCall({String callId = 'out-1', bool video = false}) {
    handle(PlaceCall(callId: callId, roomId: roomId, peer: peer, video: video));
    return handle(const LocalDescriptionReady(offerSdp));
  }

  /// Place a call, have the far end answer, and reach [CallState.connected].
  void outgoingConnected({
    String callId = 'out-1',
    bool video = false,
    CodecSummary? codecs,
  }) {
    placeCall(callId: callId, video: video);
    handle(answerFrom(callId: callId, video: video));
    handle(MediaConnected(codecs: codecs));
  }

  /// Take an invite and start ringing.
  CallTransition ring({
    String callId = 'in-1',
    bool video = false,
    DateTime? sentAt,
    String roomId = fixtureRoomId,
  }) {
    return handle(
      inviteFrom(
        callId: callId,
        video: video,
        sentAt: sentAt ?? now,
        roomId: roomId,
      ),
    );
  }

  /// Ring, accept, answer and reach [CallState.connected].
  void incomingConnected({String callId = 'in-1', bool video = false}) {
    ring(callId: callId, video: video);
    handle(AcceptCall(video: video));
    handle(const LocalDescriptionReady(answerSdp));
    handle(const MediaConnected());
  }
}

// ---------------------------------------------------------------------------
// Inbound signals, with everything the test does not care about defaulted.
// ---------------------------------------------------------------------------

CallInviteSignal inviteFrom({
  String callId = 'in-1',
  String partyId = peerParty,
  String senderId = peerUserId,
  String roomId = fixtureRoomId,
  SessionDescription offer = offerSdp,
  DateTime? sentAt,
  Duration lifetime = kDefaultInviteLifetime,
  bool video = false,
  String? invitee,
  String version = '1',
}) {
  return CallInviteSignal(
    callId: callId,
    partyId: partyId,
    senderId: senderId,
    roomId: roomId,
    offer: offer,
    sentAt: sentAt ?? t0,
    lifetime: lifetime,
    video: video,
    invitee: invitee,
    version: version,
  );
}

CallAnswerSignal answerFrom({
  String callId = 'out-1',
  String partyId = peerParty,
  String senderId = peerUserId,
  SessionDescription answer = answerSdp,
  bool video = false,
}) {
  return CallAnswerSignal(
    callId: callId,
    partyId: partyId,
    senderId: senderId,
    answer: answer,
    video: video,
  );
}

CallCandidatesSignal candidatesFrom(
  List<IceCandidate> candidates, {
  String callId = 'out-1',
  String partyId = peerParty,
  String senderId = peerUserId,
}) {
  return CallCandidatesSignal(
    callId: callId,
    partyId: partyId,
    senderId: senderId,
    candidates: candidates,
  );
}

CallHangupSignal hangupFrom({
  String callId = 'out-1',
  String partyId = peerParty,
  String senderId = peerUserId,
  String? reason,
}) {
  return CallHangupSignal(
    callId: callId,
    partyId: partyId,
    senderId: senderId,
    reason: reason,
  );
}

CallRejectSignal rejectFrom({
  String callId = 'out-1',
  String partyId = peerParty,
  String senderId = peerUserId,
  String? reason,
}) {
  return CallRejectSignal(
    callId: callId,
    partyId: partyId,
    senderId: senderId,
    reason: reason,
  );
}

CallSelectAnswerSignal selectAnswerFrom({
  String callId = 'in-1',
  String partyId = peerParty,
  String senderId = peerUserId,
  String selectedPartyId = localParty,
}) {
  return CallSelectAnswerSignal(
    callId: callId,
    partyId: partyId,
    senderId: senderId,
    selectedPartyId: selectedPartyId,
  );
}

CallNegotiateSignal negotiateFrom(
  SessionDescription description, {
  String callId = 'out-1',
  String partyId = peerParty,
  String senderId = peerUserId,
  bool video = true,
}) {
  return CallNegotiateSignal(
    callId: callId,
    partyId: partyId,
    senderId: senderId,
    description: description,
    video: video,
  );
}

// ---------------------------------------------------------------------------
// Assertion helpers.
// ---------------------------------------------------------------------------

/// The runtime types of a transition's intents, in order.
///
/// Order is part of the contract in several places — the glare loser's hangup
/// must precede its teardown, the camera must be enabled before the offer that
/// describes it — so the compact form asserts on the sequence rather than on
/// one intent at a time.
List<Type> typesOf(Iterable<CallIntent> intents) =>
    intents.map((intent) => intent.runtimeType).toList(growable: false);

/// The candidates carried by every [SendCandidates] in a transition, flattened
/// in the order they would reach the wire.
List<IceCandidate> sentCandidates(CallTransition transition) => [
  for (final intent in transition.signalling.whereType<SendCandidates>())
    ...intent.candidates,
];

/// The candidates handed to the media engine by a transition, in order.
List<IceCandidate> appliedCandidates(CallTransition transition) => [
  for (final intent in transition.media.whereType<AddRemoteCandidate>())
    intent.candidate,
];
