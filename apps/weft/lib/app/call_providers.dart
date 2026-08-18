import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_matrix/weft_matrix.dart';

import '../services/call/call_audio.dart';
import '../services/call/call_service.dart';
import '../services/call/webrtc_media_engine.dart';
import 'session_providers.dart';

/// The call layer, assembled, or null when this build cannot carry a call.
///
/// Null in demo mode and before login, for the reason
/// `notificationServiceProvider` is: there is no client to signal through, and
/// a call against fixtures would be a call to nobody. Every call surface reads
/// this and shows its button disabled rather than asserting.
///
/// The three seams are wired here and nowhere else — this is the only place in
/// Weft that names both `MatrixCallSignalling` and [WebRTCMediaEngine], which
/// is what keeps [CallService] testable against a `StreamController` and a
/// list.
final callServiceProvider = Provider<CallService?>((ref) {
  if (kDemoMode) return null;

  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) return null;

  final sdk.Client client = session.client;
  final MatrixCallSignalling signalling;
  try {
    signalling = MatrixCallSignalling.forClient(client);
  } on CallSignallingException {
    // Not signed in yet. The auth gate makes this transient, and a null service
    // is what every surface already handles.
    return null;
  }

  final turnServers = MatrixTurnServers.forClient(client);
  final service = CallService(
    signalling: signalling,
    // A closure rather than the object, so the service never learns what a
    // homeserver is: `configuration()` already caches, shares one in-flight
    // request and refetches before expiry.
    iceConfiguration: turnServers.configuration,
    createEngine: (ice) async => WebRTCMediaEngine(iceServers: ice.servers),
    // Both the to-device path and the timeline path feed this, which is what
    // makes an invite in an encrypted room arrive like any other.
    signals: signalling.signalsFrom(client.onCallEvents.stream),
    audio: PlatformCallAudio(),
  );

  ref.onDispose(() {
    turnServers.invalidate();
    unawaited(service.dispose());
  });
  return service;
});

/// The active call, for the call screen, the incoming sheet and the minimised
/// bar.
///
/// Seeded with the service's current state so a widget built mid-call paints
/// the call rather than a frame of nothing while it waits for the next change.
final activeCallProvider = StreamProvider<CallServiceState>((ref) async* {
  final service = ref.watch(callServiceProvider);
  if (service == null) return;
  yield service.state;
  yield* service.states;
});

/// The current call state, whether or not anything has changed yet.
///
/// A plain read for the surfaces that only need "is there a call" — the app
/// bar's button, the router's guard — without subscribing to every ICE-driven
/// repaint.
final currentCallProvider = Provider<CallServiceState>((ref) {
  final service = ref.watch(callServiceProvider);
  return ref.watch(activeCallProvider).value ??
      service?.state ??
      const CallServiceState();
});
