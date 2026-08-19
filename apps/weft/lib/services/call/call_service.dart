import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'call_audio.dart';
import 'call_video.dart';

/// Builds the media engine for one call, with the relay configuration the
/// homeserver handed out.
///
/// A factory rather than a long-lived engine because a peer connection is not
/// reusable: WebRTC's own lifecycle ends with the call, and a second call needs
/// fresh ICE credentials anyway.
typedef MediaEngineFactory = Future<MediaEngine> Function(IceConfiguration ice);

/// Reads the current TURN configuration. `MatrixTurnServers.configuration` is
/// the one implementation; a test passes a closure.
typedef IceConfigurationLoader = Future<IceConfiguration> Function();

/// Why a call could not be placed.
///
/// Separate from [CallEndReason] on purpose: these are failures that happen
/// *before* there is a call, so there is nothing to show an end screen for and
/// nothing to tell the far end. They are a sentence next to the button that was
/// just pressed.
enum CallStartFailure {
  /// A call is already in progress. Weft carries one at a time.
  busy,

  /// The microphone or camera could not be opened — permission denied, or
  /// another app holding the device.
  mediaUnavailable,

  /// The invite could not be put on the wire.
  signallingFailed,
}

/// Everything the call UI reads, in one value.
@immutable
class CallServiceState {
  const CallServiceState({
    this.session,
    this.audio = const CallAudioState(),
    this.ice,
    this.video,
    this.reconnecting = false,
  });

  /// The active call, or null when there is none. Survives into
  /// [CallState.ended] so the screen can say who it was with and why it
  /// stopped.
  final CallSession? session;

  final CallAudioState audio;

  /// What the homeserver said about relays, once it has been asked.
  ///
  /// Held rather than reduced to a boolean because [IceConfiguration.warning]
  /// is the sentence the user needs — the Matrix SDK's habit of logging this at
  /// verbose level and returning an empty server list is exactly how a
  /// self-hosted account ends up with calls that work at home and nowhere else,
  /// with nothing on screen to explain it.
  final IceConfiguration? ice;

  /// The engine's pictures, when this call has an engine that has any.
  ///
  /// Null for a call that has not opened media yet, and in any build whose
  /// engine is not a [CallVideoSource] — which is every test that hands the
  /// service a fake. The call screen draws a placeholder for both, because they
  /// look the same to a user: no picture yet.
  final CallVideoSource? video;

  /// The peer connection has dropped and is being given a chance to heal.
  ///
  /// Published because it is the only honest connection-quality signal a 1:1
  /// call has that the user can act on — a call that has gone quiet is either
  /// this, in which case waiting a few seconds is right, or the other person
  /// not talking. WebRTC's own statistics would say more and none of it in the
  /// second it matters.
  final bool reconnecting;

  /// A sentence to show, or null when there is nothing to say.
  String? get warning => ice?.warning;

  bool get isLive => session?.state.isLive ?? false;

  bool get hasCall => session != null;

  CallServiceState copyWith({
    CallSession? session,
    CallAudioState? audio,
    IceConfiguration? ice,
    CallVideoSource? video,
    bool? reconnecting,
  }) => CallServiceState(
    session: session ?? this.session,
    audio: audio ?? this.audio,
    ice: ice ?? this.ice,
    video: video ?? this.video,
    reconnecting: reconnecting ?? this.reconnecting,
  );

  @override
  String toString() =>
      'CallServiceState(${session ?? 'idle'}, ${audio.route}'
      '${reconnecting ? ', reconnecting' : ''})';
}

/// The one place a call's decisions meet its plumbing.
///
/// [CallStateMachine] says what should happen; this carries it out against
/// three collaborators and feeds the results back:
///
/// - [MatrixCallSignalling] for the wire,
/// - [MediaEngine] for the microphone, camera and peer connection,
/// - [CallAudioController] for where the sound comes out.
///
/// Every input goes through one serialised queue. A call is the one part of a
/// messenger where two events genuinely race — an answer arriving down `/sync`
/// while the user is pressing decline — and interleaving two transitions would
/// let intents from the first be executed against the state of the second.
///
/// Three things the machine deliberately leaves open are closed here, because
/// they need a clock and it does not have one (`weft_call`'s test suite says as
/// much):
///
///  * **An ICE timeout.** Nothing in the machine ends a call stuck in
///    [CallState.connecting]. Without this a call with no relay rings, connects
///    nothing, and sits there.
///  * **A reconnection grace period.** A peer connection that goes
///    `disconnected` usually heals — a phone changing network does it every
///    time — so it is given [reconnectGrace] before it counts as failed.
///  * **A renegotiation timeout.** A far end that never answers an
///    `m.call.negotiate` would otherwise leave the machine's negotiation latched
///    and every later upgrade a silent no-op.
class CallService {
  CallService({
    required MatrixCallSignalling signalling,
    required IceConfigurationLoader iceConfiguration,
    required MediaEngineFactory createEngine,
    required Stream<CallSignal> signals,
    CallAudioController? audio,
    DateTime Function()? clock,
    String Function()? generateCallId,
    Stream<void>? ticks,
    Duration tickInterval = const Duration(seconds: 1),
    this.iceTimeout = const Duration(seconds: 30),
    this.reconnectGrace = const Duration(seconds: 20),
    this.negotiationTimeout = const Duration(seconds: 15),
  }) : _signalling = signalling,
       _iceConfiguration = iceConfiguration,
       _createEngine = createEngine,
       _audio = audio,
       _clock = clock ?? DateTime.now,
       _generateCallId = generateCallId ?? _randomCallId,
       _machine = CallStateMachine(
         localUserId: signalling.localUserId,
         localPartyId: signalling.localPartyId,
         clock: clock ?? DateTime.now,
       ) {
    _signals = signals.listen(_onSignal);
    _ticks = (ticks ?? Stream<void>.periodic(tickInterval)).listen(_onTick);
    _routes = _audio?.available.listen(_onRoutesChanged);
    unawaited(_refreshRoutes());
  }

  /// How long a call may sit in [CallState.connecting] before ICE counts as
  /// failed. Long enough for a slow relay handshake, short enough that a call
  /// that will never connect says so while the user is still looking at it.
  final Duration iceTimeout;

  /// How long a `disconnected` peer connection is given to heal.
  final Duration reconnectGrace;

  /// How long a renegotiation may go unanswered.
  final Duration negotiationTimeout;

  final MatrixCallSignalling _signalling;
  final IceConfigurationLoader _iceConfiguration;
  final MediaEngineFactory _createEngine;
  final CallAudioController? _audio;
  final DateTime Function() _clock;
  final String Function() _generateCallId;
  final CallStateMachine _machine;

  final StreamController<CallServiceState> _states =
      StreamController<CallServiceState>.broadcast();

  StreamSubscription<CallSignal>? _signals;
  StreamSubscription<void>? _ticks;
  StreamSubscription<Set<CallAudioRoute>>? _routes;
  StreamSubscription<IceCandidate>? _engineCandidates;
  StreamSubscription<MediaConnectionState>? _engineStates;

  MediaEngine? _engine;
  IceConfiguration? _ice;
  CallServiceState _state = const CallServiceState();

  /// Where an invite for a call id arrived, so a reject can be addressed.
  ///
  /// Not derivable from the session: the invite Weft rejects with `user_busy`
  /// belongs to a *different* room from the call already in progress, and
  /// sending its reject to the active call's room would leave the second caller
  /// ringing until their invite expired.
  final Map<String, String> _roomForCall = {};

  Set<CallAudioRoute> _availableRoutes = const {
    CallAudioRoute.earpiece,
    CallAudioRoute.speaker,
  };
  CallAudioRoute? _preferredRoute;

  DateTime? _iceDeadline;
  DateTime? _reconnectDeadline;
  DateTime? _negotiationDeadline;

  CallStartFailure? _startFailure;
  Future<void> _queue = Future<void>.value();

  /// Whether a call currently owns the audio session, so it is released once
  /// and not on every idle tick.
  bool _audioHeld = false;
  bool _disposed = false;

  /// The current call and everything around it.
  CallServiceState get state => _state;

  /// Changes to [state]. Broadcast, because the call screen, the minimised call
  /// bar and the chat view all watch it.
  Stream<CallServiceState> get states => _states.stream;

  /// True while a call exists, in any live state.
  bool get hasActiveCall => _machine.state.isLive;

  // -------------------------------------------------------------------------
  // Actions.
  // -------------------------------------------------------------------------

  /// Places a call, returning null on success or why it could not start.
  ///
  /// One call at a time is enforced here *and* in the state machine, and the
  /// two do different jobs: the machine refuses a second **incoming** invite
  /// with `m.call.reject` and `user_busy`, so the far end stops ringing at once;
  /// this refuses a second **outgoing** one with a reason the button that was
  /// pressed can show.
  Future<CallStartFailure?> placeCall({
    required String roomId,
    required CallPeer peer,
    bool video = false,
  }) async {
    if (_machine.state.isLive) return CallStartFailure.busy;

    _startFailure = null;
    _preferredRoute = null;
    final callId = _generateCallId();
    _roomForCall[callId] = roomId;
    await _dispatch(
      PlaceCall(callId: callId, roomId: roomId, peer: peer, video: video),
    );

    if (_machine.state.isLive) return null;
    return _startFailure ?? CallStartFailure.mediaUnavailable;
  }

  /// Answers the ringing call. [video] defaults to whatever the caller offered.
  Future<void> accept({bool? video}) => _dispatch(AcceptCall(video: video));

  /// Declines the ringing call. Sends `m.call.reject`.
  Future<void> decline() => _dispatch(const DeclineCall());

  /// Ends an outgoing or established call. Sends `m.call.hangup`.
  Future<void> hangUp() => _dispatch(const HangUp());

  Future<void> setMuted({required bool muted}) => _dispatch(SetMuted(muted));

  /// Routes audio to the loudspeaker, or back to the automatic choice.
  Future<void> setSpeaker({required bool speakerOn}) => setAudioRoute(
    speakerOn ? CallAudioRoute.speaker : CallAudioRoute.earpiece,
  );

  /// Sends audio to [route] and remembers the choice for the rest of the call.
  ///
  /// The choice is honoured only while [route] remains available, which is what
  /// makes a headset being unplugged fall back to the receiver instead of
  /// leaving the call routed at an empty socket.
  Future<void> setAudioRoute(CallAudioRoute route) async {
    _preferredRoute = route;
    await _reconcileAudio();
    _publish();
  }

  /// Turns the local camera on or off within an established video call. Does
  /// not renegotiate — see [requestVideo].
  Future<void> setCameraEnabled({required bool enabled}) =>
      _dispatch(SetCameraEnabled(enabled));

  Future<void> switchCamera() => _dispatch(const SwitchCamera());

  /// Asks to add video to a voice call, or to drop back to audio.
  Future<void> requestVideo({bool video = true}) =>
      _dispatch(RequestVideoUpgrade(video: video));

  Future<void> setHold({required bool onHold}) => _dispatch(SetHold(onHold));

  /// Releases everything. Ends a call in progress first, so the far end is told
  /// rather than left listening to silence.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    if (_machine.state.isLive) await _dispatch(const HangUp());

    await _signals?.cancel();
    await _ticks?.cancel();
    await _routes?.cancel();
    await _teardownEngine();
    await _audio?.stop();
    await _audio?.dispose();
    await _states.close();
  }

  // -------------------------------------------------------------------------
  // The queue.
  // -------------------------------------------------------------------------

  /// Feeds one input, after everything already queued.
  ///
  /// Errors are swallowed rather than propagated: an input that fails must not
  /// poison the queue, or the hang-up behind it never runs.
  Future<void> _dispatch(CallInput input) {
    if (_disposed && input is! HangUp) return Future<void>.value();
    return _queue = _queue.then((_) => _handle(input)).catchError((
      Object error,
      StackTrace stack,
    ) {
      debugPrint('weft: call input failed: $error');
    });
  }

  /// Runs one input to completion. Called from inside the queue only — feeding
  /// results back through [_dispatch] would wait on the queue entry that is
  /// still running.
  Future<void> _handle(CallInput input) async {
    final transition = _machine.handle(input);
    await _execute(transition);
    _updateDeadlines(transition);
    await _reconcileAudio();
    _publish();
  }

  Future<void> _execute(CallTransition transition) async {
    for (final intent in transition.intents) {
      switch (intent) {
        case final SignallingIntent signalling:
          await _send(signalling);
        case final MediaIntent media:
          await _perform(media);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Signalling.
  // -------------------------------------------------------------------------

  void _onSignal(CallSignal signal) {
    if (signal is CallInviteSignal) _rememberRoom(signal.callId, signal.roomId);
    unawaited(_dispatch(signal));
  }

  Future<void> _send(SignallingIntent intent) async {
    final roomId = _roomIdFor(intent);
    if (roomId == null) {
      debugPrint('weft: no room for ${intent.runtimeType} on ${intent.callId}');
      return;
    }

    try {
      await _signalling.send(
        intent,
        roomId: roomId,
        // MSC2746 reads an absent `invitee` as "any member of the room", which
        // in a room holding a bridge bot or an integration manager means
        // ringing them too.
        invitee: intent is SendInvite
            ? _machine.session?.peer.matrixUserId
            : null,
      );
    } on CallSignallingException catch (error) {
      debugPrint('weft: could not send a call event: ${error.message}');
      // An invite or answer that never left is a call that cannot happen; a
      // candidate or a hangup that failed is not worth ending anything over.
      if (intent is SendInvite || intent is SendAnswer) {
        _startFailure = CallStartFailure.signallingFailed;
        await _handle(const HangUp(reason: CallEndReason.unknownError));
      }
    }
  }

  /// Which room an outbound event belongs in.
  ///
  /// Only [SendInvite] carries a room of its own. Everything else is looked up:
  /// first against the active call, then against the invites seen recently,
  /// which is what addresses a `user_busy` reject to the room the second caller
  /// is actually ringing in.
  String? _roomIdFor(SignallingIntent intent) {
    if (intent is SendInvite) return intent.roomId;
    final session = _machine.session;
    if (session != null && session.callId == intent.callId) {
      return session.roomId;
    }
    return _roomForCall[intent.callId];
  }

  void _rememberRoom(String callId, String roomId) {
    _roomForCall[callId] = roomId;
    // A cap, not a cache policy. Only the call being rejected right now is ever
    // read back; the rest are kept because an invite may be retried and cost
    // one short string each.
    while (_roomForCall.length > 16) {
      _roomForCall.remove(_roomForCall.keys.first);
    }
  }

  // -------------------------------------------------------------------------
  // Media.
  // -------------------------------------------------------------------------

  Future<void> _perform(MediaIntent intent) async {
    switch (intent) {
      case CreateOffer():
        await _describe(
          () async => (await _ensureEngine()).createOffer(video: intent.video),
        );
      case CreateAnswer():
        await _describe(
          () async => (await _ensureEngine()).createAnswer(
            intent.remoteOffer,
            video: intent.video,
          ),
        );
      case ApplyRemoteDescription():
        // An answer applied mid-call is a renegotiation completing, and is the
        // one observable that says so from out here — the machine's own latch
        // is private.
        if (intent.description.type == SdpType.answer &&
            _machine.state.hasPeerConnection) {
          _negotiationDeadline = null;
        }
        await _guardMedia(
          () async => (await _ensureEngine()).applyRemoteDescription(
            intent.description,
          ),
        );
      case AddRemoteCandidate():
        try {
          await _engine?.addCandidate(intent.candidate);
        } on Object catch (error) {
          // One malformed candidate is not a call. This is why the machine
          // emits an intent per candidate rather than per batch.
          debugPrint('weft: rejected an ICE candidate: $error');
        }
      case ApplyMute():
        await _bestEffort(() => _engine?.setMute(intent.muted));
      case ApplyVideo():
        await _bestEffort(() => _engine?.setVideo(intent.enabled));
      case ApplySwitchCamera():
        await _bestEffort(() => _engine?.switchCamera());
      case DisposeMedia():
        await _teardownEngine();
        await _handle(const MediaDisposed());
    }
  }

  /// Runs a description-producing call and feeds the result back.
  Future<void> _describe(Future<SessionDescription> Function() produce) async {
    try {
      final description = await produce();
      await _handle(LocalDescriptionReady(description));
    } on Object catch (error) {
      await _onMediaError(error);
    }
  }

  Future<void> _guardMedia(Future<void> Function() run) async {
    try {
      await run();
    } on Object catch (error) {
      await _onMediaError(error);
    }
  }

  /// A failure in the middle of a call is not the same as one at its start.
  ///
  /// Mid-call, the only thing that could have failed is a renegotiation, and
  /// [NegotiationFailed] is non-fatal by construction — the call carries on with
  /// whatever was already negotiated. Before the call is up, the same failure is
  /// the microphone or the camera, and there is no call to carry on with.
  Future<void> _onMediaError(Object error) async {
    debugPrint('weft: media failed: $error');
    if (_machine.state == CallState.connected ||
        _machine.state == CallState.onHold) {
      _negotiationDeadline = null;
      await _handle(const NegotiationFailed());
      return;
    }
    _startFailure = CallStartFailure.mediaUnavailable;
    await _handle(const MediaFailed(reason: CallEndReason.mediaFailed));
  }

  Future<void> _bestEffort(Future<void>? Function() run) async {
    try {
      await run();
    } on Object catch (error) {
      debugPrint('weft: media command failed: $error');
    }
  }

  Future<MediaEngine> _ensureEngine() async {
    final existing = _engine;
    if (existing != null) return existing;

    // Asked for once per call, and this is where the homeserver's answer — and
    // its warning — enters the app.
    final ice = await _iceConfiguration();
    _ice = ice;
    if (!ice.hasTurn) {
      debugPrint('weft: placing a call without a relay: ${ice.warning}');
    }

    final engine = await _createEngine(ice);
    _engine = engine;
    _engineCandidates = engine.localCandidates.listen(
      (candidate) => unawaited(_dispatch(LocalCandidate(candidate))),
    );
    _engineStates = engine.connectionState.listen(_onConnectionState);
    return engine;
  }

  Future<void> _teardownEngine() async {
    final engine = _engine;
    _engine = null;
    _iceDeadline = null;
    _reconnectDeadline = null;
    _negotiationDeadline = null;
    await _engineCandidates?.cancel();
    _engineCandidates = null;
    await _engineStates?.cancel();
    _engineStates = null;
    if (engine == null) return;
    try {
      await engine.dispose();
    } on Object catch (error) {
      // Whatever happened, the call is over. The machine's ending grace turns
      // this into an `ended` on the next tick rather than a screen stuck on
      // "Ending…".
      debugPrint('weft: media teardown failed: $error');
    }
  }

  void _onConnectionState(MediaConnectionState state) {
    switch (state) {
      case MediaConnectionState.connected:
        _reconnectDeadline = null;
        _iceDeadline = null;
        unawaited(_dispatch(MediaConnected(codecs: _engine?.negotiatedCodecs)));
        _publish();
      case MediaConnectionState.disconnected:
        // Recoverable, and routinely is: a phone changing from wifi to mobile
        // does this every time. Give it a grace period rather than ending a
        // call that would have healed.
        _reconnectDeadline ??= _clock().add(reconnectGrace);
        // Published here rather than left for the next transition: nothing else
        // is going to happen for the length of the grace period, and a call
        // screen that says nothing while the audio has stopped is the one
        // moment a user starts pressing buttons.
        _publish();
      case MediaConnectionState.failed:
        unawaited(_dispatch(const MediaFailed()));
      case MediaConnectionState.connecting:
      case MediaConnectionState.closed:
        break;
    }
  }

  // -------------------------------------------------------------------------
  // Time.
  // -------------------------------------------------------------------------

  void _onTick(void _) {
    unawaited(
      _queue = _queue
          .then((_) async {
            // The machine's own deadlines — invite lifetime, the ending grace —
            // come first, so a tick that expires an invite is not also charged
            // with an ICE timeout for the call it just ended.
            await _handle(const Tick());
            await _checkDeadlines();
          })
          .catchError((Object error, StackTrace stack) {
            debugPrint('weft: call tick failed: $error');
          }),
    );
  }

  Future<void> _checkDeadlines() async {
    final now = _clock();

    if (_expired(_iceDeadline, now) || _expired(_reconnectDeadline, now)) {
      _iceDeadline = null;
      _reconnectDeadline = null;
      await _handle(const MediaFailed());
      return;
    }

    if (_expired(_negotiationDeadline, now)) {
      _negotiationDeadline = null;
      await _handle(const NegotiationFailed());
    }
  }

  bool _expired(DateTime? deadline, DateTime now) =>
      deadline != null && !now.isBefore(deadline);

  void _updateDeadlines(CallTransition transition) {
    if (transition.to == CallState.connecting && transition.changedState) {
      // Nothing in the machine ends a call that never connects.
      _iceDeadline = _clock().add(iceTimeout);
    }
    // Only on the transition *into* connected, never on every input received
    // while already there. A [Tick] is a transition too, and clearing the
    // reconnection deadline on each of them would mean the grace period never
    // expired: a peer connection that dropped and did not heal would sit in
    // "Reconnecting…" until one of the two people gave up, which is precisely
    // the failure the grace period exists to bound.
    if (transition.to == CallState.connected && transition.changedState) {
      _iceDeadline = null;
      _reconnectDeadline = null;
    }
    if (!transition.to.isLive) {
      _iceDeadline = null;
      _reconnectDeadline = null;
      _negotiationDeadline = null;
    }
    // An offer we sent mid-call. The far end has until the deadline to answer
    // it, after which the machine's latch would otherwise stay set and every
    // later upgrade or hold be a silent no-op.
    if (transition.signalling.whereType<SendNegotiate>().any(
      (intent) => intent.description.type == SdpType.offer,
    )) {
      _negotiationDeadline = _clock().add(negotiationTimeout);
    }
  }

  // -------------------------------------------------------------------------
  // Audio.
  // -------------------------------------------------------------------------

  void _onRoutesChanged(Set<CallAudioRoute> routes) {
    _availableRoutes = routes;
    unawaited(() async {
      await _reconcileAudio();
      _publish();
    }());
  }

  Future<void> _refreshRoutes() async {
    final controller = _audio;
    if (controller == null) return;
    _availableRoutes = await controller.refresh();
  }

  /// Puts the audio session where the call says it should be.
  ///
  /// [SetSpeaker] is fed straight to the machine rather than through the queue
  /// because it emits no intents — it only records the flag the call screen's
  /// speaker button reads — so there is nothing to execute and no recursion to
  /// guard against.
  Future<void> _reconcileAudio() async {
    final controller = _audio;
    final session = _machine.session;

    if (session == null || !session.state.isLive) {
      // Only once, and only if a call actually took the audio session: calling
      // this on every tick of an idle app would fight whatever else on the
      // phone is playing sound.
      if (_audioHeld) {
        _audioHeld = false;
        await controller?.stop();
      }
      _state = _state.copyWith(
        audio: CallAudioState(available: _availableRoutes),
      );
      return;
    }

    final route = resolveCallAudioRoute(
      video: session.videoEnabled,
      available: _availableRoutes,
      preferred: _preferredRoute,
    );
    // Proximity only for a voice call held to an ear. Blanking the screen
    // during a video call turns it black and puts the hang-up button out of
    // reach.
    final proximity = route.isAgainstTheEar && !session.videoEnabled;

    if (route != _state.audio.route || !_audioHeld) {
      await controller?.apply(route);
    }
    _audioHeld = true;
    if (proximity != _state.audio.proximityActive) {
      await controller?.setProximityEnabled(enabled: proximity);
    }

    _state = _state.copyWith(
      audio: CallAudioState(
        route: route,
        available: _availableRoutes,
        proximityActive: proximity,
      ),
    );

    final speakerOn = route == CallAudioRoute.speaker;
    if (session.speakerOn != speakerOn) {
      _machine.handle(SetSpeaker(speakerOn));
    }
  }

  void _publish() {
    final engine = _engine;
    _state = CallServiceState(
      session: _machine.session,
      audio: _state.audio,
      ice: _ice,
      // `CallVideoSource` is not a subtype of `MediaEngine` — it is a second
      // interface the real engine happens to implement — so this is a cast
      // rather than a promotion.
      video: engine is CallVideoSource ? engine as CallVideoSource : null,
      // Only while there is a live call: a deadline left over from the call
      // that just ended would leave "Reconnecting…" on an end screen.
      reconnecting: _reconnectDeadline != null && _machine.state.isLive,
    );
    if (!_states.isClosed) _states.add(_state);
  }
}

/// A call id with enough entropy that two devices dialling in the same
/// millisecond cannot tie.
///
/// Glare is resolved by comparing these lexically, so a tie would leave both
/// sides believing they won. The timestamp prefix keeps them roughly ordered,
/// which is only a debugging convenience — the protocol does not care.
String _randomCallId() {
  final random = Random.secure();
  final suffix = List.generate(
    8,
    (_) => random.nextInt(36).toRadixString(36),
  ).join();
  return '${DateTime.now().microsecondsSinceEpoch}$suffix';
}
