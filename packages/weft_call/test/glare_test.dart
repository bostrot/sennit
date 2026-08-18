import 'package:test/test.dart';
import 'package:weft_call/weft_call.dart';

import 'support/fixtures.dart';

/// Two people pressing call at the same moment.
///
/// The failure this prevents is not subtle — both phones ring, both people
/// answer, and neither can hear the other, because each is talking into a peer
/// connection the far end abandoned. Exactly one call has to survive, and both
/// sides have to pick the same one without being able to ask each other.
///
/// The rule is a lexical comparison of `call_id`, lowest wins. That it is
/// deterministic is not enough on its own: the far end is usually Element, and
/// a rule Element does not share resolves glare into two dead calls instead of
/// one live one. This is the Matrix SDK's rule, and these tests exist mostly to
/// stop it being "simplified" into a different one.
void main() {
  /// Both sides of one collision, wired to each other's call ids.
  ///
  /// `low` placed the call with the lexically smaller id, so `low` is the side
  /// whose call must survive on *both* machines.
  ({CallHarness low, CallHarness high}) collide({
    String lowId = 'aaa',
    String highId = 'bbb',
    String room = roomId,
  }) {
    final low = CallHarness(partyId: 'DEVICE_LOW')
      ..handle(PlaceCall(callId: lowId, roomId: room, peer: peer))
      ..handle(const LocalDescriptionReady(offerSdp));
    final high = CallHarness(partyId: 'DEVICE_HIGH')
      ..handle(PlaceCall(callId: highId, roomId: room, peer: peer))
      ..handle(const LocalDescriptionReady(offerSdp));
    return (low: low, high: high);
  }

  group('resolution', () {
    test('the side holding the lower id keeps its call and kills theirs', () {
      final sides = collide();

      final atLow = sides.low.handle(
        inviteFrom(callId: 'bbb', partyId: 'DEVICE_HIGH', sentAt: t0),
      );

      final hangup = atLow.signalling.single as SendHangup;
      expect(hangup.callId, 'bbb', reason: 'theirs, not ours');
      expect(hangup.partyId, 'DEVICE_LOW');
      expect(atLow.media, isEmpty, reason: 'our own media is untouched');
      expect(sides.low.state, CallState.outgoingRinging);
      expect(sides.low.session!.callId, 'aaa');
      expect(sides.low.session!.direction, CallDirection.outgoing);
    });

    test('the side holding the higher id abandons its call and rings', () {
      final sides = collide();

      final atHigh = sides.high.handle(
        inviteFrom(callId: 'aaa', partyId: 'DEVICE_LOW', sentAt: t0),
      );

      final hangup = atHigh.signalling.single as SendHangup;
      expect(hangup.callId, 'bbb', reason: 'ours, the one that lost');
      expect(sides.high.state, CallState.ringing);
      expect(sides.high.session!.callId, 'aaa');
      expect(sides.high.session!.direction, CallDirection.incoming);
    });

    test('exactly one call is alive across both machines', () {
      final sides = collide();
      sides.low.handle(
        inviteFrom(callId: 'bbb', partyId: 'DEVICE_HIGH', sentAt: t0),
      );
      sides.high.handle(
        inviteFrom(callId: 'aaa', partyId: 'DEVICE_LOW', sentAt: t0),
      );

      expect(sides.low.session!.callId, sides.high.session!.callId);
      expect(sides.low.session!.callId, 'aaa');
      expect(sides.low.session!.direction, CallDirection.outgoing);
      expect(sides.high.session!.direction, CallDirection.incoming);
    });

    test('the surviving call connects end to end', () {
      // Glare is only resolved if what is left is a working call, not merely a
      // consistent pair of survivors.
      final sides = collide();
      sides.low.handle(
        inviteFrom(callId: 'bbb', partyId: 'DEVICE_HIGH', sentAt: t0),
      );
      sides.high.handle(
        inviteFrom(callId: 'aaa', partyId: 'DEVICE_LOW', sentAt: t0),
      );

      sides.high.handle(const AcceptCall());
      sides.high.handle(const LocalDescriptionReady(answerSdp));
      sides.low.handle(answerFrom(callId: 'aaa', partyId: 'DEVICE_HIGH'));

      sides.low.handle(const MediaConnected());
      sides.high.handle(const MediaConnected());
      expect(sides.low.state, CallState.connected);
      expect(sides.high.state, CallState.connected);
    });

    test('the loser hangs up with the reason the SDK sends', () {
      // MSC2746 defines no glare reason. `unknown_error` is what the Matrix SDK
      // puts on the wire, and matching it is what stops an Element on the far
      // end reading the loser's hangup as something it has to show the user.
      final sides = collide();
      final atHigh = sides.high.handle(
        inviteFrom(callId: 'aaa', partyId: 'DEVICE_LOW', sentAt: t0),
      );
      final hangup = atHigh.signalling.single as SendHangup;
      expect(hangup.reason, CallEndReason.glareLost);
      expect(hangup.reason.wireReason, 'unknown_error');
    });

    test('the hangup precedes everything about the new call', () {
      // A far end that processes these out of order would see a hangup for the
      // call it has only just started.
      final sides = collide();
      final atHigh = sides.high.handle(
        inviteFrom(callId: 'aaa', partyId: 'DEVICE_LOW', sentAt: t0),
      );
      expect(typesOf(atHigh.intents), [SendHangup, DisposeMedia]);
    });

    test('the comparison is lexical, not numeric or by length', () {
      // '10' < '9' as text. A call id is an opaque string on the wire, and a
      // rule that quietly parsed it as a number would disagree with Element
      // exactly when both clients generate digits.
      final sides = collide(lowId: '10', highId: '9');
      sides.low.handle(
        inviteFrom(callId: '9', partyId: 'DEVICE_HIGH', sentAt: t0),
      );
      sides.high.handle(
        inviteFrom(callId: '10', partyId: 'DEVICE_LOW', sentAt: t0),
      );
      expect(sides.low.session!.callId, '10');
      expect(sides.high.session!.callId, '10');
    });
  });

  group('scope', () {
    test('an invite from a different room is busy, not glare', () {
      // Calling Anna while Bea calls us is not a collision — it is two calls,
      // and the second one has to be refused rather than silently replace the
      // first.
      final call = CallHarness()..placeCall(callId: 'aaa');
      final other = call.handle(
        inviteFrom(callId: 'bbb', roomId: otherRoomId, sentAt: t0),
      );

      final reject = other.signalling.single as SendReject;
      expect(reject.callId, 'bbb');
      expect(reject.reason, CallEndReason.userBusy);
      expect(call.state, CallState.outgoingRinging);
      expect(call.session!.callId, 'aaa');
    });

    test('an invite arriving once we are connected is busy, not glare', () {
      final call = CallHarness()..outgoingConnected(callId: 'aaa');
      final late = call.handle(inviteFrom(callId: 'AAA', sentAt: call.now));
      expect(
        (late.signalling.single as SendReject).reason,
        CallEndReason.userBusy,
        reason: 'a lower id does not win once a call is up',
      );
      expect(call.state, CallState.connected);
    });

    test('an expired invite cannot win glare', () {
      final call = CallHarness()..placeCall(callId: 'bbb');
      call.advance(const Duration(minutes: 2));
      final stale = call.handle(inviteFrom(callId: 'aaa', sentAt: t0));
      expect(stale.isNoOp, isTrue);
      expect(call.session!.callId, 'bbb');
    });
  });

  group('the loser leaves nothing behind', () {
    /// The high side after it has lost, ringing for the surviving call, with a
    /// remote candidate having been buffered for the call that died.
    CallHarness losingSide({Duration collisionAfter = Duration.zero}) {
      final high = CallHarness(partyId: 'DEVICE_HIGH')
        ..handle(const PlaceCall(callId: 'bbb', roomId: roomId, peer: peer))
        ..handle(const LocalDescriptionReady(offerSdp))
        ..handle(candidatesFrom([ice('doomed')], callId: 'bbb'));

      high.advance(collisionAfter);
      high.handle(
        inviteFrom(callId: 'aaa', partyId: 'DEVICE_LOW', sentAt: high.now),
      );
      return high;
    }

    test('the dead call cannot be answered, hung up or fed candidates', () {
      final high = losingSide();
      expect(high.handle(answerFrom(callId: 'bbb')).isNoOp, isTrue);
      expect(high.handle(hangupFrom(callId: 'bbb')).isNoOp, isTrue);
      expect(
        high.handle(candidatesFrom([ice('late')], callId: 'bbb')).isNoOp,
        isTrue,
      );
      expect(high.state, CallState.ringing);
      expect(high.session!.callId, 'aaa');
    });

    test("the dead call's candidates never reach the new one", () {
      final high = losingSide();
      final accepted = high.handle(const AcceptCall());
      expect(
        appliedCandidates(accepted),
        isEmpty,
        reason:
            'that candidate belonged to a peer connection that was '
            'disposed with the call it was gathered for',
      );
      expect(
        high.handle(const LocalDescriptionReady(answerSdp)).signalling.single,
        isA<SendAnswer>().having((i) => i.callId, 'callId', 'aaa'),
      );
    });

    test('local candidates gathered for the dead call are dropped too', () {
      // Losing before the offer was even produced is the tightest version of
      // the race, and the one where a local candidate is still sitting in the
      // outbound buffer.
      final high = CallHarness(partyId: 'DEVICE_HIGH')
        ..handle(const PlaceCall(callId: 'bbb', roomId: roomId, peer: peer))
        ..handle(LocalCandidate(ice('local-doomed')));

      high.handle(inviteFrom(callId: 'aaa', partyId: 'DEVICE_LOW', sentAt: t0));
      high.handle(const AcceptCall());

      final answered = high.handle(const LocalDescriptionReady(answerSdp));
      expect(sentCandidates(answered), isEmpty);
    });

    test('the new call buffers and flushes its own candidates normally', () {
      // The reset must reopen the buffers, not merely empty them: a closed one
      // would drop every candidate that arrives before the answer and leave a
      // call that connects on a LAN and nowhere else.
      final high = losingSide();
      expect(high.remoteBuffer.isOpen, isTrue);

      final fresh = [ice('host'), ice('srflx'), ice('relay')];
      high.handle(candidatesFrom(fresh, callId: 'aaa', partyId: 'DEVICE_LOW'));
      expect(high.remoteBuffer.length, 3);

      final accepted = high.handle(const AcceptCall());
      expect(appliedCandidates(accepted), orderedEquals(fresh));
    });

    test("the abandoned call's timeout does not end the new one", () {
      // The invite for 'bbb' went out 40 seconds ago and its timer is 20
      // seconds from firing. The call now ringing arrived just now and has a
      // full minute of its own.
      final high = losingSide(collisionAfter: const Duration(seconds: 40));

      high.advance(const Duration(seconds: 25));
      expect(high.tick().isNoOp, isTrue, reason: 'the old timer is not ours');
      expect(high.state, CallState.ringing);

      high.advance(const Duration(seconds: 35));
      expect(high.tick().isNoOp, isFalse);
      expect(high.session!.endReason, CallEndReason.inviteTimeout);
    });
  });
}
