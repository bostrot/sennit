import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/call/call_audio.dart';
import 'package:weft/services/call/call_service.dart';
import 'package:weft/services/call/sdp_codecs.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'support/call_fixtures.dart';

/// `CallService`, the one place a call's decisions meet its plumbing.
///
/// The decisions themselves are `weft_call`'s and have 114 tests of their own;
/// nothing here re-asserts a state transition for its own sake. What this file
/// pins is the part that only exists once the machine is wired to something:
/// that each intent lands on the *right* collaborator and in the right room,
/// that the three deadlines the machine deliberately leaves open are actually
/// closed here, that a failure in the microphone or on the wire produces a
/// sentence the button that was pressed can show, and that the audio session
/// ends up where the call says it should be.
///
/// Every collaborator is a recorder (`support/call_fixtures.dart`) and time is
/// injected, so a thirty-second ICE timeout is one `advance` and one tick.
void main() {
  group('outgoing call', () {
    test('the invite is the whole contract with the far end', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      final failure = await harness.service.placeCall(
        roomId: room,
        peer: annaPeer,
      );
      await pumpEventQueue();

      expect(failure, isNull);
      expect(harness.engine.calls, ['createOffer(video: false)']);

      final invite = harness.sink.sent.single;
      expect(invite.type, 'm.call.invite');
      expect(invite.roomId, room);
      expect(invite.callId, 'call-1');
      expect(invite.content['party_id'], localParty);
      expect(invite.content['version'], '1');
      // `invitee` absent means "any member of the room", which in a room holding
      // a bridge bot or an integration manager means ringing them as well.
      expect(invite.content['invitee'], annaPeer.matrixUserId);
      expect((invite.content['offer']! as Map)['type'], 'offer');
      expect(harness.session?.state, CallState.outgoingRinging);
    });

    test('an answer is committed to before anything else is done', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();
      harness.signal(harness.answer());
      await pumpEventQueue();

      // `m.call.select_answer` before the description is applied: a second
      // device of theirs that also answered has to be told to stop, and told
      // first.
      expect(harness.sink.types, ['m.call.invite', 'm.call.select_answer']);
      expect(harness.sink.last!.content['selected_party_id'], peerParty);
      expect(harness.engine.calls, contains('applyRemoteDescription(answer)'));
      expect(harness.session?.state, CallState.connecting);
      expect(harness.session?.remotePartyId, peerParty);
    });

    test('media flowing starts the duration and names the codecs', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();

      final connected = harness.session!;
      expect(connected.state, CallState.connected);
      expect(connected.connectedAt, t0);
      expect(connected.codecs?.audio, 'opus');
      expect(harness.state.reconnecting, isFalse);
    });

    test('hanging up tells the far end and then closes the engine', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      await harness.service.hangUp();
      await pumpEventQueue();

      // Order is the contract: the hangup is on the wire before the engine is
      // torn down, so the far end stops ringing even if teardown hangs.
      expect(harness.sink.types.last, 'm.call.hangup');
      expect(harness.sink.last!.reason, 'user_hangup');
      expect(harness.engine.disposed, isTrue);
      expect(harness.session?.state, CallState.ended);
      expect(harness.session?.endReason, CallEndReason.userHangup);
    });

    test('an engine that throws on teardown still ends the call', () async {
      // Whatever happened, the call is over. A screen stuck on "Ending…" is the
      // failure this guards.
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      harness.engine.disposeError = StateError('the plugin went away');
      await harness.service.hangUp();
      await pumpEventQueue();

      expect(harness.session?.state, CallState.ended);
      expect(harness.session?.endReason, CallEndReason.userHangup);
    });

    test('disposing mid-call hangs up rather than going quiet', () async {
      final harness = CallHarness();
      await harness.connect();

      await harness.service.dispose();
      await pumpEventQueue();

      expect(harness.sink.types.last, 'm.call.hangup');
      expect(harness.engine.disposed, isTrue);
      expect(harness.audio.stopped, isTrue);

      await harness.signals.close();
      await harness.ticks.close();
      await harness.engine.close();
      await harness.audio.close();
    });
  });

  group('incoming call', () {
    test('ringing opens nothing — the microphone waits for an answer', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.signal(harness.invite());
      await pumpEventQueue();

      expect(harness.session?.state, CallState.ringing);
      expect(harness.session?.direction, CallDirection.incoming);
      expect(harness.engine.calls, isEmpty);
      expect(harness.engineBuilds, 0);
      expect(harness.sink.sent, isEmpty);
      // The audio session *is* taken, because a ringing call is a live call and
      // the ring belongs on the receiver. Nothing is captured until the call is
      // answered, which is the part that matters: a client that opened the
      // microphone to ring would be recording before anyone agreed to a call.
      expect(harness.audio.applied, [CallAudioRoute.earpiece]);
    });

    test('the answer goes back to the invite\'s room', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.signal(harness.invite(roomId: otherRoom));
      await pumpEventQueue();
      await harness.service.accept();
      await pumpEventQueue();

      expect(harness.engine.calls.first, 'createAnswer(video: false)');
      expect(harness.sink.types, ['m.call.answer']);
      expect(harness.sink.last!.roomId, otherRoom);
      expect(harness.sink.last!.callId, 'call-in');
    });

    test('a video call can be answered on audio', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.signal(harness.invite(video: true));
      await pumpEventQueue();
      expect(harness.session?.videoEnabled, isTrue);

      await harness.service.accept(video: false);
      await pumpEventQueue();

      // The camera is never opened, and the answer says so. It is still a video
      // call — the far end keeps sending its picture — which is why
      // `videoEnabled` stays true and only `cameraOn` goes down. Conflating the
      // two would drop the incoming video as well, which is not what the user
      // asked for.
      expect(harness.engine.calls.first, 'createAnswer(video: false)');
      expect(harness.session?.cameraOn, isFalse);
      expect(harness.session?.videoEnabled, isTrue);
    });

    test('declining sends a reject and never touches the engine', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.signal(harness.invite());
      await pumpEventQueue();
      await harness.service.decline();
      await pumpEventQueue();

      expect(harness.sink.types, ['m.call.reject']);
      expect(harness.session?.endReason, CallEndReason.localReject);
      expect(harness.engineBuilds, 0);
    });

    test('an invite that sat in a sync backlog does not ring', () async {
      // A device coming back after an hour offline receives every call of that
      // hour at once. Ringing for each is the failure the invite lifetime
      // exists to prevent.
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.signal(
        harness.invite(sentAt: t0.subtract(const Duration(minutes: 5))),
      );
      await pumpEventQueue();

      expect(harness.session, isNull);
      expect(harness.sink.sent, isEmpty);
    });

    test('an unanswered call gives up when the invite expires', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.signal(harness.invite());
      await pumpEventQueue();

      harness.advance(kDefaultInviteLifetime + const Duration(seconds: 1));
      await harness.tick();

      expect(harness.session?.endReason, CallEndReason.inviteTimeout);
      expect(harness.session?.state, CallState.ended);
    });
  });

  group('one call at a time', () {
    test('a second outgoing call is refused with a sentence', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      expect(
        await harness.service.placeCall(roomId: room, peer: annaPeer),
        isNull,
      );
      await pumpEventQueue();

      expect(
        await harness.service.placeCall(roomId: otherRoom, peer: annaPeer),
        CallStartFailure.busy,
      );
      // Nothing reached the wire for the second attempt, and the call in
      // progress is untouched.
      expect(harness.sink.types, ['m.call.invite']);
      expect(harness.session?.callId, 'call-1');
      expect(harness.engineBuilds, 1);
    });

    test('a second invite is rejected in its own room, not the call\'s', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();

      // The busy reject is the one outbound event that belongs to a *different*
      // room from the active call. Addressing it to the call's room would leave
      // the second caller ringing until their invite expired.
      harness.signal(harness.invite(callId: 'call-2', roomId: otherRoom));
      await pumpEventQueue();

      final reject = harness.sink.last!;
      expect(reject.type, 'm.call.reject');
      expect(reject.roomId, otherRoom);
      expect(reject.callId, 'call-2');
      expect(reject.reason, 'user_busy');
      expect(harness.session?.callId, 'call-1');
      expect(harness.session?.state, CallState.outgoingRinging);
    });

    test('the call after a call rings normally, on a new engine', () async {
      // A peer connection is not reusable and neither are the candidate
      // buffers. This is the app-level shape of the bug `weft_call`'s own suite
      // caught: a session's second call dropping every early candidate.
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      await harness.service.hangUp();
      await pumpEventQueue();
      final first = harness.engine.calls.length;

      harness.signal(harness.invite(callId: 'call-2'));
      await pumpEventQueue();
      expect(harness.session?.state, CallState.ringing);

      harness.signal(harness.candidates([ice('host')], callId: 'call-2'));
      await pumpEventQueue();
      await harness.service.accept();
      await pumpEventQueue();

      expect(harness.engineBuilds, 2);
      expect(harness.engine.calls.length, greaterThan(first));
      expect(harness.engine.applied, ['candidate:host']);
    });
  });

  group('candidates', () {
    test('remote candidates before the answer are flushed in order', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();

      // There is no peer connection to feed yet. Dropping these is the classic
      // cause of a call that connects at home and nowhere else — the host
      // candidates are the ones that arrive first.
      harness.signal(harness.candidates([ice('host'), ice('srflx')]));
      await pumpEventQueue();
      expect(harness.engine.applied, isEmpty);

      harness.signal(harness.answer());
      await pumpEventQueue();

      expect(harness.engine.applied, ['candidate:host', 'candidate:srflx']);
    });

    test('local candidates reach the wire once the invite has', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();

      harness.engine.candidates.add(ice('host'));
      await pumpEventQueue();

      final sent = harness.sink.ofType('m.call.candidates').single;
      expect(sent.roomId, room);
      expect(sent.callId, 'call-1');
      final candidates = sent.content['candidates']! as List;
      expect(candidates.length, 1);
      expect((candidates.single as Map)['candidate'], 'candidate:host');
    });

    test('one malformed candidate is not a call', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      harness.engine.candidateError = ArgumentError('nonsense');
      harness.signal(harness.candidates([ice('bogus')]));
      await pumpEventQueue();

      // This is why the machine emits an intent per candidate rather than one
      // per batch: a rejected candidate is logged and the call carries on.
      expect(harness.session?.state, CallState.connected);
    });

    test('candidates after the call ends are discarded', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      await harness.service.hangUp();
      await pumpEventQueue();
      final applied = List.of(harness.engine.applied);

      harness.signal(harness.candidates([ice('late')]));
      await pumpEventQueue();

      expect(harness.engine.applied, applied);
    });
  });

  group('when the call cannot start', () {
    test('a microphone that will not open is a reason, not a call', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.engine.descriptionError = StateError('permission denied');
      final failure = await harness.service.placeCall(
        roomId: room,
        peer: annaPeer,
      );
      await pumpEventQueue();

      expect(failure, CallStartFailure.mediaUnavailable);
      expect(
        harness.sink.ofType('m.call.invite'),
        isEmpty,
        reason: 'nothing was ever offered',
      );
      expect(harness.session?.endReason, CallEndReason.mediaFailed);
      expect(harness.service.hasActiveCall, isFalse);
    });

    test('an invite that never left is a call that cannot happen', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.sink.failures['m.call.invite'] = const CallSignallingException(
        'The homeserver refused the event.',
      );
      final failure = await harness.service.placeCall(
        roomId: room,
        peer: annaPeer,
      );
      await pumpEventQueue();

      expect(failure, CallStartFailure.signallingFailed);
      expect(harness.service.hasActiveCall, isFalse);
      expect(harness.engine.disposed, isTrue);
    });

    test('a failed candidate send does not end anything', () async {
      // The opposite of the invite: candidates are best-effort, and ending a
      // call because one batch failed would drop calls that were about to
      // connect.
      final harness = CallHarness();
      addTearDown(harness.dispose);

      harness.sink.failures['m.call.candidates'] =
          const CallSignallingException('rate limited');
      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();
      harness.engine.candidates.add(ice('host'));
      await pumpEventQueue();

      expect(harness.session?.state, CallState.outgoingRinging);
    });
  });

  group('a homeserver with no relay', () {
    test('the call is placed and the warning is on the state', () async {
      final harness = CallHarness(ice: turnMissing);
      addTearDown(harness.dispose);

      expect(
        await harness.service.placeCall(roomId: room, peer: annaPeer),
        isNull,
      );
      await pumpEventQueue();

      // A call with no relay still works on one network, so this is a sentence
      // to show rather than a reason to refuse to dial. The Matrix SDK logs it
      // at verbose level and returns an empty server list, which is how a
      // self-hosted account ends up with calls that work at home and nowhere
      // else with nothing on screen to explain it.
      expect(harness.sink.types, ['m.call.invite']);
      expect(harness.state.ice?.hasTurn, isFalse);
      expect(harness.state.warning, kNoRelayWarning);
    });

    test('the warning reaches the surfaces that watch the service', () async {
      final harness = CallHarness(ice: turnMissing);
      addTearDown(harness.dispose);

      final seen = <String?>[];
      final sub = harness.service.states.listen((s) => seen.add(s.warning));
      addTearDown(sub.cancel);

      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();

      expect(seen, isNotEmpty);
      expect(seen.last, kNoRelayWarning);
    });

    test('a relay that is present says nothing at all', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();

      expect(harness.state.ice?.hasTurn, isTrue);
      expect(harness.state.warning, isNull);
    });
  });

  group('the deadlines the state machine leaves open', () {
    test('a call that never connects is ended as an ICE failure', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();
      harness.signal(harness.answer());
      await pumpEventQueue();
      expect(harness.session?.state, CallState.connecting);

      // Nothing in `weft_call` ends a call stuck here; without this layer's
      // timeout it would sit silent forever.
      harness.advance(const Duration(seconds: 31));
      await harness.tick();

      expect(harness.session?.endReason, CallEndReason.iceFailed);
      expect(harness.sink.last!.type, 'm.call.hangup');
      expect(harness.sink.last!.reason, 'ice_failed');
    });

    test('a call that connects in time is not timed out', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      harness.advance(const Duration(minutes: 5));
      await harness.tick();

      expect(harness.session?.state, CallState.connected);
    });

    test('a dropped connection is given time to heal', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      harness.engine.states.add(MediaConnectionState.disconnected);
      await pumpEventQueue();

      // A phone changing from wifi to mobile does this every time. Ending here
      // would drop calls that were about to recover — and the user is told,
      // because a call that has gone quiet with nothing on screen is the moment
      // people start pressing buttons.
      expect(harness.state.reconnecting, isTrue);
      harness.advance(const Duration(seconds: 5));
      await harness.tick();
      expect(harness.session?.state, CallState.connected);

      harness.engine.states.add(MediaConnectionState.connected);
      await pumpEventQueue();
      expect(harness.state.reconnecting, isFalse);

      harness.advance(const Duration(minutes: 1));
      await harness.tick();
      expect(harness.session?.state, CallState.connected);
    });

    test('a connection that does not heal ends the call', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      harness.engine.states.add(MediaConnectionState.disconnected);
      await pumpEventQueue();

      harness.advance(const Duration(seconds: 21));
      await harness.tick();

      expect(harness.session?.endReason, CallEndReason.iceFailed);
      // "Reconnecting…" must not survive onto the end screen.
      expect(harness.state.reconnecting, isFalse);
    });

    test('a peer connection that fails outright does not wait', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      harness.engine.states.add(MediaConnectionState.failed);
      await pumpEventQueue();

      expect(harness.session?.endReason, CallEndReason.iceFailed);
    });
  });

  group('renegotiation', () {
    test('adding video offers, and settles on the far end\'s answer', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      await harness.service.requestVideo();
      await pumpEventQueue();

      // The camera is opened before the offer that describes it: offering video
      // and then failing to open the camera produces an answer for media that
      // never arrives.
      expect(harness.engine.calls, contains('setVideo(true)'));
      expect(harness.sink.types.last, 'm.call.negotiate');
      expect(harness.session?.cameraOn, isTrue);
      expect(harness.session?.videoEnabled, isFalse, reason: 'not yet agreed');

      harness.signal(
        CallNegotiateSignal(
          callId: 'call-1',
          partyId: peerParty,
          senderId: annaPeer.matrixUserId,
          description: const SessionDescription.answer(reanswerSdp),
          video: true,
        ),
      );
      await pumpEventQueue();

      expect(harness.session?.videoEnabled, isTrue);
      expect(harness.session?.state, CallState.connected);

      // The renegotiation is finished, so its deadline must not fire later and
      // undo a video call that is already up.
      harness.advance(const Duration(minutes: 1));
      await harness.tick();
      expect(harness.session?.videoEnabled, isTrue);
    });

    test('a far end that never answers leaves the call on audio', () async {
      // Without this the machine's negotiation latch stays set and every later
      // upgrade or hold is a silent no-op.
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      await harness.service.requestVideo();
      await pumpEventQueue();

      harness.advance(const Duration(seconds: 16));
      await harness.tick();

      expect(harness.session?.state, CallState.connected);
      expect(harness.session?.videoEnabled, isFalse);
      expect(
        harness.session?.cameraOn,
        isFalse,
        reason: 'the optimism is undone',
      );

      // And the latch is clear, so a second attempt is not swallowed.
      await harness.service.requestVideo();
      await pumpEventQueue();
      expect(harness.session?.cameraOn, isTrue);
    });

    test('the far end adding video is answered without being asked', () async {
      // WebRTC requires a prompt answer. The user-facing gate is on whether to
      // send *our* camera, and it belongs to the call screen.
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      harness.signal(
        CallNegotiateSignal(
          callId: 'call-1',
          partyId: peerParty,
          senderId: annaPeer.matrixUserId,
          description: const SessionDescription.offer(reofferSdp),
          video: true,
        ),
      );
      await pumpEventQueue();

      expect(harness.engine.calls, contains('createAnswer(video: true)'));
      expect(harness.sink.types.last, 'm.call.negotiate');
      expect(harness.session?.videoEnabled, isTrue);
      expect(harness.session?.state, CallState.connected);
    });
  });

  group('the controls, against the engine', () {
    test('mute moves the engine and the session together', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      await harness.service.setMuted(muted: true);
      await pumpEventQueue();

      expect(harness.engine.calls, contains('setMute(true)'));
      expect(harness.session?.muted, isTrue);

      await harness.service.setMuted(muted: false);
      await pumpEventQueue();
      expect(harness.engine.calls, contains('setMute(false)'));
      expect(harness.session?.muted, isFalse);
    });

    test('the camera can be stopped without renegotiating', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect(video: true);
      final before = harness.sink.types.length;

      await harness.service.setCameraEnabled(enabled: false);
      await harness.service.switchCamera();
      await pumpEventQueue();

      expect(harness.engine.calls, contains('setVideo(false)'));
      expect(harness.engine.calls, contains('switchCamera()'));
      expect(harness.session?.cameraOn, isFalse);
      // Still a video call, and nothing was sent: a camera toggle that
      // renegotiated would pause the media every time somebody covered the lens.
      expect(harness.session?.videoEnabled, isTrue);
      expect(harness.sink.types.length, before);
    });
  });

  group('audio routing', () {
    test('a voice call uses the receiver and the proximity sensor', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();

      expect(harness.audio.applied.last, CallAudioRoute.earpiece);
      expect(harness.audio.proximity, isTrue);
      expect(harness.state.audio.proximityActive, isTrue);
    });

    test('a video call uses the speaker and leaves the screen on', () async {
      // Blanking the screen during a video call turns it black and puts the
      // hang-up button out of reach.
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.service.placeCall(
        roomId: room,
        peer: annaPeer,
        video: true,
      );
      await pumpEventQueue();

      expect(harness.audio.applied.last, CallAudioRoute.speaker);
      expect(harness.audio.proximity, isFalse);
      // The session's own flag follows the resolved route, so the call screen's
      // speaker button cannot disagree with where the sound is going.
      expect(harness.session?.speakerOn, isTrue);
    });

    test('an explicit choice is honoured, and moves the session', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      await harness.service.setAudioRoute(CallAudioRoute.speaker);
      await pumpEventQueue();

      expect(harness.audio.applied.last, CallAudioRoute.speaker);
      expect(harness.state.audio.route, CallAudioRoute.speaker);
      expect(harness.session?.speakerOn, isTrue);
      expect(harness.state.audio.proximityActive, isFalse);
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
      await harness.service.placeCall(roomId: room, peer: annaPeer);
      await pumpEventQueue();
      expect(harness.audio.applied.last, CallAudioRoute.wiredHeadset);

      harness.audio.routes.add({
        CallAudioRoute.earpiece,
        CallAudioRoute.speaker,
      });
      await pumpEventQueue();

      expect(harness.audio.applied.last, CallAudioRoute.earpiece);
      expect(harness.state.audio.route, CallAudioRoute.earpiece);
    });

    test('a headset plugged back in restores the choice it names', () async {
      // The user's choice is never cleared — it stops matching and starts
      // matching again, which is the whole of the unplug/replug behaviour.
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      await harness.service.setAudioRoute(CallAudioRoute.bluetooth);
      await pumpEventQueue();
      expect(harness.state.audio.route, CallAudioRoute.earpiece);

      harness.audio.routes.add({
        CallAudioRoute.earpiece,
        CallAudioRoute.speaker,
        CallAudioRoute.bluetooth,
      });
      await pumpEventQueue();

      expect(harness.state.audio.route, CallAudioRoute.bluetooth);
    });

    test('the audio session is released once the call is over', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.connect();
      await harness.service.hangUp();
      await pumpEventQueue();

      expect(harness.audio.stopped, isTrue);
      expect(harness.audio.proximity, isFalse);
    });

    test('an idle app does not fight whatever else is playing', () async {
      final harness = CallHarness();
      addTearDown(harness.dispose);

      await harness.tick();
      await harness.tick();

      expect(harness.audio.applied, isEmpty);
      expect(harness.audio.stopped, isFalse);
    });
  });

  group('the route policy, on its own', () {
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
      expect(
        resolveCallAudioRoute(
          video: false,
          available: const {
            CallAudioRoute.earpiece,
            CallAudioRoute.speaker,
            CallAudioRoute.wiredHeadset,
          },
        ),
        CallAudioRoute.wiredHeadset,
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
      expect(
        resolveCallAudioRoute(video: false, available: const {}),
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
      // that turns out to be a virtual sound card is worse than not offering it.
      expect(callAudioRouteForDevice('Loopback (virtual)'), isNull);
    });
  });

  group('negotiated codecs', () {
    test('are read from the SDP, per media section', () {
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
