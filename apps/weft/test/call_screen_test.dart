import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/call_providers.dart';
import 'package:weft/features/call/call_labels.dart';
import 'package:weft/features/call/call_overlay.dart';
import 'package:weft/features/call/call_video_view.dart';
import 'package:weft/services/call/call_audio.dart';
import 'package:weft/services/call/call_service.dart';
import 'package:weft_call/weft_call.dart';

import 'support/call_fixtures.dart';

/// The call screen, in each state a call can put it in.
///
/// [CallScreenBody] is a pure function of a [CallServiceState] and a
/// [CallControls], which is what makes this possible at all: every scene below
/// is one constructor call, including the several that take a real network
/// failure to reach on a device.
///
/// Two things are worth pinning here and nowhere else. The **sentences**, which
/// no golden proves — a call nobody answered has to say "No answer" rather than
/// "Call failed", and the wire cannot tell those apart. And **which control each
/// button drives**, because a mute button wired to the speaker looks perfect in
/// an image.
void main() {
  group('what each state says', () {
    testWidgets('an outgoing call is calling, and cannot add video yet', (
      tester,
    ) async {
      await pumpCallScreen(
        tester,
        serviceState(callSession(state: CallState.outgoingRinging)),
      );

      expect(find.text('Anna'), findsWidgets);
      expect(find.text('Calling…'), findsOneWidget);
      // A video upgrade is a renegotiation, and there is nothing to renegotiate
      // until there is a session.
      expect(find.byTooltip('Add video'), findsOneWidget);
      expect(actionEnabled(tester, 'Add video'), isFalse);
      expect(find.byTooltip('Switch camera'), findsNothing);
    });

    testWidgets('a connecting call with no relay says so', (tester) async {
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connecting),
          ice: turnMissing,
        ),
      );

      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.text(kNoRelayWarning), findsOneWidget);
      expect(actionEnabled(tester, 'Add video'), isFalse);
    });

    testWidgets('the relay warning goes away once media is flowing', (
      tester,
    ) async {
      // By then the absence of a relay has stopped mattering, and a warning that
      // stays up for a whole call is a warning nobody reads the next time.
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, connectedAt: t0),
          ice: turnMissing,
        ),
      );

      expect(find.text(kNoRelayWarning), findsNothing);
    });

    testWidgets('a connected voice call counts, and names its codecs', (
      tester,
    ) async {
      await withCallClock(() async {
        await pumpCallScreen(
          tester,
          serviceState(
            callSession(
              state: CallState.connected,
              connectedAt: t0.subtract(const Duration(seconds: 65)),
              codecs: const CodecSummary(audio: 'opus'),
            ),
          ),
        );

        expect(find.text('1:05'), findsOneWidget);
        expect(find.text('opus'), findsOneWidget);
        // A voice call has no picture, so it shows who is on it.
        expect(find.byType(CallVideoView), findsNothing);
      });
    });

    testWidgets('a connected video call draws two surfaces', (tester) async {
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, video: true, connectedAt: t0),
          video: const NoPictures(),
        ),
      );

      // The far end's picture and the local preview. Neither has a stream in a
      // widget test, so both draw their placeholder — which is also what a real
      // video call draws in the second before the first frame.
      expect(find.byType(CallVideoView), findsNWidgets(2));
      expect(find.byTooltip('Turn camera off'), findsOneWidget);
      expect(find.byTooltip('Add video'), findsNothing);
    });

    testWidgets('a video call with the camera off keeps only one surface', (
      tester,
    ) async {
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(
            state: CallState.connected,
            video: true,
            cameraOn: false,
            connectedAt: t0,
          ),
          video: const NoPictures(),
        ),
      );

      expect(find.byType(CallVideoView), findsOneWidget);
      expect(find.byTooltip('Turn camera on'), findsOneWidget);
      // Nothing to switch when nothing is capturing.
      expect(find.byTooltip('Switch camera'), findsNothing);
    });

    testWidgets('a dropped connection outranks the duration', (tester) async {
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, connectedAt: t0),
          reconnecting: true,
        ),
      );

      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.text('Weak connection — trying to recover'), findsOneWidget);
    });

    testWidgets('a held call says so', (tester) async {
      await pumpCallScreen(
        tester,
        serviceState(callSession(state: CallState.onHold, connectedAt: t0)),
      );

      expect(find.text('On hold'), findsOneWidget);
      // Still live, so the controls still work.
      expect(actionEnabled(tester, 'Hang up'), isTrue);
    });

    testWidgets('an ending call is a real frame, not a flash', (tester) async {
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(
            state: CallState.ending,
            endReason: CallEndReason.userHangup,
          ),
        ),
      );

      expect(find.text('Ending…'), findsOneWidget);
    });

    testWidgets('a call that ended says why, and its buttons are inert', (
      tester,
    ) async {
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(
            state: CallState.ended,
            endReason: CallEndReason.remoteReject,
          ),
        ),
        controls: controls,
      );

      expect(find.text('They declined'), findsOneWidget);
      await tester.tap(find.byTooltip('Hang up'));
      await tester.tap(find.byTooltip('Mute'));
      await tester.pump();
      expect(controls.actions, isEmpty);
    });
  });

  group('each control drives its own action', () {
    testWidgets('mute, speaker, video and hang up', (tester) async {
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(callSession(state: CallState.connected, connectedAt: t0)),
        controls: controls,
      );

      await tester.tap(find.byTooltip('Mute'));
      await tester.tap(find.byTooltip('Speaker'));
      await tester.tap(find.byTooltip('Add video'));
      await tester.tap(find.byTooltip('Hang up'));
      await tester.pump();

      expect(controls.actions, [
        'setMuted(true)',
        'setAudioRoute(speaker)',
        'requestVideo(true)',
        'hangUp',
      ]);
    });

    testWidgets('a muted call offers to unmute, not to mute again', (
      tester,
    ) async {
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, muted: true, connectedAt: t0),
        ),
        controls: controls,
      );

      expect(find.byTooltip('Mute'), findsNothing);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pump();
      expect(controls.actions, ['setMuted(false)']);
    });

    testWidgets('the speaker button goes back to the receiver', (tester) async {
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, connectedAt: t0),
          audio: const CallAudioState(route: CallAudioRoute.speaker),
        ),
        controls: controls,
      );

      await tester.tap(find.byTooltip('Speaker off'));
      await tester.pump();
      expect(controls.actions, ['setAudioRoute(earpiece)']);
    });

    testWidgets('the camera controls belong to a video call', (tester) async {
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, video: true, connectedAt: t0),
          video: const NoPictures(),
        ),
        controls: controls,
      );

      await tester.tap(find.byTooltip('Switch camera'));
      await tester.tap(find.byTooltip('Turn camera off'));
      await tester.pump();

      expect(controls.actions, ['switchCamera', 'setCameraEnabled(false)']);
    });

    testWidgets('more than two audio routes become a menu', (tester) async {
      // A phone with nothing plugged in should not make the user open a menu to
      // reach the loudspeaker; a phone with a car kit paired should not pretend
      // the choice is binary.
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, connectedAt: t0),
          audio: const CallAudioState(
            route: CallAudioRoute.bluetooth,
            available: {
              CallAudioRoute.earpiece,
              CallAudioRoute.speaker,
              CallAudioRoute.bluetooth,
            },
          ),
        ),
        controls: controls,
      );

      await tester.tap(find.byType(PopupMenuButton<CallAudioRoute>));
      await tester.pumpAndSettle();
      expect(find.text('Receiver'), findsOneWidget);
      expect(find.text('Bluetooth'), findsOneWidget);

      await tester.tap(find.text('Speaker').last);
      await tester.pumpAndSettle();

      expect(controls.actions, ['setAudioRoute(speaker)']);
    });

    testWidgets('minimising leaves the call alone', (tester) async {
      final controls = RecordingControls();
      var minimised = 0;
      await pumpCallScreen(
        tester,
        serviceState(callSession(state: CallState.connected, connectedAt: t0)),
        controls: controls,
        onClose: () => minimised++,
      );

      await tester.tap(find.byTooltip('Minimise call'));
      await tester.pump();

      expect(minimised, 1);
      expect(controls.actions, isEmpty, reason: 'the call is still up');
    });
  });

  group('the video-upgrade prompt', () {
    testWidgets('the far end adding video asks about this side\'s camera', (
      tester,
    ) async {
      // The gate is on the camera and not on the renegotiation: WebRTC needs a
      // prompt answer, so `weft_call` has already answered and the camera is
      // already capturing by the time a person can be asked anything.
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(callSession(state: CallState.connected, connectedAt: t0)),
        controls: controls,
      );
      expect(find.textContaining('turned on video'), findsNothing);

      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, video: true, connectedAt: t0),
          video: const NoPictures(),
        ),
        controls: controls,
      );
      await tester.pump();

      expect(find.text('Anna turned on video'), findsOneWidget);
      expect(find.text('Your camera is on as well.'), findsOneWidget);

      await tester.tap(find.text('Turn mine off'));
      await tester.pump();

      expect(controls.actions, ['setCameraEnabled(false)']);
      expect(find.text('Anna turned on video'), findsNothing);
    });

    testWidgets('keeping the camera on dismisses the prompt too', (
      tester,
    ) async {
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(callSession(state: CallState.connected, connectedAt: t0)),
        controls: controls,
      );
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, video: true, connectedAt: t0),
          video: const NoPictures(),
        ),
        controls: controls,
      );
      await tester.pump();

      await tester.tap(find.text('Keep it'));
      await tester.pump();

      expect(controls.actions, ['setCameraEnabled(true)']);
      expect(find.textContaining('turned on video'), findsNothing);
    });

    testWidgets('an upgrade this side asked for is not announced back at it', (
      tester,
    ) async {
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(callSession(state: CallState.connected, connectedAt: t0)),
        controls: controls,
      );

      await tester.tap(find.byTooltip('Add video'));
      await tester.pump();

      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, video: true, connectedAt: t0),
          video: const NoPictures(),
        ),
        controls: controls,
      );
      await tester.pump();

      expect(find.textContaining('turned on video'), findsNothing);
    });

    testWidgets('dropping back to audio clears the question', (tester) async {
      final controls = RecordingControls();
      await pumpCallScreen(
        tester,
        serviceState(callSession(state: CallState.connected, connectedAt: t0)),
        controls: controls,
      );
      await pumpCallScreen(
        tester,
        serviceState(
          callSession(state: CallState.connected, video: true, connectedAt: t0),
          video: const NoPictures(),
        ),
        controls: controls,
      );
      await tester.pump();
      expect(find.textContaining('turned on video'), findsOneWidget);

      // The far end turned video off again before anyone answered. There is
      // nothing left to ask about.
      await pumpCallScreen(
        tester,
        serviceState(callSession(state: CallState.connected, connectedAt: t0)),
        controls: controls,
      );
      await tester.pump();

      expect(find.textContaining('turned on video'), findsNothing);
    });
  });

  group('the minimised bar', () {
    testWidgets('names the call, returns to it, and can end it', (
      tester,
    ) async {
      final controls = RecordingControls();
      var opened = 0;
      await withCallClock(() async {
        await pumpCallSurface(
          tester,
          Column(
            children: [
              MinimisedCallBar(
                state: serviceState(
                  callSession(
                    state: CallState.connected,
                    connectedAt: t0.subtract(const Duration(seconds: 5)),
                  ),
                ),
                controls: controls,
                onOpen: () => opened++,
              ),
              const Spacer(),
            ],
          ),
        );

        expect(find.text('Anna · 0:05'), findsOneWidget);

        // Labelled rather than tooltipped: the bar is drawn above the
        // navigator, where there is no Overlay for a tooltip to appear in.
        await tester.tap(find.byIcon(Icons.call_end_rounded));
        await tester.pump();
        expect(controls.actions, ['hangUp']);

        await tester.tap(find.textContaining('Anna · '));
        await tester.pump();
        expect(opened, 1);
      });
    });

    testWidgets('a call with no session draws nothing at all', (tester) async {
      await pumpCallSurface(
        tester,
        MinimisedCallBar(
          state: const CallServiceState(),
          controls: RecordingControls(),
          onOpen: () {},
        ),
      );

      expect(find.byIcon(Icons.call_end_rounded), findsNothing);
    });
  });

  group('the overlay decides when a surface appears', () {
    testWidgets('a live call shows the bar until its screen is up', (
      tester,
    ) async {
      await pumpCallOverlay(
        tester,
        call: serviceState(
          callSession(state: CallState.connected, connectedAt: t0),
        ),
      );
      expect(find.byType(MinimisedCallBar), findsOneWidget);

      // What the call screen does when it opens. The bar is how the user gets
      // back to a call they navigated away from, so it must not also sit on top
      // of the call itself.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CallOverlay)),
      );
      container.read(callScreenVisibleProvider.notifier).set(true);
      await tester.pump();

      expect(find.byType(MinimisedCallBar), findsNothing);
    });

    testWidgets('an idle app is untouched by the overlay', (tester) async {
      await pumpCallOverlay(tester);

      expect(find.byType(MinimisedCallBar), findsNothing);
      expect(find.text('the app'), findsOneWidget);
    });

    testWidgets('an ended call takes the bar down with it', (tester) async {
      await pumpCallOverlay(
        tester,
        call: serviceState(
          callSession(
            state: CallState.ended,
            endReason: CallEndReason.remoteHangup,
          ),
        ),
      );

      expect(find.byType(MinimisedCallBar), findsNothing);
    });
  });

  group('the sentences, on their own', () {
    test('each call state has its own', () {
      expect(
        callStatusLabel(
          serviceState(callSession(state: CallState.outgoingRinging)),
          now: t0,
        ),
        'Calling…',
      );
      expect(
        callStatusLabel(
          serviceState(callSession(state: CallState.connecting)),
          now: t0,
        ),
        'Connecting…',
      );
      expect(
        callStatusLabel(serviceState(ringingSession()), now: t0),
        'Incoming call',
      );
      expect(
        callStatusLabel(serviceState(ringingSession(video: true)), now: t0),
        'Incoming video call',
      );
      expect(
        callStatusLabel(
          serviceState(callSession(state: CallState.ending)),
          now: t0,
        ),
        'Ending…',
      );
      expect(callStatusLabel(const CallServiceState(), now: t0), 'Call ended');
    });

    test(
      'a connected call counts from when media flowed, not from the ring',
      () {
        expect(
          callStatusLabel(
            serviceState(
              callSession(
                state: CallState.connected,
                connectedAt: t0.subtract(const Duration(seconds: 65)),
              ),
            ),
            now: t0,
          ),
          '1:05',
        );
        // `connectedAt` is null while connecting, and a `0:00` there would be a
        // timer counting the ringing.
        expect(
          callStatusLabel(
            serviceState(callSession(state: CallState.connecting)),
            now: t0,
          ),
          'Connecting…',
        );
      },
    );

    test('the wire cannot tell these apart and the screen must', () {
      // Every one of these is `user_hangup` or a reject on the wire. The
      // sentences are the only place the difference survives.
      expect(
        callEndLabel(CallEndReason.remoteReject, isOutgoing: true),
        'They declined',
      );
      expect(
        callEndLabel(CallEndReason.remoteReject, isOutgoing: false),
        'Call declined',
      );
      expect(
        callEndLabel(CallEndReason.inviteTimeout, isOutgoing: true),
        'No answer',
      );
      expect(
        callEndLabel(CallEndReason.inviteTimeout, isOutgoing: false),
        'Missed call',
      );
      expect(
        callEndLabel(CallEndReason.userBusy, isOutgoing: true),
        'They are on another call',
      );
      expect(
        callEndLabel(CallEndReason.answeredElsewhere, isOutgoing: false),
        'Answered on another device',
      );
      expect(
        callEndLabel(CallEndReason.iceFailed, isOutgoing: true),
        'Could not connect',
      );
      expect(
        callEndLabel(CallEndReason.mediaFailed, isOutgoing: true),
        'Microphone or camera unavailable',
      );
      expect(
        callEndLabel(CallEndReason.glareLost, isOutgoing: true),
        'Your calls crossed',
      );
      expect(callEndLabel(null, isOutgoing: true), 'Call ended');
    });

    test('durations read as a phone shows them', () {
      expect(formatCallDuration(const Duration(seconds: 7)), '0:07');
      expect(
        formatCallDuration(const Duration(minutes: 12, seconds: 30)),
        '12:30',
      );
      expect(
        formatCallDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
      // A clock skew between the two devices must not show a negative call.
      expect(formatCallDuration(const Duration(seconds: -3)), '0:00');
      expect(formatCallDuration(null), isNull);
    });

    test('a call that could not be placed says which failure it was', () {
      expect(
        callStartFailureLabel(CallStartFailure.busy),
        'You are already on a call.',
      );
      expect(
        callStartFailureLabel(CallStartFailure.mediaUnavailable),
        contains('microphone'),
      );
      expect(
        callStartFailureLabel(CallStartFailure.signallingFailed),
        contains('could not be sent'),
      );
    });

    test('every audio route has a name a person would use', () {
      expect(callAudioRouteLabel(CallAudioRoute.earpiece), 'Receiver');
      expect(callAudioRouteLabel(CallAudioRoute.speaker), 'Speaker');
      expect(callAudioRouteLabel(CallAudioRoute.wiredHeadset), 'Headphones');
      expect(callAudioRouteLabel(CallAudioRoute.bluetooth), 'Bluetooth');
    });
  });
}
