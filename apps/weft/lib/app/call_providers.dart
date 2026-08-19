import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_call/weft_call.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../features/call/call_controls.dart';
import '../services/call/call_audio.dart';
import '../services/call/call_service.dart';
import '../services/call/webrtc_media_engine.dart';
import 'providers.dart';
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

/// What the call surfaces are allowed to do to the call.
///
/// [InertCallControls] before login and in demo mode rather than a null: every
/// call surface would otherwise need a second branch for "the buttons are
/// there but do nothing", and a screen that cannot be built at all is worse
/// than one whose buttons are inert — there is no call in that state anyway.
final callControlsProvider = Provider<CallControls>((ref) {
  final service = ref.watch(callServiceProvider);
  if (service == null) return const InertCallControls();
  return CallServiceControls(service);
});

/// Whether a full-screen call surface is up.
///
/// The minimised call bar reads it, and it is written by the two screens that
/// take over the display. A boolean rather than a route observer because that
/// is exactly the fact the bar needs — "the call is already on screen, do not
/// offer to return to it" — and a route observer would answer a related but
/// different question about what is on top of the navigator.
final callScreenVisibleProvider = NotifierProvider<CallScreenVisibility, bool>(
  CallScreenVisibility.new,
);

class CallScreenVisibility extends Notifier<bool> {
  @override
  bool build() => false;

  // ignore: avoid_positional_boolean_parameters
  void set(bool visible) => state = visible;
}

/// Whether [chat] can carry a call, and where it would go.
///
/// The predicate lives in `weft_call`; what this adds is the merged identity
/// behind the conversation, which is what turns a room into a person. Keyed by
/// chat id and recomputed when the inbox changes, so the app bar does not walk
/// the identity graph on every rebuild.
final callAvailabilityProvider = Provider.family<CallAvailability, String>((
  ref,
  chatId,
) {
  final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
  final chat = chats.firstWhereOrNull((c) => c.id == chatId);
  if (chat == null) {
    return const CallBlocked(
      CallBlocker.unknownPeer,
      'This conversation is still loading.',
    );
  }
  return callAvailabilityFor(chat, contact: contactForChat(ref, chat));
});

/// The merged contact behind a conversation, or null when there is none.
///
/// `Chat.contactId` is set for every DM the identity graph knows — including
/// unmerged ones, which get a contact of their own — so this is the ordinary
/// path rather than a merged-only special case.
UnifiedContact? contactForChat(Ref ref, Chat chat) {
  final contactId = chat.contactId;
  if (contactId == null) return null;
  return ref
      .watch(chatRepositoryProvider)
      .identityGraph
      .contacts()
      .firstWhereOrNull((contact) => contact.id == contactId);
}
