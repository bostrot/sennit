import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:weft/app/call_providers.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/call/call_controls.dart';
import 'package:weft/features/call/call_labels.dart';
import 'package:weft/features/call/call_overlay.dart';
import 'package:weft/features/call/call_screen.dart';
import 'package:weft/features/call/incoming_call_sheet.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/services/call/call_audio.dart';
import 'package:weft/services/call/call_service.dart';
import 'package:weft/services/call/call_video.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart'
    show IceConfiguration, TurnAvailability;

/// A deliberately small suite, in the shape the two layers below this one took:
/// it exists so the call UI is not committed unexecuted, and it does **not**
/// pre-empt the phase's next task, whose `call_screen_test.dart`,
/// `incoming_call_test.dart` and `call_availability_test.dart` subsume it.
///
/// What is worth pinning here is the part of a call surface that is not a
/// layout: which control each button drives, which sentence each state
/// produces, and the two rules that are easy to get backwards — that the far
/// end adding video prompts *this* side about *its own* camera, and that a
/// bridged conversation's call button is disabled with the reason on it rather
/// than missing.
void main() {
  group('labels', () {
    test('each call state has its own sentence', () {
      expect(
        callStatusLabel(state(call(state: CallState.outgoingRinging)), now: t0),
        'Calling…',
      );
      expect(
        callStatusLabel(state(call(state: CallState.connecting)), now: t0),
        'Connecting…',
      );
      expect(
        callStatusLabel(
          state(
            call(state: CallState.ringing, direction: CallDirection.incoming),
          ),
          now: t0,
        ),
        'Incoming call',
      );
      expect(
        callStatusLabel(state(call(state: CallState.ending)), now: t0),
        'Ending…',
      );
    });

    test(
      'a connected call counts from when media flowed, not from the ring',
      () {
        final connected = call(
          state: CallState.connected,
          connectedAt: t0.subtract(const Duration(seconds: 65)),
        );
        expect(callStatusLabel(state(connected), now: t0), '1:05');

        // Still connecting: `connectedAt` is null and a `0:00` here would be a
        // timer counting the ringing.
        expect(
          callStatusLabel(state(call(state: CallState.connecting)), now: t0),
          'Connecting…',
        );
      },
    );

    test('a dropped connection outranks the duration', () {
      final connected = call(
        state: CallState.connected,
        connectedAt: t0.subtract(const Duration(seconds: 20)),
      );
      expect(
        callStatusLabel(
          CallServiceState(session: connected, reconnecting: true),
          now: t0,
        ),
        'Reconnecting…',
      );
    });

    test('the wire cannot tell these apart and the screen must', () {
      // Every one of these is `user_hangup` or a reject on the wire. The
      // sentences are the only place the difference survives.
      expect(
        callEndLabel(CallEndReason.remoteReject, isOutgoing: true),
        'They declined',
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
        callEndLabel(CallEndReason.iceFailed, isOutgoing: true),
        'Could not connect',
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
      expect(formatCallDuration(null), isNull);
    });
  });

  group('call screen', () {
    testWidgets('a voice call shows who it is with and what it is doing', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        state(call(state: CallState.outgoingRinging)),
        RecordingControls(),
      );

      expect(find.text('Anna'), findsWidgets);
      expect(find.text('Calling…'), findsOneWidget);
      // Video controls belong to a video call; a voice call offers the upgrade
      // instead, and it is disabled until there is a session to renegotiate.
      expect(find.byTooltip('Add video'), findsOneWidget);
      expect(find.byTooltip('Switch camera'), findsNothing);
      expect(enabled(tester, 'Add video'), isFalse);
    });

    testWidgets('each control drives its own action', (tester) async {
      final controls = RecordingControls();
      await pumpScreen(
        tester,
        state(call(state: CallState.connected, connectedAt: t0)),
        controls,
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

    testWidgets('a video call swaps the upgrade for the camera controls', (
      tester,
    ) async {
      final controls = RecordingControls();
      await pumpScreen(
        tester,
        state(
          call(state: CallState.connected, video: true, connectedAt: t0),
          video: const NoPictures(),
        ),
        controls,
      );

      expect(find.byTooltip('Add video'), findsNothing);
      expect(find.byTooltip('Turn camera off'), findsOneWidget);

      await tester.tap(find.byTooltip('Switch camera'));
      await tester.tap(find.byTooltip('Turn camera off'));
      await tester.pump();

      expect(controls.actions, ['switchCamera', 'setCameraEnabled(false)']);
    });

    testWidgets('the far end adding video asks about this side\'s camera', (
      tester,
    ) async {
      // The gate is on the camera and not on the renegotiation: WebRTC needs a
      // prompt answer, so `weft_call` has already answered and the camera is
      // already on by the time a person can be asked anything.
      final controls = RecordingControls();
      await pumpScreen(
        tester,
        state(call(state: CallState.connected, connectedAt: t0)),
        controls,
      );
      expect(find.textContaining('turned on video'), findsNothing);

      await pumpScreen(
        tester,
        state(
          call(state: CallState.connected, video: true, connectedAt: t0),
          video: const NoPictures(),
        ),
        controls,
      );
      await tester.pump();

      expect(find.text('Anna turned on video'), findsOneWidget);
      await tester.tap(find.text('Turn mine off'));
      await tester.pump();

      expect(controls.actions, ['setCameraEnabled(false)']);
      expect(find.text('Anna turned on video'), findsNothing);
    });

    testWidgets('an upgrade this side asked for is not announced back at it', (
      tester,
    ) async {
      final controls = RecordingControls();
      await pumpScreen(
        tester,
        state(call(state: CallState.connected, connectedAt: t0)),
        controls,
      );

      await tester.tap(find.byTooltip('Add video'));
      await tester.pump();

      await pumpScreen(
        tester,
        state(
          call(state: CallState.connected, video: true, connectedAt: t0),
          video: const NoPictures(),
        ),
        controls,
      );
      await tester.pump();

      expect(find.textContaining('turned on video'), findsNothing);
    });

    testWidgets('a call that ended says why, and its buttons are inert', (
      tester,
    ) async {
      final controls = RecordingControls();
      await pumpScreen(
        tester,
        state(
          call(state: CallState.ended, endReason: CallEndReason.remoteReject),
        ),
        controls,
      );

      expect(find.text('They declined'), findsOneWidget);
      await tester.tap(find.byTooltip('Hang up'));
      await tester.pump();
      expect(controls.actions, isEmpty);
    });

    testWidgets('a homeserver with no relay says so while connecting', (
      tester,
    ) async {
      const warning = 'Your homeserver provides no call relay.';
      await pumpScreen(
        tester,
        CallServiceState(
          session: call(state: CallState.connecting),
          ice: const IceConfiguration(
            availability: TurnAvailability.notConfigured,
            warning: warning,
          ),
        ),
        RecordingControls(),
      );

      expect(find.text(warning), findsOneWidget);
    });

    testWidgets('more than two audio routes become a menu', (tester) async {
      final controls = RecordingControls();
      await pumpScreen(
        tester,
        CallServiceState(
          session: call(state: CallState.connected, connectedAt: t0),
          audio: const CallAudioState(
            route: CallAudioRoute.bluetooth,
            available: {
              CallAudioRoute.earpiece,
              CallAudioRoute.speaker,
              CallAudioRoute.bluetooth,
            },
          ),
        ),
        controls,
      );

      await tester.tap(find.byType(PopupMenuButton<CallAudioRoute>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speaker').last);
      await tester.pumpAndSettle();

      expect(controls.actions, ['setAudioRoute(speaker)']);
    });
  });

  group('incoming call', () {
    testWidgets('accept and decline reach the service', (tester) async {
      final controls = RecordingControls();
      await pumpSurface(
        tester,
        IncomingCallSheet(
          session: call(
            state: CallState.ringing,
            direction: CallDirection.incoming,
          ),
          controls: controls,
        ),
      );

      expect(find.text('Incoming call'), findsOneWidget);
      expect(find.byTooltip('Voice only'), findsNothing);

      await tester.tap(find.byTooltip('Decline'));
      await tester.tap(find.byTooltip('Accept'));
      await tester.pump();

      expect(controls.actions, ['decline', 'accept(null)']);
    });

    testWidgets('a video call can be answered on audio', (tester) async {
      final controls = RecordingControls();
      await pumpSurface(
        tester,
        IncomingCallSheet(
          session: call(
            state: CallState.ringing,
            direction: CallDirection.incoming,
            video: true,
          ),
          controls: controls,
        ),
      );

      expect(find.text('Incoming video call'), findsOneWidget);
      await tester.tap(find.byTooltip('Voice only'));
      await tester.pump();

      expect(controls.actions, ['accept(false)']);
    });

    testWidgets('the caller is named by the merged identity', (tester) async {
      // The peer carries the contact's display name and every network it spans,
      // so the call says what the inbox row said rather than `@anna:…`.
      await pumpSurface(
        tester,
        IncomingCallSheet(
          session: call(
            state: CallState.ringing,
            direction: CallDirection.incoming,
          ),
          controls: RecordingControls(),
        ),
      );

      expect(find.text('Anna'), findsOneWidget);
      expect(find.text('@anna:example.org'), findsNothing);
    });

    testWidgets('the heads-up variant carries the same two actions', (
      tester,
    ) async {
      final controls = RecordingControls();
      await pumpSurface(
        tester,
        Align(
          alignment: Alignment.topCenter,
          child: IncomingCallBanner(
            session: call(
              state: CallState.ringing,
              direction: CallDirection.incoming,
            ),
            controls: controls,
          ),
        ),
      );

      await tester.tap(find.byTooltip('Accept'));
      await tester.pump();
      expect(controls.actions, ['accept(null)']);
    });
  });

  group('minimised bar', () {
    testWidgets('shows the call, returns to it, and can end it', (
      tester,
    ) async {
      final controls = RecordingControls();
      var opened = 0;
      await pumpSurface(
        tester,
        Column(
          children: [
            MinimisedCallBar(
              state: state(
                call(
                  state: CallState.connected,
                  connectedAt: DateTime.now().subtract(
                    const Duration(seconds: 5),
                  ),
                ),
              ),
              controls: controls,
              onOpen: () => opened++,
            ),
            const Spacer(),
          ],
        ),
      );

      expect(find.textContaining('Anna · '), findsOneWidget);

      await tester.tap(find.byIcon(Icons.call_end_rounded));
      await tester.pump();
      expect(controls.actions, ['hangUp']);

      await tester.tap(find.textContaining('Anna · '));
      await tester.pump();
      expect(opened, 1);
    });
  });

  group('overlay', () {
    testWidgets('a ringing call takes a narrow window', (tester) async {
      await pumpOverlay(
        tester,
        state(
          call(state: CallState.ringing, direction: CallDirection.incoming),
        ),
        size: const Size(420, 900),
      );

      expect(find.byType(IncomingCallSheet), findsOneWidget);
      expect(find.byType(IncomingCallBanner), findsNothing);
      // The bar is for a call in progress; a ringing one is already on screen.
      expect(find.byType(MinimisedCallBar), findsNothing);
    });

    testWidgets('a wide window gets the heads-up card instead', (tester) async {
      await pumpOverlay(
        tester,
        state(
          call(state: CallState.ringing, direction: CallDirection.incoming),
        ),
        size: const Size(1200, 900),
      );

      expect(find.byType(IncomingCallBanner), findsOneWidget);
      expect(find.byType(IncomingCallSheet), findsNothing);
    });

    testWidgets('a live call shows the bar until its screen is up', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        state(call(state: CallState.connected, connectedAt: t0)),
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
      await pumpOverlay(tester, const CallServiceState());

      expect(find.byType(MinimisedCallBar), findsNothing);
      expect(find.byType(IncomingCallSheet), findsNothing);
      expect(find.text('the app'), findsOneWidget);
    });
  });

  group('the call button in a conversation', () {
    testWidgets('is disabled with a reason for a bridged conversation', (
      tester,
    ) async {
      // Anna is reachable on WhatsApp, Signal and Telegram — three rooms on the
      // user's own homeserver, none of them Matrix-native, and a bridge ghost on
      // the far end of each that will never answer an `m.call.invite`.
      await pumpChat(tester);

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.call_rounded),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(button.tooltip, contains("can't carry calls"));
      expect(button.tooltip, contains('WhatsApp'));
    });

    testWidgets(
      'is enabled for a Matrix-native one and reports why it cannot dial',
      (tester) async {
        await pumpChat(
          tester,
          availability: const CallReady(
            CallTarget(roomId: '!anna:example.org', peer: annaPeer),
          ),
        );

        final finder = find.ancestor(
          of: find.byIcon(Icons.call_rounded),
          matching: find.byType(IconButton),
        );
        expect(tester.widget<IconButton>(finder).onPressed, isNotNull);
        expect(tester.widget<IconButton>(finder).tooltip, 'Call Anna');

        // No signed-in account behind it in a test, which is the one failure the
        // button itself has to explain rather than swallow.
        await tester.tap(finder);
        await tester.pump();
        expect(
          find.text('Calling needs a signed-in Matrix account.'),
          findsOneWidget,
        );
      },
    );
  });

  group('availability, as the app resolves it', () {
    test('a Matrix DM resolves a target through the identity graph', () async {
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(MatrixNativeRepository()),
        ],
      );
      addTearDown(container.dispose);

      // The inbox is a stream, so before its first value every conversation is
      // "still loading" rather than callable — which is the honest answer for
      // the frame before a chat exists, and is why this is awaited.
      // Held open while it is awaited: providers are auto-disposing, and an
      // inbox nobody is listening to is torn down before its first value.
      container.listen(chatsProvider, (_, _) {});
      await container.read(chatsProvider.future);

      final availability = container.read(
        callAvailabilityProvider(MatrixNativeRepository.chatId),
      );
      expect(availability.isAvailable, isTrue);
      expect(availability.target?.roomId, MatrixNativeRepository.chatId);
      expect(availability.target?.peer.matrixUserId, '@anna:example.org');
    });

    test(
      'a bridged conversation is blocked, with its networks named',
      () async {
        final container = ProviderContainer(
          overrides: [
            chatRepositoryProvider.overrideWithValue(DemoChatRepository()),
          ],
        );
        addTearDown(container.dispose);
        // Held open while it is awaited: providers are auto-disposing, and an
        // inbox nobody is listening to is torn down before its first value.
        container.listen(chatsProvider, (_, _) {});
        await container.read(chatsProvider.future);

        final availability = container.read(
          callAvailabilityProvider('merged:anna'),
        );
        expect(availability.isAvailable, isFalse);
        expect(availability.message, contains('WhatsApp'));
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

final DateTime t0 = DateTime.utc(2026, 8, 19, 12);

const CallPeer annaPeer = CallPeer(
  matrixUserId: '@anna:example.org',
  displayName: 'Anna',
);

CallSession call({
  required CallState state,
  CallDirection direction = CallDirection.outgoing,
  bool video = false,
  bool muted = false,
  bool cameraOn = true,
  DateTime? connectedAt,
  CallEndReason? endReason,
}) => CallSession(
  callId: 'call-1',
  partyId: 'DEVICE',
  roomId: '!room:example.org',
  peer: annaPeer,
  direction: direction,
  state: state,
  startedAt: t0,
  videoEnabled: video,
  muted: muted,
  cameraOn: cameraOn,
  connectedAt: connectedAt,
  endReason: endReason,
);

CallServiceState state(CallSession session, {CallVideoSource? video}) =>
    CallServiceState(session: session, video: video);

/// A video source with no pictures in it — which is what a widget test has, and
/// also what a real video call has for its first second.
class NoPictures implements CallVideoSource {
  const NoPictures();

  @override
  MediaStream? get localStream => null;

  @override
  MediaStream? get remoteStream => null;

  @override
  Stream<MediaStream?> get remoteStreams => const Stream.empty();
}

class RecordingControls implements CallControls {
  final List<String> actions = [];

  @override
  Future<void> accept({bool? video}) async => actions.add('accept($video)');

  @override
  Future<void> decline() async => actions.add('decline');

  @override
  Future<void> hangUp() async => actions.add('hangUp');

  @override
  Future<void> setMuted({required bool muted}) async =>
      actions.add('setMuted($muted)');

  @override
  Future<void> setAudioRoute(CallAudioRoute route) async =>
      actions.add('setAudioRoute(${route.name})');

  @override
  Future<void> setCameraEnabled({required bool enabled}) async =>
      actions.add('setCameraEnabled($enabled)');

  @override
  Future<void> switchCamera() async => actions.add('switchCamera');

  @override
  Future<void> requestVideo({bool video = true}) async =>
      actions.add('requestVideo($video)');
}

/// The demo repository with one Matrix-native DM in front of it.
///
/// The demo fixtures are deliberately all bridged — they exist to show the
/// merge feature — so the callable case needs a conversation of its own, with a
/// handle in the identity graph for the peer to be resolved from.
class MatrixNativeRepository extends DemoChatRepository {
  MatrixNativeRepository() {
    identityGraph.upsertHandle(
      const NetworkHandle(
        id: '@anna:example.org',
        network: ChatNetwork.matrix,
        remoteId: '@anna:example.org',
        matrixUserId: '@anna:example.org',
        roomId: chatId,
        displayName: 'Anna',
      ),
    );
  }

  static const String chatId = '!anna_matrix:example.org';

  @override
  Stream<List<Chat>> watchChats() => Stream.value([
    Chat(
      id: chatId,
      title: 'Anna',
      contactId: identityGraph.contactIdOf('@anna:example.org'),
      sources: const [ChatSource(roomId: chatId, network: ChatNetwork.matrix)],
    ),
  ]);
}

// ---------------------------------------------------------------------------
// Pumps.
// ---------------------------------------------------------------------------

Future<void> pumpSurface(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: WeftTheme.build(),
        home: Scaffold(body: child),
      ),
    ),
  );
}

Future<void> pumpScreen(
  WidgetTester tester,
  CallServiceState state,
  CallControls controls,
) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: WeftTheme.build(),
        home: CallScreenBody(state: state, controls: controls),
      ),
    ),
  );
}

/// The overlay over a stand-in app, with one call state behind it.
Future<void> pumpOverlay(
  WidgetTester tester,
  CallServiceState call, {
  Size size = const Size(420, 900),
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        callServiceProvider.overrideWithValue(null),
        activeCallProvider.overrideWith((ref) => Stream.value(call)),
      ],
      child: MaterialApp(
        theme: WeftTheme.build(),
        builder: (context, child) =>
            CallOverlay(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: Center(child: Text('the app'))),
      ),
    ),
  );
  await tester.pump();
}

/// The chat view, with no session behind it — which is all the app bar needs.
///
/// [availability] is named rather than passed as an overrides list because
/// Riverpod's `Override` type is not exported from either barrel, so a
/// `List<Override>` parameter cannot be written at all — the same constraint
/// `golden_harness.dart` records.
Future<void> pumpChat(
  WidgetTester tester, {
  CallAvailability? availability,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatRepositoryProvider.overrideWithValue(DemoChatRepository()),
        callServiceProvider.overrideWithValue(null),
        if (availability != null)
          callAvailabilityProvider(
            'merged:anna',
          ).overrideWithValue(availability),
      ],
      child: MaterialApp(
        theme: WeftTheme.build(),
        home: const ChatView(chatId: 'merged:anna'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool enabled(WidgetTester tester, String tooltip) {
  final button = tester.widget<CallActionButton>(
    find.ancestor(
      of: find.byTooltip(tooltip),
      matching: find.byType(CallActionButton),
    ),
  );
  return button.onPressed != null;
}
