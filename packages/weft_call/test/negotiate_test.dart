import 'package:test/test.dart';
import 'package:weft_call/weft_call.dart';

import 'support/fixtures.dart';

/// Changing a call that is already up.
///
/// Renegotiation is deliberately separate from the call's lifecycle, and this
/// file is where that separation is pinned. Turning on the camera is a request
/// that can be refused, time out, or fail in the peer connection, and none of
/// those may end a conversation two people are in the middle of: the video
/// button goes back to off and they keep talking. The opposite behaviour — a
/// call that drops because someone tapped video on a bad network — is the one
/// users remember.
void main() {
  group('audio to video, requested here', () {
    test('the camera is opened before the offer that describes it', () {
      // Offering video and then failing to open the camera produces an answer
      // for media that never arrives, which the far end paints as a frozen
      // black rectangle rather than an error.
      final call = CallHarness()..outgoingConnected();

      final asked = call.handle(const RequestVideoUpgrade());
      expect(typesOf(asked.intents), [ApplyVideo, CreateOffer]);
      expect((asked.media.first as ApplyVideo).enabled, isTrue);
      expect((asked.media.last as CreateOffer).video, isTrue);
      expect(asked.signalling, isEmpty, reason: 'nothing to send yet');
      expect(call.state, CallState.connected, reason: 'the call never pauses');
    });

    test('the offer travels as m.call.negotiate, never as a second invite', () {
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(const RequestVideoUpgrade());

      final sent = call.handle(const LocalDescriptionReady(reofferSdp));
      final negotiate = sent.signalling.single as SendNegotiate;
      expect(negotiate, isNot(isA<SendInvite>()));
      expect(negotiate.callId, 'out-1');
      expect(negotiate.partyId, localParty);
      expect(negotiate.description, reofferSdp);
      expect(negotiate.video, isTrue);
      expect(negotiate.lifetime, kDefaultCallEventLifetime);
    });

    test('video is only enabled once the far end has agreed', () {
      // Optimism here is what produces a local preview of a call the other
      // person is not receiving.
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(const RequestVideoUpgrade())
        ..handle(const LocalDescriptionReady(reofferSdp));
      expect(call.session!.videoEnabled, isFalse, reason: 'not yet agreed');
      expect(call.session!.cameraOn, isTrue, reason: 'but capturing already');

      final agreed = call.handle(negotiateFrom(reanswerSdp));
      expect(typesOf(agreed.intents), [ApplyRemoteDescription]);
      expect(agreed.signalling, isEmpty);
      expect(call.state, CallState.connected);
      expect(call.session!.videoEnabled, isTrue);
      expect(call.session!.cameraOn, isTrue);
    });

    test('a second request while one is in flight is ignored', () {
      // WebRTC allows exactly one offer/answer exchange outstanding; a second
      // would come back from the peer connection as an error the user cannot
      // act on.
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(const RequestVideoUpgrade());
      expect(call.handle(const RequestVideoUpgrade()).isNoOp, isTrue);
    });

    test('asking for the state the call is already in does nothing', () {
      final call = CallHarness()..outgoingConnected(video: true);
      expect(call.handle(const RequestVideoUpgrade()).isNoOp, isTrue);
    });

    test('an upgrade before the call connects does nothing', () {
      final call = CallHarness()..placeCall();
      expect(call.handle(const RequestVideoUpgrade()).isNoOp, isTrue);

      call.handle(answerFrom());
      expect(call.state, CallState.connecting);
      expect(call.handle(const RequestVideoUpgrade()).isNoOp, isTrue);
    });
  });

  group('video back to audio', () {
    test('turning video off renegotiates and settles on the answer', () {
      final call = CallHarness()..outgoingConnected(video: true);

      final asked = call.handle(const RequestVideoUpgrade(video: false));
      expect((asked.media.first as ApplyVideo).enabled, isFalse);
      expect((asked.media.last as CreateOffer).video, isFalse);

      final sent = call.handle(const LocalDescriptionReady(reofferSdp));
      expect((sent.signalling.single as SendNegotiate).video, isFalse);
      expect(call.session!.videoEnabled, isTrue, reason: 'still, until agreed');

      call.handle(negotiateFrom(reanswerSdp, video: false));
      expect(call.session!.videoEnabled, isFalse);
      expect(call.session!.cameraOn, isFalse);
      expect(call.state, CallState.connected);
    });
  });

  group('audio to video, requested by the far end', () {
    test('a remote offer is answered without asking anyone', () {
      // WebRTC requires a prompt answer. The user-facing "accept video?" gate
      // belongs in the UI and decides whether to send *our* camera, not whether
      // to renegotiate at all.
      final call = CallHarness()..outgoingConnected();

      final offered = call.handle(negotiateFrom(reofferSdp));
      final createAnswer = offered.media.single as CreateAnswer;
      expect(createAnswer.remoteOffer, reofferSdp);
      expect(createAnswer.video, isTrue);
      expect(offered.signalling, isEmpty);
      expect(call.state, CallState.connected);
    });

    test('our answer goes back as m.call.negotiate and settles the upgrade', () {
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(negotiateFrom(reofferSdp));

      final answered = call.handle(const LocalDescriptionReady(reanswerSdp));
      final negotiate = answered.signalling.single as SendNegotiate;
      expect(negotiate.description, reanswerSdp);
      expect(negotiate.video, isTrue);
      expect(
        call.session!.videoEnabled,
        isTrue,
        reason: 'answering an offer settles it — there is nothing left to wait '
            'for',
      );
    });

    test('a renegotiation offer is ignored before the call is up', () {
      final call = CallHarness()..ring();
      expect(call.handle(negotiateFrom(reofferSdp, callId: 'in-1')).isNoOp, isTrue);

      call.handle(const AcceptCall());
      expect(call.state, CallState.connecting);
      expect(call.handle(negotiateFrom(reofferSdp, callId: 'in-1')).isNoOp, isTrue);
    });

    test('a renegotiation from a device we did not answer is ignored', () {
      // The whole point of latching the far end's party id: a second device
      // must not be able to reshape a session negotiated with the first.
      final call = CallHarness()..outgoingConnected();
      expect(
        call.handle(negotiateFrom(reofferSdp, partyId: otherPeerParty)).isNoOp,
        isTrue,
      );
      expect(call.session!.videoEnabled, isFalse);
    });

    test('an answer with nothing in flight is applied and changes nothing', () {
      final call = CallHarness()..outgoingConnected();
      final stray = call.handle(negotiateFrom(reanswerSdp));
      expect(typesOf(stray.intents), [ApplyRemoteDescription]);
      expect(call.session!.videoEnabled, isFalse);
      expect(call.state, CallState.connected);
    });
  });

  group('a renegotiation that fails', () {
    test('the call stays connected on audio and the camera goes back off', () {
      final call = CallHarness()
        ..outgoingConnected(codecs: const CodecSummary(audio: 'opus'))
        ..handle(const RequestVideoUpgrade())
        ..handle(const LocalDescriptionReady(reofferSdp));

      final failed = call.handle(const NegotiationFailed());
      expect(typesOf(failed.intents), [ApplyVideo]);
      expect((failed.media.single as ApplyVideo).enabled, isFalse);
      expect(failed.signalling, isEmpty, reason: 'the far end need not care');

      expect(call.state, CallState.connected);
      expect(call.session!.videoEnabled, isFalse);
      expect(call.session!.cameraOn, isFalse);
      expect(call.session!.endReason, isNull);
      expect(call.session!.codecs!.audio, 'opus', reason: 'audio is untouched');
    });

    test('the call can still be muted, held and hung up afterwards', () {
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(const RequestVideoUpgrade())
        ..handle(const NegotiationFailed());

      expect(call.handle(const SetMuted(true)).isNoOp, isFalse);
      final hungUp = call.handle(const HangUp());
      expect((hungUp.signalling.single as SendHangup).reason,
          CallEndReason.userHangup);
    });

    test('a failure releases the slot, so the user can try again', () {
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(const RequestVideoUpgrade())
        ..handle(const NegotiationFailed());

      final retried = call.handle(const RequestVideoUpgrade());
      expect(typesOf(retried.intents), [ApplyVideo, CreateOffer]);

      call.handle(const LocalDescriptionReady(reofferSdp));
      call.handle(negotiateFrom(reanswerSdp));
      expect(call.session!.videoEnabled, isTrue);
    });

    test('a failure with nothing in flight does nothing', () {
      final call = CallHarness()..outgoingConnected();
      expect(call.handle(const NegotiationFailed()).isNoOp, isTrue);
      expect(call.state, CallState.connected);
    });

    test('a downgrade that fails leaves video on', () {
      final call = CallHarness()
        ..outgoingConnected(video: true)
        ..handle(const RequestVideoUpgrade(video: false))
        ..handle(const LocalDescriptionReady(reofferSdp));

      final failed = call.handle(const NegotiationFailed());
      expect((failed.media.single as ApplyVideo).enabled, isTrue);
      expect(call.session!.videoEnabled, isTrue);
      expect(call.session!.cameraOn, isTrue);
    });
  });

  group('hold', () {
    test('holding suspends the call and re-offers', () {
      final call = CallHarness()..outgoingConnected();

      final held = call.handle(const SetHold(true));
      expect(typesOf(held.intents), [CreateOffer]);
      expect(call.state, CallState.onHold);
      expect(call.session!.state, CallState.onHold);

      final sent = call.handle(const LocalDescriptionReady(reofferSdp));
      final negotiate = sent.signalling.single as SendNegotiate;
      expect(negotiate.video, isFalse, reason: 'hold does not change the media');

      call.handle(negotiateFrom(reanswerSdp, video: false));
      expect(call.state, CallState.onHold, reason: 'still held once agreed');
    });

    test('resuming returns to connected', () {
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(const SetHold(true))
        ..handle(const LocalDescriptionReady(reofferSdp))
        ..handle(negotiateFrom(reanswerSdp, video: false));

      final resumed = call.handle(const SetHold(false));
      expect(typesOf(resumed.intents), [CreateOffer]);
      expect(call.state, CallState.connected);
    });

    test('holding twice does nothing the second time', () {
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(const SetHold(true))
        ..handle(const LocalDescriptionReady(reofferSdp))
        ..handle(negotiateFrom(reanswerSdp, video: false));
      expect(call.handle(const SetHold(true)).isNoOp, isTrue);
    });

    test('a hold that fails to negotiate is undone', () {
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(const SetHold(true))
        ..handle(const LocalDescriptionReady(reofferSdp));

      call.handle(const NegotiationFailed());
      expect(call.state, CallState.connected, reason: 'never actually held');
      expect(call.session!.state, CallState.connected);
    });

    test('a held call still hangs up cleanly', () {
      final call = CallHarness()
        ..outgoingConnected()
        ..handle(const SetHold(true));

      final hungUp = call.handle(const HangUp());
      expect(typesOf(hungUp.intents), [SendHangup, DisposeMedia]);
      call.handle(const MediaDisposed());
      expect(call.state, CallState.ended);
    });

    test('holding a call that is not up does nothing', () {
      final call = CallHarness()..placeCall();
      expect(call.handle(const SetHold(true)).isNoOp, isTrue);
      expect(call.state, CallState.outgoingRinging);
    });
  });

  group('renegotiating from the answering side', () {
    test('the callee can upgrade its own call to video', () {
      // The answering side reached `connected` by a different path, and a
      // renegotiation must not be mistaken there for a second answer.
      final call = CallHarness()..incomingConnected();

      call.handle(const RequestVideoUpgrade());
      final sent = call.handle(const LocalDescriptionReady(reofferSdp));
      final negotiate = sent.signalling.single as SendNegotiate;
      expect(negotiate.callId, 'in-1');
      expect(negotiate.video, isTrue);

      call.handle(negotiateFrom(reanswerSdp, callId: 'in-1'));
      expect(call.session!.videoEnabled, isTrue);
      expect(call.state, CallState.connected);
    });
  });
}
