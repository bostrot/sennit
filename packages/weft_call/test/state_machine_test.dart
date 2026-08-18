import 'package:test/test.dart';
import 'package:weft_call/weft_call.dart';

import 'support/fixtures.dart';

/// The lifecycle of a 1:1 call, from both ends.
///
/// Every assertion here is on a state *and* on what went on the wire, because
/// half of these behaviours are only visible to the far end: a call that ends
/// with `m.call.reject` shows as declined in Element and one that ends with
/// `m.call.hangup` shows as ended, and no local state distinguishes them. The
/// states say what the user sees; the intents say what the other person sees.
void main() {
  group('outgoing', () {
    test('reaches connected and pins every event it sends', () {
      final call = CallHarness();

      final placed = call.handle(
        const PlaceCall(callId: 'out-1', roomId: roomId, peer: peer),
      );
      expect(call.state, CallState.outgoingRinging);
      expect(typesOf(placed.intents), [CreateOffer]);
      expect((placed.media.single as CreateOffer).video, isFalse);
      expect(call.session!.direction, CallDirection.outgoing);
      expect(call.session!.startedAt, t0);

      // The invite only exists once the engine has produced an offer. Until
      // then there is nothing to put in it.
      final invited = call.handle(const LocalDescriptionReady(offerSdp));
      final invite = invited.signalling.single as SendInvite;
      expect(invite.callId, 'out-1');
      expect(invite.partyId, localParty);
      expect(invite.roomId, roomId);
      expect(invite.offer, offerSdp);
      expect(invite.lifetime, kDefaultInviteLifetime);
      expect(invite.video, isFalse);
      expect(call.state, CallState.outgoingRinging, reason: 'still ringing');

      // The answer commits us to one of the far end's devices, and says so on
      // the wire before anything else, so a second device learns it lost.
      final answered = call.handle(answerFrom());
      expect(typesOf(answered.intents), [
        SendSelectAnswer,
        ApplyRemoteDescription,
      ]);
      final selected = answered.signalling.single as SendSelectAnswer;
      expect(selected.callId, 'out-1');
      expect(selected.partyId, localParty, reason: 'ours, not theirs');
      expect(selected.selectedPartyId, peerParty);
      expect(call.state, CallState.connecting);
      expect(call.session!.remotePartyId, peerParty);
      expect(call.session!.connectedAt, isNull, reason: 'ICE is still working');

      call.advance(const Duration(seconds: 4));
      final connected = call.handle(
        const MediaConnected(codecs: CodecSummary(audio: 'opus')),
      );
      expect(connected.intents, isEmpty, reason: 'nothing to tell anyone');
      expect(call.state, CallState.connected);
      expect(call.session!.connectedAt, t0.add(const Duration(seconds: 4)));
      expect(call.session!.codecs!.audio, 'opus');

      // The duration counts from media, not from the invite: charging the user
      // for the ringing is how a five-second call shows as thirty.
      call.advance(const Duration(seconds: 30));
      expect(call.session!.durationAt(call.now), const Duration(seconds: 30));
    });

    test('a video call offers, answers and records video throughout', () {
      final call = CallHarness();
      final placed = call.handle(
        const PlaceCall(
          callId: 'out-1',
          roomId: roomId,
          peer: peer,
          video: true,
        ),
      );
      expect((placed.media.single as CreateOffer).video, isTrue);

      final invited = call.handle(const LocalDescriptionReady(offerSdp));
      expect((invited.signalling.single as SendInvite).video, isTrue);
      expect(call.session!.videoEnabled, isTrue);
      expect(call.session!.cameraOn, isTrue);
    });

    test('local hangup rejects nothing and tells the far end it hung up', () {
      final call = CallHarness()..outgoingConnected();

      final hungUp = call.handle(const HangUp());
      expect(typesOf(hungUp.intents), [SendHangup, DisposeMedia]);
      final hangup = hungUp.signalling.single as SendHangup;
      expect(hangup.callId, 'out-1');
      expect(hangup.reason, CallEndReason.userHangup);
      expect(hangup.reason.wireReason, 'user_hangup');
      expect(call.state, CallState.ending, reason: '"Ending…" is a real frame');
      expect(call.session!.endReason, CallEndReason.userHangup);

      final disposed = call.handle(const MediaDisposed());
      expect(disposed.intents, isEmpty);
      expect(call.state, CallState.ended);
      expect(call.session!.state, CallState.ended, reason: 'session kept in step');
      expect(call.session!.endReason, CallEndReason.userHangup);
      expect(call.session!.peer.label, 'Anna', reason: 'who it was with survives');
    });

    test('the far end hanging up is not the same reason as hanging up', () {
      final call = CallHarness()..outgoingConnected();

      final remote = call.handle(hangupFrom(reason: 'user_hangup'));
      expect(remote.signalling, isEmpty, reason: 'never hang up on a hangup');
      expect(typesOf(remote.intents), [DisposeMedia]);
      expect(call.session!.endReason, CallEndReason.remoteHangup);
      expect(call.session!.endReason!.isFailure, isFalse);
    });

    test('the far end declining before answering reads as a rejection', () {
      final call = CallHarness()..placeCall();

      final rejected = call.handle(rejectFrom());
      expect(rejected.signalling, isEmpty);
      expect(call.state, CallState.ending);
      expect(call.session!.endReason, CallEndReason.remoteReject);
    });

    test('a reason this build has never heard of is still a deliberate end', () {
      // A newer client's reason must not be reported as a failure — that would
      // put a red "Call failed" on a call the other person simply ended.
      final call = CallHarness()..outgoingConnected();
      call.handle(hangupFrom(reason: 'org.example.went_for_lunch'));
      expect(call.session!.endReason, CallEndReason.remoteHangup);
      expect(call.session!.endReason!.isFailure, isFalse);
    });

    test('ICE failing ends the call as a failure, and says so on the wire', () {
      final call = CallHarness()..placeCall();
      call.handle(answerFrom());

      final failed = call.handle(const MediaFailed());
      final hangup = failed.signalling.single as SendHangup;
      expect(hangup.reason.wireReason, 'ice_failed');
      expect(call.session!.endReason, CallEndReason.iceFailed);
      expect(call.session!.endReason!.isFailure, isTrue);
    });
  });

  group('incoming', () {
    test('rings, answers, and pins every event it sends', () {
      final call = CallHarness();

      final rang = call.handle(inviteFrom(sentAt: t0));
      expect(rang.intents, isEmpty, reason: 'nothing is sent until the user acts');
      expect(call.state, CallState.ringing);
      expect(call.session!.direction, CallDirection.incoming);
      expect(call.session!.callId, 'in-1');
      expect(call.session!.peer.matrixUserId, peerUserId);
      expect(
        call.session!.remotePartyId,
        peerParty,
        reason: 'the caller is latched from the invite, not from an answer',
      );

      final accepted = call.handle(const AcceptCall());
      expect(typesOf(accepted.intents), [CreateAnswer]);
      final createAnswer = accepted.media.single as CreateAnswer;
      expect(createAnswer.remoteOffer, offerSdp);
      expect(call.state, CallState.connecting);

      final sent = call.handle(const LocalDescriptionReady(answerSdp));
      final answer = sent.signalling.single as SendAnswer;
      expect(answer.callId, 'in-1');
      expect(answer.partyId, localParty);
      expect(answer.answer, answerSdp);
      expect(answer.video, isFalse);

      call.handle(const MediaConnected());
      expect(call.state, CallState.connected);
    });

    test('a video call may be answered with audio only', () {
      // Not a downgrade of the call: the caller keeps sending video, we simply
      // do not send ours, so `videoEnabled` stays true and the camera does not.
      final call = CallHarness()..ring(video: true);
      expect(call.session!.videoEnabled, isTrue);
      expect(call.session!.cameraOn, isTrue);

      final accepted = call.handle(const AcceptCall(video: false));
      expect((accepted.media.single as CreateAnswer).video, isFalse);
      expect(call.session!.videoEnabled, isTrue);
      expect(call.session!.cameraOn, isFalse);

      final sent = call.handle(const LocalDescriptionReady(answerSdp));
      expect((sent.signalling.single as SendAnswer).video, isFalse);
    });

    test('declining sends a reject, not a hangup', () {
      final call = CallHarness()..ring();

      final declined = call.handle(const DeclineCall());
      expect(typesOf(declined.intents), [SendReject, DisposeMedia]);
      final reject = declined.signalling.single as SendReject;
      expect(reject.callId, 'in-1');
      expect(reject.partyId, localParty);
      expect(reject.reason, CallEndReason.localReject);
      expect(call.session!.endReason, CallEndReason.localReject);
    });

    test('declining a call that is not ringing does nothing', () {
      final call = CallHarness()..outgoingConnected();
      expect(call.handle(const DeclineCall()).isNoOp, isTrue);
      expect(call.state, CallState.connected);
    });

    test('the caller giving up while we ring ends the call silently', () {
      final call = CallHarness()..ring();
      final gone = call.handle(hangupFrom(callId: 'in-1'));
      expect(gone.signalling, isEmpty);
      expect(call.session!.endReason, CallEndReason.remoteHangup);
    });

    test('an invite addressed to somebody else never rings', () {
      final call = CallHarness();
      final other = call.handle(inviteFrom(invitee: '@someone:example.org'));
      expect(other.isNoOp, isTrue);
      expect(call.state, CallState.idle);

      // Addressed to us, or to nobody in particular, does ring.
      expect(call.handle(inviteFrom(invitee: localUserId)).isNoOp, isFalse);
    });

    test('an invite in a version this build cannot speak is ignored', () {
      // Ignored rather than rejected: a client speaking a dialect from the
      // future has probably sent the same call in a version we do understand,
      // and rejecting would cancel that one too.
      final call = CallHarness();
      expect(call.handle(inviteFrom(version: '2')).isNoOp, isTrue);
      expect(call.state, CallState.idle);
      expect(call.handle(inviteFrom(version: '0')).isNoOp, isFalse);
      expect(call.state, CallState.ringing);
    });

    test('an invite that already expired never rings', () {
      // The common case after time offline: sync delivers every call from the
      // last hour at once, and without this the phone rings for all of them.
      final call = CallHarness();
      call.advance(const Duration(minutes: 5));
      expect(call.handle(inviteFrom(sentAt: t0)).isNoOp, isTrue);
      expect(call.state, CallState.idle);
    });

    test('a fresh invite delivered late still rings for what is left', () {
      final call = CallHarness();
      call.advance(const Duration(seconds: 59));
      expect(call.handle(inviteFrom(sentAt: t0)).isNoOp, isFalse);
      expect(call.state, CallState.ringing);
    });
  });

  group('invite timeout', () {
    test('the caller gives up after the lifetime and hangs up', () {
      final call = CallHarness()..placeCall();

      call.advance(const Duration(seconds: 59));
      expect(call.tick().isNoOp, isTrue, reason: 'a second short of the limit');
      expect(call.state, CallState.outgoingRinging);

      call.advance(const Duration(seconds: 1));
      final gaveUp = call.tick();
      final hangup = gaveUp.signalling.single as SendHangup;
      expect(hangup.reason, CallEndReason.inviteTimeout);
      expect(hangup.reason.wireReason, 'invite_timeout');
      expect(call.state, CallState.ending);
    });

    test('the timeout runs from the invite, not from the user pressing call', () {
      final call = CallHarness();
      call.handle(
        const PlaceCall(callId: 'out-1', roomId: roomId, peer: peer),
      );

      // Ten seconds to open the camera. The phone must still ring for a full
      // minute after that, not for fifty seconds.
      call.advance(const Duration(seconds: 10));
      call.handle(const LocalDescriptionReady(offerSdp));

      call.advance(const Duration(seconds: 59));
      expect(call.tick().isNoOp, isTrue);
      call.advance(const Duration(seconds: 1));
      expect(
        call.state,
        CallState.outgoingRinging,
        reason: 'time passing is not an input — only a tick ends a call',
      );
      expect(call.tick().signalling.single, isA<SendHangup>());
    });

    test('the ringing side stops without sending anything', () {
      // The caller is running the same timer and is about to hang up. A reject
      // here would race it and land in the room as a second call-ended event.
      final call = CallHarness()..ring(sentAt: t0);
      call.advance(const Duration(seconds: 60));

      final expired = call.tick();
      expect(expired.signalling, isEmpty);
      expect(typesOf(expired.intents), [DisposeMedia]);
      expect(call.state, CallState.ending);
      expect(call.session!.endReason, CallEndReason.inviteTimeout);
    });

    test('a shorter lifetime chosen by the caller is honoured', () {
      final call = CallHarness()
        ..handle(
          inviteFrom(sentAt: t0, lifetime: const Duration(seconds: 15)),
        );
      call.advance(const Duration(seconds: 14));
      expect(call.tick().isNoOp, isTrue);
      call.advance(const Duration(seconds: 1));
      expect(call.tick().isNoOp, isFalse);
      expect(call.session!.endReason, CallEndReason.inviteTimeout);
    });
  });

  group('busy', () {
    test('a second invite during a call is rejected, not ignored', () {
      // Rejecting stops the caller ringing at once; ignoring makes them wait
      // out the full minute for a phone that was never going to answer.
      final call = CallHarness()..outgoingConnected();

      final second = call.handle(inviteFrom(callId: 'in-2'));
      final reject = second.signalling.single as SendReject;
      expect(reject.callId, 'in-2', reason: 'the new call, not ours');
      expect(reject.partyId, localParty);
      expect(reject.reason, CallEndReason.userBusy);
      expect(reject.reason.wireReason, 'user_busy');

      expect(call.state, CallState.connected, reason: 'our call is untouched');
      expect(call.session!.callId, 'out-1');
    });

    test('a second invite while the phone is already ringing is rejected', () {
      final call = CallHarness()..ring(callId: 'in-1');
      final second = call.handle(inviteFrom(callId: 'in-2'));
      expect((second.signalling.single as SendReject).callId, 'in-2');
      expect(call.session!.callId, 'in-1');
    });

    test('the far end saying it is busy ends our call as busy', () {
      final call = CallHarness()..placeCall();
      call.handle(rejectFrom(reason: 'user_busy'));
      expect(call.session!.endReason, CallEndReason.userBusy);
      expect(call.session!.endReason!.isFailure, isFalse);
    });

    test('an invite arriving after the last call ended rings normally', () {
      // The second call of a session is where stale state shows up: the first
      // call closed both candidate buffers on its way out, and an incoming
      // call that inherited them would silently drop every candidate that
      // arrived before the answer.
      final call = CallHarness()..outgoingConnected();
      call.handle(const HangUp());
      call.handle(const MediaDisposed());
      expect(call.state, CallState.ended);

      call.handle(inviteFrom(callId: 'in-2', sentAt: call.now));
      expect(call.state, CallState.ringing);
      expect(call.session!.callId, 'in-2');
      expect(call.session!.endReason, isNull);
      expect(call.remoteBuffer.isOpen, isTrue);

      final early = [ice('host'), ice('srflx')];
      call.handle(candidatesFrom(early, callId: 'in-2'));
      expect(call.remoteBuffer.length, 2);

      final accepted = call.handle(const AcceptCall());
      expect(appliedCandidates(accepted), orderedEquals(early));
    });

    test('placing a second call after the first ended starts clean', () {
      final call = CallHarness()..outgoingConnected(callId: 'out-1');
      call.handle(const HangUp());
      call.handle(const MediaDisposed());

      final placed = call.handle(
        const PlaceCall(callId: 'out-2', roomId: roomId, peer: peer),
      );
      expect(typesOf(placed.intents), [CreateOffer]);
      expect(call.state, CallState.outgoingRinging);
      expect(call.session!.callId, 'out-2');
      expect(call.session!.endReason, isNull);
      expect(call.session!.connectedAt, isNull);
    });

    test('placing a call while one is in progress does nothing', () {
      final call = CallHarness()..outgoingConnected(callId: 'out-1');
      final second = call.handle(
        const PlaceCall(callId: 'out-2', roomId: roomId, peer: peer),
      );
      expect(second.isNoOp, isTrue);
      expect(call.session!.callId, 'out-1');
    });
  });

  group('select_answer', () {
    test('the caller names the device it accepted', () {
      final call = CallHarness()..placeCall();
      final answered = call.handle(answerFrom(partyId: 'THEIR_PHONE'));
      expect(
        (answered.signalling.single as SendSelectAnswer).selectedPartyId,
        'THEIR_PHONE',
      );

      // A second device answering afterwards is ignored — the select_answer
      // has already told it to stop, and re-committing would swap the peer
      // connection out from under a call that is already coming up.
      final second = call.handle(answerFrom(partyId: 'THEIR_LAPTOP'));
      expect(second.isNoOp, isTrue);
      expect(call.session!.remotePartyId, 'THEIR_PHONE');
    });

    test('a device that lost stops, and does not send anything', () {
      final call = CallHarness()..ring();
      call.handle(const AcceptCall());
      call.handle(const LocalDescriptionReady(answerSdp));

      final lost = call.handle(
        selectAnswerFrom(callId: 'in-1', selectedPartyId: otherLocalParty),
      );
      expect(lost.signalling, isEmpty, reason: 'the caller already knows');
      expect(typesOf(lost.intents), [DisposeMedia]);
      expect(call.session!.endReason, CallEndReason.answeredElsewhere);
      expect(call.session!.endReason!.isFailure, isFalse);
    });

    test('the device that won carries on', () {
      final call = CallHarness()..ring();
      call.handle(const AcceptCall());
      call.handle(const LocalDescriptionReady(answerSdp));

      final won = call.handle(
        selectAnswerFrom(callId: 'in-1', selectedPartyId: localParty),
      );
      expect(won.isNoOp, isTrue);
      expect(call.state, CallState.connecting);
    });

    test('a select_answer before we answered is not ours to obey', () {
      // We are still ringing, so this cannot be about us: acting on it would
      // stop a phone that never had a chance to be picked up.
      final call = CallHarness()..ring();
      final early = call.handle(
        selectAnswerFrom(callId: 'in-1', selectedPartyId: otherLocalParty),
      );
      expect(early.isNoOp, isTrue);
      expect(call.state, CallState.ringing);
    });
  });

  group('party filtering', () {
    test('signalling for a call we do not have is dropped', () {
      final call = CallHarness()..outgoingConnected(callId: 'out-1');
      expect(call.handle(hangupFrom(callId: 'someone-else')).isNoOp, isTrue);
      expect(call.handle(answerFrom(callId: 'someone-else')).isNoOp, isTrue);
      expect(call.state, CallState.connected);
    });

    test('a second far-end device cannot hang up a call it did not answer', () {
      final call = CallHarness()..outgoingConnected();
      expect(call.session!.remotePartyId, peerParty);

      final imposter = call.handle(hangupFrom(partyId: otherPeerParty));
      expect(imposter.isNoOp, isTrue);
      expect(call.state, CallState.connected);

      expect(call.handle(hangupFrom(partyId: peerParty)).isNoOp, isFalse);
      expect(call.state, CallState.ending);
    });

    test('an invite with no party id leaves the far end unlatched', () {
      // Version 0 clients send no `party_id`. Latching on an empty string would
      // then reject every subsequent event from them, which is worse than not
      // filtering at all.
      final call = CallHarness()..handle(inviteFrom(partyId: '', sentAt: t0));
      expect(call.session!.remotePartyId, isNull);
      expect(call.handle(hangupFrom(callId: 'in-1', partyId: '')).isNoOp, isFalse);
    });
  });

  group('local controls', () {
    test('mute and unmute reach the engine once each', () {
      final call = CallHarness()..outgoingConnected();

      final muted = call.handle(const SetMuted(true));
      expect(typesOf(muted.intents), [ApplyMute]);
      expect((muted.media.single as ApplyMute).muted, isTrue);
      expect(call.session!.muted, isTrue);

      // Muting twice is the user tapping a button that is already on. Nothing
      // is sent, which is what keeps a rebuild from re-muting the microphone.
      expect(call.handle(const SetMuted(true)).isNoOp, isTrue);

      final unmuted = call.handle(const SetMuted(false));
      expect((unmuted.media.single as ApplyMute).muted, isFalse);
      expect(call.session!.muted, isFalse);
    });

    test('the speaker is recorded but never handed to the engine', () {
      // Routing is a platform concern and deliberately absent from MediaEngine,
      // so the app reads this flag and drives the OS itself.
      final call = CallHarness()..outgoingConnected();
      final speaker = call.handle(const SetSpeaker(true));
      expect(speaker.intents, isEmpty);
      expect(call.session!.speakerOn, isTrue);
    });

    test('the camera can be turned off without renegotiating', () {
      final call = CallHarness()..outgoingConnected(video: true);
      final off = call.handle(const SetCameraEnabled(false));
      expect(typesOf(off.intents), [ApplyVideo]);
      expect(off.signalling, isEmpty, reason: 'still a video call');
      expect(call.session!.cameraOn, isFalse);
      expect(call.session!.videoEnabled, isTrue);
    });

    test('switching camera needs a peer connection', () {
      final call = CallHarness()..ring(video: true);
      expect(call.handle(const SwitchCamera()).isNoOp, isTrue);

      call.handle(const AcceptCall());
      expect(typesOf(call.handle(const SwitchCamera()).intents), [
        ApplySwitchCamera,
      ]);
    });

    test('controls do nothing when there is no call', () {
      final call = CallHarness();
      expect(call.handle(const SetMuted(true)).isNoOp, isTrue);
      expect(call.handle(const SetSpeaker(true)).isNoOp, isTrue);
      expect(call.handle(const SetCameraEnabled(true)).isNoOp, isTrue);
      expect(call.handle(const SwitchCamera()).isNoOp, isTrue);
      expect(call.handle(const HangUp()).isNoOp, isTrue);
      expect(call.handle(const AcceptCall()).isNoOp, isTrue);
      expect(call.tick().isNoOp, isTrue);
      expect(call.state, CallState.idle);
      expect(call.session, isNull);
    });
  });

  group('teardown', () {
    test('an engine that never finishes disposing cannot strand the screen', () {
      // "Ending…" forever is a worse failure than a slightly early dismissal,
      // so the grace period forces the terminal state without the engine.
      final call = CallHarness(endingGrace: const Duration(seconds: 5))
        ..outgoingConnected();
      call.handle(const HangUp());
      expect(call.state, CallState.ending);

      call.advance(const Duration(seconds: 4));
      expect(call.tick().isNoOp, isTrue);
      expect(call.state, CallState.ending);

      call.advance(const Duration(seconds: 1));
      call.tick();
      expect(call.state, CallState.ended);
      expect(call.session!.endReason, CallEndReason.userHangup);
    });

    test('hanging up twice sends one hangup', () {
      final call = CallHarness()..outgoingConnected();
      expect(call.handle(const HangUp()).signalling, hasLength(1));
      expect(call.handle(const HangUp()).isNoOp, isTrue);
      call.handle(const MediaDisposed());
      expect(call.handle(const HangUp()).isNoOp, isTrue);
      expect(call.session!.endReason, CallEndReason.userHangup);
    });

    test('a hangup that crosses ours does not overwrite why we ended', () {
      final call = CallHarness()..outgoingConnected();
      call.handle(const HangUp());
      expect(call.handle(hangupFrom()).isNoOp, isTrue);
      expect(call.session!.endReason, CallEndReason.userHangup);
    });

    test('MediaDisposed outside teardown is ignored', () {
      final call = CallHarness()..outgoingConnected();
      expect(call.handle(const MediaDisposed()).isNoOp, isTrue);
      expect(call.state, CallState.connected);
    });
  });
}
