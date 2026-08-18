import 'package:test/test.dart';
import 'package:weft_call/weft_call.dart';

import 'support/fixtures.dart';

/// ICE candidates arriving at the wrong moment.
///
/// This is the least dramatic file in the package and the one that pays for
/// itself. Candidates routinely beat the description they belong to — the far
/// end starts trickling the instant gathering begins, and on this side the host
/// candidates exist before the invite is on the wire — and a dropped early
/// candidate does not break the call outright. It removes the host and
/// server-reflexive candidates and leaves whatever arrives later, which on the
/// same Wi-Fi still connects. The bug it produces is "calls work at home and
/// nowhere else", which looks exactly like a missing TURN server and gets
/// diagnosed months late.
void main() {
  group('inbound, before the peer connection exists', () {
    test('candidates arriving while ringing are held, not dropped', () {
      final call = CallHarness()..ring();
      final early = [ice('host'), ice('srflx'), ice('relay')];

      final buffered = call.handle(candidatesFrom(early, callId: 'in-1'));
      expect(buffered.media, isEmpty, reason: 'nowhere to put them yet');
      expect(buffered.isNoOp, isTrue);
      expect(call.remoteBuffer.length, 3);
      expect(call.remoteBuffer.droppedCount, 0);
    });

    test('accepting flushes them in arrival order, after the answer', () {
      // Order is the contract. Host candidates ahead of relay ones is what
      // lets a call come up on the LAN in milliseconds instead of waiting on
      // TURN, and a flush that reorders silently gives that up.
      final call = CallHarness()..ring();
      final early = [ice('host'), ice('srflx'), ice('relay')];
      call.handle(candidatesFrom(early, callId: 'in-1'));

      final accepted = call.handle(const AcceptCall());
      expect(typesOf(accepted.intents), [
        CreateAnswer,
        AddRemoteCandidate,
        AddRemoteCandidate,
        AddRemoteCandidate,
      ]);
      expect(appliedCandidates(accepted), orderedEquals(early));
      expect(call.remoteBuffer.isEmpty, isTrue, reason: 'flushed, not copied');
    });

    test('order is preserved across several batches', () {
      final call = CallHarness()..ring();
      call.handle(candidatesFrom([ice('a'), ice('b')], callId: 'in-1'));
      call.handle(candidatesFrom([ice('c')], callId: 'in-1'));
      call.handle(candidatesFrom([ice('d'), ice('e')], callId: 'in-1'));

      final accepted = call.handle(const AcceptCall());
      expect(
        appliedCandidates(accepted),
        orderedEquals([ice('a'), ice('b'), ice('c'), ice('d'), ice('e')]),
      );
    });

    test('the caller holds candidates until the answer commits a device', () {
      // Between `m.call.invite` and `m.call.answer` there is no agreed peer,
      // so there is no peer connection to add anything to.
      final call = CallHarness()..placeCall();
      final early = [ice('host'), ice('relay')];
      call.handle(candidatesFrom(early));
      expect(call.remoteBuffer.length, 2);

      final answered = call.handle(answerFrom());
      expect(typesOf(answered.intents), [
        SendSelectAnswer,
        ApplyRemoteDescription,
        AddRemoteCandidate,
        AddRemoteCandidate,
      ]);
      expect(
        appliedCandidates(answered),
        orderedEquals(early),
        reason: 'and only after the remote description',
      );
    });

    test('once the description is applied they go straight through', () {
      final call = CallHarness()..outgoingConnected();
      final live = call.handle(
        candidatesFrom([ice('relay-1'), ice('relay-2')]),
      );

      expect(
        appliedCandidates(live),
        orderedEquals([ice('relay-1'), ice('relay-2')]),
      );
      expect(call.remoteBuffer.isEmpty, isTrue);
      expect(
        live.media,
        hasLength(2),
        reason:
            'one intent per candidate, so one malformed candidate cannot '
            'take a whole batch down with it',
      );
    });

    test('the end-of-candidates marker is forwarded like any other', () {
      // A peer that never learns gathering finished waits out its own ICE
      // timeout, which is thirty seconds of silence on a call that was going
      // to fail anyway.
      final call = CallHarness()..ring();
      call.handle(
        candidatesFrom([ice('host'), endOfCandidates], callId: 'in-1'),
      );

      final accepted = call.handle(const AcceptCall());
      expect(appliedCandidates(accepted).last, endOfCandidates);
      expect(appliedCandidates(accepted).last.isEndOfCandidates, isTrue);
    });

    test('a duplicate candidate is queued once and is not a loss', () {
      // Peers resend candidates after a reconnect. Adding the same one twice is
      // at best wasted work and at worst an error from the platform's ICE
      // agent — but nothing was dropped, and the drop counter is a diagnostic
      // that has to stay trustworthy.
      final call = CallHarness()..ring();
      call.handle(candidatesFrom([ice('host'), ice('host')], callId: 'in-1'));
      call.handle(candidatesFrom([ice('host')], callId: 'in-1'));

      expect(call.remoteBuffer.length, 1);
      expect(call.remoteBuffer.droppedCount, 0);
    });

    test(
      'candidates for a call we do not have are dropped without counting',
      () {
        final call = CallHarness()..ring(callId: 'in-1');
        final other = call.handle(
          candidatesFrom([ice('host')], callId: 'in-9'),
        );
        expect(other.isNoOp, isTrue);
        expect(call.remoteBuffer.isEmpty, isTrue);
        expect(call.remoteBuffer.droppedCount, 0);
      },
    );
  });

  group('inbound, after the call is over', () {
    test('candidates after a hangup are discarded and counted', () {
      // Feeding a candidate to a disposed engine is a crash on at least one
      // platform, so the buffer closes rather than merely emptying — and the
      // count is the only visible symptom, so it is worth logging.
      final call = CallHarness()..outgoingConnected();
      call.handle(const HangUp());
      expect(call.state, CallState.ending);

      final late = call.handle(candidatesFrom([ice('relay'), ice('relay-2')]));
      expect(late.media, isEmpty);
      expect(late.isNoOp, isTrue);
      expect(call.remoteBuffer.droppedCount, 2);
    });

    test('candidates after the call ended are discarded and counted', () {
      final call = CallHarness()..outgoingConnected();
      call.handle(const HangUp());
      call.handle(const MediaDisposed());

      call.handle(candidatesFrom([ice('relay')]));
      expect(call.state, CallState.ended);
      expect(call.remoteBuffer.droppedCount, 1);
    });

    test('candidates buffered when the call ends are counted as dropped', () {
      final call = CallHarness()..ring();
      call.handle(candidatesFrom([ice('a'), ice('b')], callId: 'in-1'));
      expect(call.remoteBuffer.length, 2);

      call.handle(const DeclineCall());
      expect(call.remoteBuffer.isEmpty, isTrue);
      expect(call.remoteBuffer.droppedCount, 2);
    });
  });

  group('outbound', () {
    test('candidates gathered before the invite go out with it, in order', () {
      // The far end does not know the call exists yet, so these cannot be sent
      // and must not be thrown away: they are the host candidates, the fastest
      // path there is.
      final call = CallHarness()
        ..handle(const PlaceCall(callId: 'out-1', roomId: roomId, peer: peer));

      final gathered = [ice('host-1'), ice('host-2'), ice('srflx')];
      for (final candidate in gathered) {
        final held = call.handle(LocalCandidate(candidate));
        expect(held.signalling, isEmpty, reason: 'no invite on the wire yet');
      }

      final invited = call.handle(const LocalDescriptionReady(offerSdp));
      expect(typesOf(invited.intents), [SendInvite, SendCandidates]);
      expect(
        sentCandidates(invited),
        orderedEquals(gathered),
        reason: 'one batch, in gathering order',
      );
      expect(invited.signalling.last.callId, 'out-1');
      expect(invited.signalling.last.partyId, localParty);
    });

    test('candidates gathered after the invite go out one at a time', () {
      final call = CallHarness()..placeCall();

      final trickled = call.handle(LocalCandidate(ice('relay')));
      final sent = trickled.signalling.single as SendCandidates;
      expect(sent.candidates, [ice('relay')]);
      expect(sent.callId, 'out-1');
    });

    test('the answering side holds candidates until its answer is sent', () {
      final call = CallHarness()..ring();
      call.handle(const AcceptCall());

      final held = call.handle(LocalCandidate(ice('host')));
      expect(held.signalling, isEmpty);

      final answered = call.handle(const LocalDescriptionReady(answerSdp));
      expect(typesOf(answered.intents), [SendAnswer, SendCandidates]);
      expect(sentCandidates(answered), [ice('host')]);
    });

    test('candidates gathered after we hung up are not sent', () {
      final call = CallHarness()..outgoingConnected();
      call.handle(const HangUp());
      expect(call.handle(LocalCandidate(ice('relay'))).isNoOp, isTrue);
    });

    test('candidates gathered with no call at all are not sent', () {
      final call = CallHarness();
      expect(call.handle(LocalCandidate(ice('host'))).isNoOp, isTrue);
    });
  });

  group('IceCandidateBuffer', () {
    test('flushing empties the buffer and returns arrival order', () {
      final buffer = IceCandidateBuffer();
      expect(buffer.addAll([ice('a'), ice('b'), ice('c')]), 3);
      expect(buffer.pending, orderedEquals([ice('a'), ice('b'), ice('c')]));

      expect(buffer.flush(), orderedEquals([ice('a'), ice('b'), ice('c')]));
      expect(buffer.isEmpty, isTrue);
      expect(buffer.flush(), isEmpty);
    });

    test('a duplicate is refused without being counted as a drop', () {
      final buffer = IceCandidateBuffer();
      expect(buffer.add(ice('a')), isTrue);
      expect(buffer.add(ice('a')), isFalse);
      expect(buffer.length, 1);
      expect(buffer.droppedCount, 0);
    });

    test('candidates differing only in mid or index are distinct', () {
      final buffer = IceCandidateBuffer()
        ..add(ice('a', mid: '0', index: 0))
        ..add(ice('a', mid: '1', index: 0))
        ..add(ice('a', mid: '0', index: 1));
      expect(buffer.length, 3);
    });

    test('the capacity is a leak guard and counts what it refuses', () {
      // A real call gathers a handful. Several hundred means a peer is
      // misbehaving or a buffer is never flushed, and unbounded growth in a
      // long-lived call service is a leak rather than resilience.
      final buffer = IceCandidateBuffer(capacity: 3)
        ..addAll([ice('a'), ice('b'), ice('c')]);
      expect(buffer.add(ice('d')), isFalse);
      expect(buffer.length, 3);
      expect(buffer.droppedCount, 1);

      // Flushing makes room again.
      buffer.flush();
      expect(buffer.add(ice('d')), isTrue);
    });

    test('closing discards what is queued and refuses more', () {
      final buffer = IceCandidateBuffer()..addAll([ice('a'), ice('b')]);
      buffer.close();
      expect(buffer.isOpen, isFalse);
      expect(buffer.isEmpty, isTrue);
      expect(buffer.droppedCount, 2);

      expect(buffer.add(ice('c')), isFalse);
      expect(buffer.droppedCount, 3, reason: 'still counted while closed');
    });

    test('reopening empties it and accepts again', () {
      final buffer = IceCandidateBuffer()..addAll([ice('a')]);
      buffer.reopen();
      expect(buffer.isEmpty, isTrue);
      expect(buffer.isOpen, isTrue);
      expect(buffer.add(ice('b')), isTrue);

      buffer
        ..close()
        ..reopen();
      expect(buffer.add(ice('c')), isTrue);
    });

    test('toString says enough to diagnose the LAN-only failure', () {
      final buffer = IceCandidateBuffer(capacity: 8)..add(ice('a'));
      expect(buffer.toString(), 'IceCandidateBuffer(1/8)');
      buffer.close();
      expect(buffer.toString(), 'IceCandidateBuffer(0/8, closed, dropped 1)');
    });
  });
}
