import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:weft/app/call_providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/call/call_controls.dart';
import 'package:weft/features/call/call_overlay.dart';
import 'package:weft/features/call/call_screen.dart';
import 'package:weft/services/call/call_audio.dart';
import 'package:weft/services/call/call_service.dart';
import 'package:weft/services/call/call_video.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft/app/localisation.dart';

/// Everything the four app-level call suites share.
///
/// The same idea as `packages/weft_call/test/support/fixtures.dart`, one layer
/// up: a call has three collaborators that all need a device — a homeserver, a
/// peer connection and an audio session — and every one of them is replaced
/// here by a recorder. What is left is the layer actually under test.
///
/// [CallHarness] is the important part. It holds the service *and* the clock the
/// service reads, so the three deadlines a call carries (thirty seconds of ICE,
/// twenty of reconnection grace, fifteen of renegotiation) are asserted in a
/// microsecond rather than waited out.

// ---------------------------------------------------------------------------
// Values.
// ---------------------------------------------------------------------------

/// The instant every call in these suites starts from.
///
/// Pinned rather than read from the wall clock because an invite expires
/// relative to when it was *sent*, and a suite whose result depended on how long
/// the runner took to get here would be worse than no suite.
final DateTime t0 = DateTime.utc(2026, 8, 19, 12);

/// Runs [body] with the clock the call surfaces read pinned to [t0].
///
/// The call screen and the minimised bar both call `clock.now()` on every build
/// to redraw the duration, and a widget test's fake async does not fake
/// `DateTime.now()`. Without this an assertion on `1:05` is a race with the
/// second hand: the real elapsed millisecond between building the fixture and
/// painting it floors the duration to `1:04` about as often as not.
Future<void> withCallClock(Future<void> Function() body) =>
    withClock(Clock.fixed(t0), body);

const String localUserId = '@me:example.org';
const String localParty = 'DEVICE';
const String peerParty = 'THEIRS';

const String room = '!room:example.org';
const String otherRoom = '!elsewhere:example.org';

const CallPeer annaPeer = CallPeer(
  matrixUserId: '@anna:example.org',
  displayName: 'Anna',
);

/// Anna as the inbox knows her: one person, three networks, and only the Matrix
/// leg able to carry a call.
const CallPeer mergedAnnaPeer = CallPeer(
  matrixUserId: '@anna:example.org',
  displayName: 'Anna',
  networks: [ChatNetwork.matrix, ChatNetwork.whatsapp, ChatNetwork.signal],
);

/// Audio only. Parsed by `codecSummaryFromSdp`, so these are real enough to
/// name a codec rather than opaque strings.
const String offerSdp = '''
v=0
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=rtpmap:111 opus/48000/2
''';

/// Audio and video, which is also what makes the codec summary two-sided.
const String answerSdp = '''
v=0
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=rtpmap:111 opus/48000/2
m=video 9 UDP/TLS/RTP/SAVPF 96
a=rtpmap:96 VP8/90000
''';

/// A renegotiation's descriptions, kept distinct from the originals so an
/// assertion can tell which exchange a description belonged to.
const String reofferSdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n(reoffer)';
const String reanswerSdp =
    'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n(reanswer)';

IceCandidate ice(String name, {String mid = '0', int index = 0}) =>
    IceCandidate(
      candidate: 'candidate:$name',
      sdpMid: mid,
      sdpMLineIndex: index,
    );

const IceConfiguration turnAvailable = IceConfiguration(
  availability: TurnAvailability.available,
  servers: [
    {
      'urls': ['turn:relay.example.org'],
      'username': 'u',
      'credential': 'p',
    },
  ],
);

/// What a self-hosted Synapse with no `turn_uris` answers, and the sentence the
/// SDK swallows.
const String kNoRelayWarning =
    'Your homeserver provides no call relay. Calls may only work on the same '
    'network.';

const IceConfiguration turnMissing = IceConfiguration(
  availability: TurnAvailability.notConfigured,
  warning: kNoRelayWarning,
);

/// One call, in whatever state a scene needs it in.
CallSession callSession({
  required CallState state,
  CallDirection direction = CallDirection.outgoing,
  CallPeer peer = annaPeer,
  String callId = 'call-1',
  bool video = false,
  bool muted = false,
  bool cameraOn = true,
  bool speakerOn = false,
  DateTime? connectedAt,
  CodecSummary? codecs,
  CallEndReason? endReason,
}) => CallSession(
  callId: callId,
  partyId: localParty,
  roomId: room,
  peer: peer,
  direction: direction,
  state: state,
  startedAt: t0,
  videoEnabled: video,
  muted: muted,
  cameraOn: cameraOn,
  speakerOn: speakerOn,
  connectedAt: connectedAt,
  codecs: codecs,
  endReason: endReason,
);

/// A ringing incoming call, which is the one every incoming-call scene starts
/// from.
CallSession ringingSession({CallPeer peer = annaPeer, bool video = false}) =>
    callSession(
      state: CallState.ringing,
      direction: CallDirection.incoming,
      peer: peer,
      video: video,
    );

CallServiceState serviceState(
  CallSession? session, {
  CallVideoSource? video,
  CallAudioState audio = const CallAudioState(),
  IceConfiguration? ice,
  bool reconnecting = false,
}) => CallServiceState(
  session: session,
  video: video,
  audio: audio,
  ice: ice,
  reconnecting: reconnecting,
);

// ---------------------------------------------------------------------------
// The service, and everything around it.
// ---------------------------------------------------------------------------

/// A [CallService] with a recorder in place of each of its three collaborators,
/// and the clock it reads.
class CallHarness {
  CallHarness({
    IceConfiguration ice = turnAvailable,
    List<String> callIds = const ['call-1', 'call-2', 'call-3'],
    Duration iceTimeout = const Duration(seconds: 30),
    Duration reconnectGrace = const Duration(seconds: 20),
    Duration negotiationTimeout = const Duration(seconds: 15),
  }) : _callIds = List.of(callIds) {
    service = CallService(
      signalling: MatrixCallSignalling(
        localUserId: localUserId,
        localPartyId: localParty,
        sink: sink,
      ),
      iceConfiguration: () async => ice,
      createEngine: (_) async {
        engineBuilds++;
        return engine;
      },
      signals: signals.stream,
      audio: audio,
      ticks: ticks.stream,
      clock: () => now,
      generateCallId: _nextCallId,
      iceTimeout: iceTimeout,
      reconnectGrace: reconnectGrace,
      negotiationTimeout: negotiationTimeout,
    );
  }

  DateTime now = t0;

  final RecordingSink sink = RecordingSink();
  final FakeMediaEngine engine = FakeMediaEngine();
  final RecordingAudio audio = RecordingAudio();
  final StreamController<CallSignal> signals =
      StreamController<CallSignal>.broadcast();
  final StreamController<void> ticks = StreamController<void>.broadcast();

  final List<String> _callIds;

  /// How many times an engine was asked for. A peer connection is not reusable,
  /// so a second call must build a second one.
  int engineBuilds = 0;

  late final CallService service;

  String _nextCallId() =>
      _callIds.length > 1 ? _callIds.removeAt(0) : _callIds.first;

  CallServiceState get state => service.state;

  CallSession? get session => service.state.session;

  void signal(CallSignal signal) => signals.add(signal);

  /// An invite from the far end, sent just now so it has not expired.
  CallInviteSignal invite({
    String callId = 'call-in',
    String roomId = room,
    bool video = false,
    DateTime? sentAt,
    Duration lifetime = kDefaultInviteLifetime,
  }) => CallInviteSignal(
    callId: callId,
    partyId: peerParty,
    senderId: annaPeer.matrixUserId,
    roomId: roomId,
    offer: SessionDescription.offer(video ? answerSdp : offerSdp),
    sentAt: sentAt ?? now,
    lifetime: lifetime,
    video: video,
  );

  CallAnswerSignal answer({String callId = 'call-1', bool video = false}) =>
      CallAnswerSignal(
        callId: callId,
        partyId: peerParty,
        senderId: annaPeer.matrixUserId,
        answer: const SessionDescription.answer(answerSdp),
        video: video,
      );

  CallCandidatesSignal candidates(
    List<IceCandidate> candidates, {
    String callId = 'call-1',
  }) => CallCandidatesSignal(
    callId: callId,
    partyId: peerParty,
    senderId: annaPeer.matrixUserId,
    candidates: candidates,
  );

  void advance(Duration by) => now = now.add(by);

  Future<void> tick() async {
    ticks.add(null);
    await pumpEventQueue();
  }

  /// Places a call and takes it all the way to media flowing, which is where
  /// most of the mid-call assertions start.
  Future<void> connect({bool video = false}) async {
    await service.placeCall(roomId: room, peer: annaPeer, video: video);
    await pumpEventQueue();
    signal(answer(video: video));
    await pumpEventQueue();
    engine.codecs = CodecSummary(audio: 'opus', video: video ? 'VP8' : null);
    engine.states.add(MediaConnectionState.connected);
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    await service.dispose();
    await signals.close();
    await ticks.close();
    await engine.close();
    await audio.close();
  }
}

/// Tears a harness down from inside a widget test, without awaiting it.
///
/// A `testWidgets` body runs in a `FakeAsync` zone, so every future the service
/// creates is driven by `tester.pump` and by nothing else. A `tearDown` that
/// awaited [CallHarness.dispose] would therefore wait forever for a microtask
/// queue that has stopped being flushed — the test passes and the runner hangs.
/// Everything being closed is in-process, so dropping the future costs nothing.
void disposeAfterWidgetTest(CallHarness harness) =>
    unawaited(harness.dispose());

/// One event as it reached the wire.
class SentEvent {
  const SentEvent(this.roomId, this.type, this.content);

  final String roomId;
  final String type;
  final Map<String, Object?> content;

  String? get callId => content['call_id'] as String?;

  String? get reason => content['reason'] as String?;

  @override
  String toString() => '$type($callId) → $roomId';
}

/// The homeserver, reduced to a list.
class RecordingSink implements MatrixCallEventSink {
  final List<SentEvent> sent = [];

  /// Event types that fail to send, and what they fail with. An invite that
  /// never left is a call that cannot happen; a candidate that failed is not.
  final Map<String, CallSignallingException> failures = {};

  List<String> get types => [for (final event in sent) event.type];

  Iterable<SentEvent> ofType(String type) =>
      sent.where((event) => event.type == type);

  SentEvent? get last => sent.isEmpty ? null : sent.last;

  @override
  Future<void> send({
    required String roomId,
    required String type,
    required Map<String, Object?> content,
  }) async {
    final failure = failures[type];
    if (failure != null) throw failure;
    sent.add(SentEvent(roomId, type, content));
  }
}

/// The peer connection, reduced to a list of the calls made on it.
class FakeMediaEngine implements MediaEngine {
  final List<String> calls = [];
  final StreamController<IceCandidate> candidates =
      StreamController<IceCandidate>.broadcast();
  final StreamController<MediaConnectionState> states =
      StreamController<MediaConnectionState>.broadcast();

  bool disposed = false;
  CodecSummary? codecs;

  /// Thrown by the next description-producing call. The microphone being held
  /// by another app, or a permission the user has just refused.
  Object? descriptionError;

  /// Thrown by [addCandidate]. One malformed candidate is not a call.
  Object? candidateError;

  /// Thrown by [dispose], to prove teardown cannot strand a call screen.
  Object? disposeError;

  /// Every remote candidate that was actually applied, in order.
  final List<String> applied = [];

  @override
  CodecSummary? get negotiatedCodecs => codecs;

  @override
  Stream<IceCandidate> get localCandidates => candidates.stream;

  @override
  Stream<MediaConnectionState> get connectionState => states.stream;

  @override
  Future<SessionDescription> createOffer({required bool video}) async {
    calls.add('createOffer(video: $video)');
    final error = descriptionError;
    if (error != null) throw error;
    return SessionDescription.offer(video ? answerSdp : offerSdp);
  }

  @override
  Future<SessionDescription> createAnswer(
    SessionDescription remoteOffer, {
    required bool video,
  }) async {
    calls.add('createAnswer(video: $video)');
    final error = descriptionError;
    if (error != null) throw error;
    return const SessionDescription.answer(answerSdp);
  }

  @override
  Future<void> applyRemoteDescription(SessionDescription description) async {
    calls.add('applyRemoteDescription(${description.type.wireType})');
  }

  @override
  Future<void> addCandidate(IceCandidate candidate) async {
    calls.add('addCandidate(${candidate.candidate})');
    final error = candidateError;
    if (error != null) throw error;
    applied.add(candidate.candidate);
  }

  @override
  Future<void> setMute(bool muted) async => calls.add('setMute($muted)');

  @override
  Future<void> setVideo(bool enabled) async => calls.add('setVideo($enabled)');

  @override
  Future<void> switchCamera() async => calls.add('switchCamera()');

  @override
  Future<void> dispose() async {
    disposed = true;
    calls.add('dispose()');
    final error = disposeError;
    if (error != null) throw error;
  }

  Future<void> close() async {
    await candidates.close();
    await states.close();
  }
}

/// The audio session, reduced to what it was told to do.
class RecordingAudio implements CallAudioController {
  final List<CallAudioRoute> applied = [];
  final StreamController<Set<CallAudioRoute>> routes =
      StreamController<Set<CallAudioRoute>>.broadcast();

  Set<CallAudioRoute> offered = const {
    CallAudioRoute.earpiece,
    CallAudioRoute.speaker,
  };
  bool proximity = false;
  bool stopped = false;

  @override
  Stream<Set<CallAudioRoute>> get available => routes.stream;

  @override
  Future<Set<CallAudioRoute>> refresh() async => offered;

  @override
  Future<void> apply(CallAudioRoute route) async => applied.add(route);

  @override
  Future<void> setProximityEnabled({required bool enabled}) async {
    proximity = enabled;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    proximity = false;
  }

  @override
  Future<void> dispose() async {}

  Future<void> close() async => routes.close();
}

// ---------------------------------------------------------------------------
// The UI's seams.
// ---------------------------------------------------------------------------

/// [CallControls] as a list of what was pressed.
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

/// The demo repository with one Matrix-native DM in front of it.
///
/// The demo fixtures are deliberately all bridged — they exist to show the merge
/// feature — so the callable case needs a conversation of its own, with a handle
/// in the identity graph for the peer to be resolved from.
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

  /// A Matrix DM and a group with a Matrix leg, so the two callable-looking
  /// conversations that resolve differently are both reachable by id.
  static const String groupChatId = '!plans:example.org';

  @override
  Stream<List<Chat>> watchChats() => Stream.value([
    Chat(
      id: chatId,
      title: 'Anna',
      contactId: identityGraph.contactIdOf('@anna:example.org'),
      sources: const [ChatSource(roomId: chatId, network: ChatNetwork.matrix)],
    ),
    Chat(
      id: groupChatId,
      title: 'Weekend plans',
      isGroup: true,
      sources: const [
        ChatSource(roomId: groupChatId, network: ChatNetwork.matrix),
      ],
    ),
  ]);
}

// ---------------------------------------------------------------------------
// Pumps.
// ---------------------------------------------------------------------------

/// One call surface, themed, with nothing behind it.
Future<void> pumpCallSurface(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: weftLocalizationsDelegates,
        theme: WeftTheme.build(),
        home: Scaffold(body: child),
      ),
    ),
  );
}

/// The call screen as a pure function of a state and a set of controls.
Future<void> pumpCallScreen(
  WidgetTester tester,
  CallServiceState state, {
  CallControls? controls,
  VoidCallback? onClose,
}) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: weftLocalizationsDelegates,
        theme: WeftTheme.build(),
        home: CallScreenBody(
          state: state,
          controls: controls ?? RecordingControls(),
          onClose: onClose,
        ),
      ),
    ),
  );
}

/// The overlay over a stand-in app, with one call state behind it.
///
/// [service] wires the real thing when a test wants a button press to reach the
/// wire; without it the state is fed directly and [callControlsProvider] falls
/// back to [InertCallControls].
Future<void> pumpCallOverlay(
  WidgetTester tester, {
  CallServiceState? call,
  CallService? service,
  Size size = const Size(420, 900),
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        callServiceProvider.overrideWithValue(service),
        if (service == null)
          activeCallProvider.overrideWith(
            (ref) => Stream.value(call ?? const CallServiceState()),
          ),
      ],
      child: MaterialApp(
        localizationsDelegates: weftLocalizationsDelegates,
        theme: WeftTheme.build(),
        builder: (context, child) =>
            CallOverlay(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: Center(child: Text('the app'))),
      ),
    ),
  );
  await tester.pump();
}

/// Whether the round control carrying [tooltip] can be pressed.
bool actionEnabled(WidgetTester tester, String tooltip) {
  final button = tester.widget<CallActionButton>(
    find.ancestor(
      of: find.byTooltip(tooltip),
      matching: find.byType(CallActionButton),
    ),
  );
  return button.onPressed != null;
}
