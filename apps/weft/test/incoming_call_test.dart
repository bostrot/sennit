import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/call/call_controls.dart';
import 'package:weft/features/call/call_overlay.dart';
import 'package:weft/features/call/incoming_call_sheet.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/call_fixtures.dart';

/// A call arriving, in the two shapes a ringing call has.
///
/// The rule underneath all of this is that dropping a call must never happen by
/// accident and answering one must never happen by brushing against something.
/// So: a phone is taken over completely, a desktop window gets a card, tapping
/// the card opens the call rather than answering it, and every accept and
/// decline goes through [CallControls] to one state machine.
///
/// The last group runs the accept and decline paths through a real
/// `CallService`, because the two events they produce — `m.call.answer` and
/// `m.call.reject` — are the only place the difference between "answered" and
/// "declined" survives. Element shows one as a call and the other as a
/// declined call; nothing local tells them apart.
void main() {
  group('the full-screen sheet', () {
    testWidgets('accept and decline reach the controls', (tester) async {
      final controls = RecordingControls();
      await pumpCallSurface(
        tester,
        IncomingCallSheet(session: ringingSession(), controls: controls),
      );

      expect(find.text('Incoming call'), findsOneWidget);
      // A voice call has one accept, not two.
      expect(find.byTooltip('Voice only'), findsNothing);

      await tester.tap(find.byTooltip('Decline'));
      await tester.tap(find.byTooltip('Accept'));
      await tester.pump();

      // `accept(null)` and not `accept(false)`: answering without saying
      // anything about video means "whatever they offered".
      expect(controls.actions, ['decline', 'accept(null)']);
    });

    testWidgets('a video call can be answered on audio', (tester) async {
      // A first-class choice rather than a fallback: it is how a video call is
      // taken somewhere the user does not want to be seen, and without it the
      // alternative is declining.
      final controls = RecordingControls();
      await pumpCallSurface(
        tester,
        IncomingCallSheet(
          session: ringingSession(video: true),
          controls: controls,
        ),
      );

      expect(find.text('Incoming video call'), findsOneWidget);
      expect(find.byTooltip('Video'), findsOneWidget);

      await tester.tap(find.byTooltip('Voice only'));
      await tester.pump();
      expect(controls.actions, ['accept(false)']);

      await tester.tap(find.byTooltip('Video'));
      await tester.pump();
      expect(controls.actions, ['accept(false)', 'accept(null)']);
    });

    testWidgets('every action is labelled as well as drawn', (tester) async {
      // The sheet is drawn by [CallOverlay], which sits above the navigator and
      // therefore above the only Overlay in the app — so a tooltip cannot float
      // anywhere. The written label under each button is what is left, and it
      // is also what a screen reader announces.
      await pumpCallSurface(
        tester,
        IncomingCallSheet(
          session: ringingSession(video: true),
          controls: RecordingControls(),
        ),
      );

      expect(find.text('Decline'), findsOneWidget);
      expect(find.text('Voice only'), findsOneWidget);
      expect(find.text('Video'), findsOneWidget);
    });
  });

  group('the heads-up card', () {
    testWidgets('carries the same two actions', (tester) async {
      final controls = RecordingControls();
      await pumpCallSurface(
        tester,
        Align(
          alignment: Alignment.topCenter,
          child: IncomingCallBanner(
            session: ringingSession(),
            controls: controls,
          ),
        ),
      );

      await tester.tap(find.byTooltip('Decline'));
      await tester.tap(find.byTooltip('Accept'));
      await tester.pump();

      expect(controls.actions, ['decline', 'accept(null)']);
    });

    testWidgets('tapping the card opens the call, it does not answer it', (
      tester,
    ) async {
      final controls = RecordingControls();
      var opened = 0;
      await pumpCallSurface(
        tester,
        Align(
          alignment: Alignment.topCenter,
          child: IncomingCallBanner(
            session: ringingSession(),
            controls: controls,
            onOpen: () => opened++,
          ),
        ),
      );

      await tester.tap(find.text('Incoming call'));
      await tester.pump();

      expect(opened, 1);
      expect(controls.actions, isEmpty);
    });
  });

  group('the caller, through the merged identity', () {
    /// Anna as the inbox knows her: one person, three networks, and only the
    /// Matrix leg able to carry a call.
    final contact = UnifiedContact(
      id: 'c-anna',
      displayName: 'Anna Maven',
      handles: const [
        NetworkHandle(
          id: 'anna_wa',
          network: ChatNetwork.whatsapp,
          remoteId: '4915112345678',
          matrixUserId: '@whatsapp_4915112345678:example.org',
          roomId: '!wa:example.org',
          displayName: 'Anna M.',
        ),
        NetworkHandle(
          id: 'anna_mx',
          network: ChatNetwork.matrix,
          remoteId: '@anna:example.org',
          matrixUserId: '@anna:example.org',
          roomId: room,
          displayName: 'anna',
        ),
      ],
    );

    testWidgets('the sheet says what the inbox row said', (tester) async {
      final peer = CallPeer.forContact(contact)!;
      await pumpCallSurface(
        tester,
        IncomingCallSheet(
          session: ringingSession(peer: peer),
          controls: RecordingControls(),
        ),
      );

      // Not `@anna:example.org`, and not the per-network display name either:
      // the merged contact's name is the one the user chose to see.
      expect(find.text('Anna Maven'), findsOneWidget);
      expect(find.text('@anna:example.org'), findsNothing);
      expect(find.text('anna'), findsNothing);
    });

    testWidgets('the avatar keeps every network the person is on', (
      tester,
    ) async {
      // A call with someone reached across three networks should look like the
      // conversation it came from, badges and all — the same [WeftAvatar] the
      // inbox row drew.
      final peer = CallPeer.forContact(contact)!;
      await pumpCallSurface(
        tester,
        IncomingCallSheet(
          session: ringingSession(peer: peer),
          controls: RecordingControls(),
        ),
      );

      final avatar = tester.widget<WeftAvatar>(find.byType(WeftAvatar));
      expect(avatar.label, 'Anna Maven');
      expect(avatar.networks, contains(ChatNetwork.whatsapp));
      expect(avatar.networks, contains(ChatNetwork.matrix));
    });

    testWidgets('a caller with no name at all is still identifiable', (
      tester,
    ) async {
      await pumpCallSurface(
        tester,
        IncomingCallSheet(
          session: ringingSession(
            peer: const CallPeer(matrixUserId: '@stranger:example.org'),
          ),
          controls: RecordingControls(),
        ),
      );

      expect(find.text('@stranger:example.org'), findsOneWidget);
    });
  });

  group('which shape the overlay draws', () {
    testWidgets('a narrow window is taken over completely', (tester) async {
      // A call that arrived as a card at the top of the inbox is a call that
      // gets missed.
      await pumpCallOverlay(
        tester,
        call: serviceState(ringingSession()),
        size: const Size(420, 900),
      );

      expect(find.byType(IncomingCallSheet), findsOneWidget);
      expect(find.byType(IncomingCallBanner), findsNothing);
      // The bar is for a call in progress; a ringing one is already on screen.
      expect(find.byType(MinimisedCallBar), findsNothing);
    });

    testWidgets('a wide window gets the card instead', (tester) async {
      await pumpCallOverlay(
        tester,
        call: serviceState(ringingSession()),
        size: const Size(1200, 900),
      );

      expect(find.byType(IncomingCallBanner), findsOneWidget);
      expect(find.byType(IncomingCallSheet), findsNothing);
      // The app is still usable behind the card, which is the whole point of
      // the wide variant.
      expect(find.text('the app'), findsOneWidget);
    });

    testWidgets('an outgoing call rings nobody here', (tester) async {
      await pumpCallOverlay(
        tester,
        call: serviceState(callSession(state: CallState.outgoingRinging)),
      );

      expect(find.byType(IncomingCallSheet), findsNothing);
      expect(find.byType(IncomingCallBanner), findsNothing);
    });
  });

  group('accept and decline, all the way to the wire', () {
    testWidgets('accepting answers in the room the invite arrived in', (
      tester,
    ) async {
      final harness = CallHarness();
      addTearDown(() => disposeAfterWidgetTest(harness));

      harness.signal(harness.invite(roomId: otherRoom));
      await tester.pump();
      await tester.pump();
      expect(harness.session?.state, CallState.ringing);

      await pumpCallSurface(
        tester,
        IncomingCallSheet(
          session: harness.session!,
          controls: CallServiceControls(harness.service),
        ),
      );
      await tester.tap(find.byTooltip('Accept'));
      await tester.pump();
      await tester.pump();

      expect(harness.sink.types, ['m.call.answer']);
      expect(harness.sink.last!.roomId, otherRoom);
      expect(harness.engine.calls.first, 'createAnswer(video: false)');
      expect(harness.session?.state, CallState.connecting);
    });

    testWidgets('answering a video call on audio never opens the camera', (
      tester,
    ) async {
      final harness = CallHarness();
      addTearDown(() => disposeAfterWidgetTest(harness));

      harness.signal(harness.invite(video: true));
      await tester.pump();
      await tester.pump();

      await pumpCallSurface(
        tester,
        IncomingCallSheet(
          session: harness.session!,
          controls: CallServiceControls(harness.service),
        ),
      );
      await tester.tap(find.byTooltip('Voice only'));
      await tester.pump();
      await tester.pump();

      expect(harness.engine.calls.first, 'createAnswer(video: false)');
      expect(harness.session?.cameraOn, isFalse);
    });

    testWidgets('declining sends a reject and opens nothing', (tester) async {
      final harness = CallHarness();
      addTearDown(() => disposeAfterWidgetTest(harness));

      harness.signal(harness.invite());
      await tester.pump();
      await tester.pump();

      await pumpCallSurface(
        tester,
        IncomingCallSheet(
          session: harness.session!,
          controls: CallServiceControls(harness.service),
        ),
      );
      await tester.tap(find.byTooltip('Decline'));
      await tester.pump();
      await tester.pump();

      // `m.call.reject` rather than `m.call.hangup`: the far end shows the
      // first as declined and the second as ended, and the user did decline.
      expect(harness.sink.types, ['m.call.reject']);
      expect(harness.session?.endReason, CallEndReason.localReject);
      expect(
        harness.engineBuilds,
        0,
        reason: 'the microphone was never opened',
      );
    });
  });

  group('a call that stops ringing while the screen is up', () {
    testWidgets('says what happened instead of asking again', (tester) async {
      // Answered on another device, given up on, or expired. Whatever the
      // reason, the screen has nothing left to ask.
      await pumpCallOverlay(
        tester,
        call: serviceState(
          callSession(
            state: CallState.ended,
            direction: CallDirection.incoming,
            endReason: CallEndReason.inviteTimeout,
          ),
        ),
      );

      expect(find.byType(IncomingCallSheet), findsNothing);
      expect(find.byType(IncomingCallBanner), findsNothing);
    });
  });
}
