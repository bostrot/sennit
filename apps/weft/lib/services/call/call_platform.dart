import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:weft_call/weft_call.dart';

import 'call_audio.dart';
import 'call_service.dart';

/// What the *platform's* call UI is allowed to do to a call.
///
/// Deliberately not [CallControls]. That interface is the set of buttons a Weft
/// screen draws — camera, camera switch, video upgrade — and none of those
/// exist on a CallKit call screen or in Android's call log. This is the set both
/// systems actually offer, and it is a different five: CallKit's `CXAnswerCall`,
/// `CXEndCall`, `CXSetMutedCall`, `CXSetHeldCall` and its route changes, against
/// `ConnectionService`'s `onAnswer`, `onReject`/`onDisconnect`, and
/// `onHold`/`onUnhold`. Keeping them apart is what stops the platform bridge
/// growing a `switchCamera` nothing will ever call.
abstract interface class CallPlatformActions {
  /// Answers the ringing call. Video is whatever the caller offered — the
  /// system's answer button carries no opinion about the camera.
  Future<void> accept();

  /// Declines a ringing call. `m.call.reject`.
  Future<void> decline();

  /// Ends an outgoing or established call. `m.call.hangup`.
  Future<void> hangUp();

  Future<void> setMuted({required bool muted});

  Future<void> setHold({required bool onHold});

  /// The system moved the audio somewhere — CallKit's route picker, or a
  /// headset button.
  Future<void> setAudioRoute(CallAudioRoute route);
}

/// [CallPlatformActions] over the real service.
///
/// A forwarder rather than `CallService implements CallPlatformActions`, for the
/// same reason [CallServiceControls] is one: the service layer keeps knowing
/// nothing about who is driving it.
class CallServicePlatformActions implements CallPlatformActions {
  const CallServicePlatformActions(this._service);

  final CallService _service;

  @override
  Future<void> accept() => _service.accept();

  @override
  Future<void> decline() => _service.decline();

  @override
  Future<void> hangUp() => _service.hangUp();

  @override
  Future<void> setMuted({required bool muted}) =>
      _service.setMuted(muted: muted);

  @override
  Future<void> setHold({required bool onHold}) =>
      _service.setHold(onHold: onHold);

  @override
  Future<void> setAudioRoute(CallAudioRoute route) =>
      _service.setAudioRoute(route);
}

/// The method names that cross `com.bostrot.weft/call`.
///
/// Constants rather than literals for the reason [WeftNotificationActions]
/// gives: each of these strings is written in three languages — here, in
/// `CallManager.swift` and in `CallBridge.kt` — and a typo in any one of them is
/// an answer button that silently does nothing. There is no compiler on a
/// method channel.
abstract final class CallPlatformMethods {
  // Dart → platform.
  static const String reportIncoming = 'reportIncomingCall';
  static const String reportOutgoing = 'reportOutgoingCall';
  static const String reportConnected = 'reportCallConnected';
  static const String reportEnded = 'reportCallEnded';
  static const String updateCall = 'updateCall';
  static const String setProximityEnabled = 'setProximityEnabled';

  // Platform → Dart.
  static const String onAnswer = 'onAnswer';
  static const String onDecline = 'onDecline';
  static const String onHangUp = 'onHangUp';
  static const String onSetMuted = 'onSetMuted';
  static const String onSetHeld = 'onSetHeld';
  static const String onAudioRouteChanged = 'onAudioRouteChanged';
  static const String onVoipToken = 'onVoipToken';
  static const String onVoipPush = 'onVoipPush';
}

/// Why the platform was told a call ended, in the vocabulary both systems share.
///
/// CallKit's `CXCallEndedReason` and Android's `DisconnectCause` are different
/// enums with different members, and neither is [CallEndReason]. Rather than
/// send an integer that means one thing on one platform, the wire carries these
/// names and each native side maps them once — which is also the only place the
/// mapping can be got right, since only CallKit distinguishes
/// `.answeredElsewhere` and only Telecom has `DisconnectCause.MISSED`.
enum PlatformCallEnd {
  /// The user, on either side, hung up an established call.
  hangup,

  /// Declined before it was answered.
  declined,

  /// Nobody answered in time. The one that becomes a missed-call entry.
  missed,

  /// Another of this user's devices took it.
  answeredElsewhere,

  /// A call was already in progress.
  busy,

  /// It broke. ICE never succeeded, the microphone would not open, signalling
  /// failed.
  failed;

  /// How a [CallEndReason] is told to the system.
  ///
  /// [CallEndReason.remoteReject] becomes [missed] rather than [declined]:
  /// "declined" on a call log means *this* user declined it, and a call the far
  /// end refused is one this phone never got an answer to. Every platform's call
  /// log makes the same distinction and gets it from this line.
  static PlatformCallEnd forReason(
    CallEndReason reason, {
    required bool incoming,
  }) => switch (reason) {
    CallEndReason.userHangup ||
    CallEndReason.remoteHangup ||
    CallEndReason.replaced => hangup,
    CallEndReason.localReject => declined,
    CallEndReason.remoteReject => incoming ? declined : missed,
    CallEndReason.inviteTimeout => missed,
    CallEndReason.answeredElsewhere => answeredElsewhere,
    CallEndReason.userBusy => busy,
    CallEndReason.iceFailed ||
    CallEndReason.mediaFailed ||
    CallEndReason.glareLost ||
    CallEndReason.unknownError => failed,
  };
}

/// The one seam between a call and the operating system it is happening on.
///
/// Both directions cross `com.bostrot.weft/call`, and there is exactly one
/// channel on purpose — the phase's own constraint, and the reason for it is
/// that all three platforms must drive *one* state machine. A second channel
/// would be a second place for an answer to go missing, and an answer that goes
/// missing is a phone that rings after the user has picked it up.
///
/// ## Outbound is a diff, not a set of call sites
///
/// [sync] is fed the whole [CallServiceState] and works out what the platform
/// has not been told yet. Nothing in [CallService] calls this; it subscribes to
/// the state stream instead. That inversion is what keeps the two in step: a
/// future transition that forgets to notify CallKit is not possible, because
/// nothing notifies CallKit — the state does.
///
/// ## Inbound is guarded by call id
///
/// Every action from the platform names the call it belongs to and is dropped
/// when that is not the call in progress. The race is real and routine: CallKit
/// delivers a `CXEndCallAction` for a call the far end has already hung up,
/// because the user pressed the red button in the half-second before the system
/// UI caught up. Without the guard that ends the *next* call.
///
/// ## What this is not
///
/// It does not ring, notify or draw anything. On iOS the native side owns the
/// incoming-call UI because CallKit demands it; on Android a self-managed
/// `ConnectionService` posts its own full-screen notification. Both are told
/// what to show from here and decide for themselves how.
class CallPlatformBridge {
  CallPlatformBridge({
    required CallPlatformActions actions,
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting TargetPlatform? platform,
  }) : _actions = actions,
       _channel = channel ?? const MethodChannel(kCallChannelName),
       _platform = platform ?? defaultTargetPlatform {
    // Set unconditionally rather than only on mobile: a desktop build has no
    // native handler and will never invoke anything, and a handler that is
    // never called costs nothing — while a build whose platform was misdetected
    // and silently stopped answering would be very hard to see.
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  final CallPlatformActions _actions;
  final MethodChannel _channel;
  final TargetPlatform _platform;

  StreamSubscription<CallServiceState>? _states;

  /// VoIP push tokens, as PushKit hands them over. Empty on every other
  /// platform.
  ///
  /// Published rather than consumed here because registering it is not this
  /// layer's job: a VoIP token becomes an `m.call.invite` that wakes the phone
  /// only once it is registered as a *second* Matrix pusher, with its own app id
  /// and its own APNs certificate — see `docs/decisions/adr-002-ios-signing-handoff.md`.
  /// Until that certificate exists there is nothing to register it with, and a
  /// token dropped on the floor is better than a pusher pointed at a gateway
  /// that cannot sign for it.
  Stream<String> get voipTokens => _voipTokens.stream;
  final StreamController<String> _voipTokens =
      StreamController<String>.broadcast();

  /// Fired when a VoIP push arrives, carrying whatever the gateway sent.
  ///
  /// The native side has *already* reported an incoming call to CallKit by the
  /// time this arrives — it has no choice, iOS terminates an app that does not —
  /// so this is not a request to ring. It is the wake-up that lets the client
  /// sync and find the invite the push was about.
  Stream<Map<String, Object?>> get voipPushes => _voipPushes.stream;
  final StreamController<Map<String, Object?>> _voipPushes =
      StreamController<Map<String, Object?>>.broadcast();

  /// The last call the platform was told about, and what it was told.
  String? _reportedCallId;
  CallState? _reportedState;
  bool? _reportedMuted;
  bool? _reportedHeld;

  bool get _hasNativeIntegration =>
      _platform == TargetPlatform.android || _platform == TargetPlatform.iOS;

  /// Keeps the platform in step with [states] for as long as this lives.
  void follow(Stream<CallServiceState> states) {
    _states?.cancel();
    _states = states.listen((state) => unawaited(sync(state)));
  }

  /// Tells the platform whatever it has not already been told about [state].
  ///
  /// Idempotent: calling it twice with the same state sends nothing the second
  /// time, which is what makes it safe to drive from a stream that fires on
  /// every ICE candidate.
  Future<void> sync(CallServiceState state) async {
    if (!_hasNativeIntegration) return;

    final session = state.session;
    if (session == null) {
      await _clear();
      return;
    }

    // A second call while one is reported: end the first before announcing the
    // second, so the system never holds two. Weft carries one at a time and a
    // call log that disagrees is worse than no call log.
    if (_reportedCallId != null && _reportedCallId != session.callId) {
      await _invoke(CallPlatformMethods.reportEnded, {
        'callId': _reportedCallId,
        'reason': PlatformCallEnd.failed.name,
      });
      _forget();
    }

    if (_reportedCallId == null) {
      // A call that is already over when it is first seen is not announced at
      // all. Reporting an incoming call and ending it in the same frame gives
      // CallKit a call screen that flashes, and Telecom a spurious missed-call
      // entry for an invite that expired while the phone was in a pocket —
      // which is the ordinary case after a sync backlog.
      if (!session.state.isLive) return;
      await _announce(session);
    }

    await _update(session);
  }

  Future<void> _announce(CallSession session) async {
    _reportedCallId = session.callId;
    // Deliberately left null rather than set to the state being announced. A
    // call whose *first* published state is already `connected` — the service
    // published nothing earlier, or a widget subscribed mid-call — still needs
    // its connected transition reported, because that is what starts the
    // system's duration timer. Recording the state here would suppress it and
    // leave a call screen counting from nothing.
    _reportedMuted = session.muted;
    _reportedHeld = session.state == CallState.onHold;

    await _invoke(
      session.isIncoming
          ? CallPlatformMethods.reportIncoming
          : CallPlatformMethods.reportOutgoing,
      _describe(session),
    );
  }

  Future<void> _update(CallSession session) async {
    if (session.state == CallState.connected &&
        _reportedState != CallState.connected) {
      await _invoke(CallPlatformMethods.reportConnected, {
        'callId': session.callId,
        'connectedAt': session.connectedAt?.millisecondsSinceEpoch,
      });
    }

    // Mute and hold round-trip: the system UI has its own buttons for both, so
    // a change made in Weft has to go back out or the two disagree. The
    // equality checks are what stops that becoming a loop — the platform's own
    // action arrives, is applied, comes back here as state, and matches.
    final held = session.state == CallState.onHold;
    if (session.muted != _reportedMuted || held != _reportedHeld) {
      await _invoke(CallPlatformMethods.updateCall, {
        'callId': session.callId,
        'muted': session.muted,
        'held': held,
        'video': session.videoEnabled,
      });
      _reportedMuted = session.muted;
      _reportedHeld = held;
    }

    _reportedState = session.state;

    if (!session.state.isLive) {
      await _invoke(CallPlatformMethods.reportEnded, {
        'callId': session.callId,
        'reason': PlatformCallEnd.forReason(
          session.endReason ?? CallEndReason.unknownError,
          incoming: session.isIncoming,
        ).name,
      });
      _forget();
    }
  }

  /// Everything the platform needs to draw a call it did not create.
  Map<String, Object?> _describe(CallSession session) => {
    'callId': session.callId,
    'roomId': session.roomId,
    // The handle is what the system's call log records and what a redial
    // would dial. A Matrix id rather than a display name because it is the
    // only part of a peer that is stable and addressable.
    'handle': session.peer.matrixUserId,
    'displayName': session.peer.label,
    'video': session.videoEnabled,
    'muted': session.muted,
  };

  /// Ends whatever the platform still thinks is happening.
  ///
  /// Reached when the service publishes a state with no session at all, which
  /// only happens on disposal — an ended call keeps its session so the screen
  /// can say why. So this is the "Weft went away mid-call" path, and a system
  /// left holding a call nobody can hang up is the failure it exists to avoid.
  Future<void> _clear() async {
    final callId = _reportedCallId;
    if (callId == null) return;
    _forget();
    await _invoke(CallPlatformMethods.reportEnded, {
      'callId': callId,
      'reason': PlatformCallEnd.failed.name,
    });
  }

  void _forget() {
    _reportedCallId = null;
    _reportedState = null;
    _reportedMuted = null;
    _reportedHeld = null;
  }

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // A build with no native call code — every desktop, and any mobile build
      // predating it. A call without a system call screen is a working call.
    } on PlatformException catch (error) {
      // Reported, not thrown. Neither CallKit nor Telecom is load-bearing: the
      // call is already happening over WebRTC and Weft's own UI is already
      // drawing it. What is lost is the lock-screen answer button.
      debugPrint(
        'weft: platform call integration refused $method: '
        '${error.code} ${error.message}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Platform → Dart.
  // ---------------------------------------------------------------------------

  Future<Object?> _onPlatformCall(MethodCall call) async {
    final arguments = (call.arguments as Map<Object?, Object?>? ?? const {})
        .map((key, value) => MapEntry(key.toString(), value));

    switch (call.method) {
      case CallPlatformMethods.onVoipToken:
        final token = arguments['token'] as String?;
        if (token != null && token.isNotEmpty && !_voipTokens.isClosed) {
          _voipTokens.add(token);
        }
        return null;

      case CallPlatformMethods.onVoipPush:
        if (!_voipPushes.isClosed) _voipPushes.add(arguments);
        return null;

      case CallPlatformMethods.onAudioRouteChanged:
        // Not guarded by call id: a route change belongs to the audio session
        // rather than to a call, and one arriving a beat after a call ended is
        // still the truth about where sound is going.
        final route = _routeNamed(arguments['route'] as String?);
        if (route != null) await _actions.setAudioRoute(route);
        return null;
    }

    // Everything below acts on a call, so it has to be the right one. A
    // `CXEndCallAction` for a call the far end hung up a moment ago is the
    // ordinary case, not a defensive hypothetical.
    if (!_isCurrent(arguments['callId'])) return null;

    switch (call.method) {
      case CallPlatformMethods.onAnswer:
        await _actions.accept();
      case CallPlatformMethods.onDecline:
        await _actions.decline();
      case CallPlatformMethods.onHangUp:
        await _actions.hangUp();
      case CallPlatformMethods.onSetMuted:
        await _actions.setMuted(muted: arguments['muted'] as bool? ?? false);
      case CallPlatformMethods.onSetHeld:
        await _actions.setHold(onHold: arguments['held'] as bool? ?? false);
      default:
        throw MissingPluginException('${call.method} is not a call method');
    }
    return null;
  }

  /// Whether an action names the call currently reported.
  ///
  /// A missing id is accepted. Android's `Connection` callbacks carry no
  /// identifier of their own — the connection *is* the identity — so the bridge
  /// there sends what it was given and an older build may send nothing.
  bool _isCurrent(Object? callId) =>
      callId == null || callId == _reportedCallId;

  static CallAudioRoute? _routeNamed(String? name) {
    for (final route in CallAudioRoute.values) {
      if (route.name == name) return route;
    }
    return null;
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _states?.cancel();
    _states = null;
    await _clear();
    await _voipTokens.close();
    await _voipPushes.close();
  }
}
