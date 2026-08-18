import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'call_state.dart';
import 'sdp.dart';

/// Who placed the call.
///
/// Not merely cosmetic: direction decides which side sends `m.call.invite` and
/// which sends `m.call.answer`, and it is the tiebreak the UI uses to show
/// "Calling…" against "Incoming call".
enum CallDirection { incoming, outgoing }

/// The other person on the call.
///
/// Deliberately a small value type rather than a [UnifiedContact]: the state
/// machine needs a Matrix user id and nothing else, and a test that has to
/// build a whole merged contact to assert on glare is a test nobody writes.
/// [CallPeer.forContact] exists for the app, which does have the contact and
/// does want the inbox's display name on the call screen.
@immutable
class CallPeer {
  const CallPeer({
    required this.matrixUserId,
    this.displayName,
    this.avatarUrl,
    this.networks = const [ChatNetwork.matrix],
  });

  /// Resolve a peer through the merged identity, or null when the contact has
  /// no Matrix-native leg.
  ///
  /// Null is the whole point. Calls are Matrix-native only, and a bridged
  /// contact is reachable exclusively through a ghost user that will never
  /// answer an `m.call.invite`. Making that a missing value rather than a
  /// boolean somewhere else means the call cannot be constructed at all.
  static CallPeer? forContact(UnifiedContact contact) {
    final handle = contact.handleFor(ChatNetwork.matrix);
    if (handle == null) return null;
    return CallPeer(
      matrixUserId: handle.matrixUserId,
      displayName: contact.displayName,
      avatarUrl: contact.avatarUrl ?? handle.avatarUrl,
      networks: contact.networks,
    );
  }

  /// The user the call is with, e.g. `@anna:example.org`.
  final String matrixUserId;

  final String? displayName;
  final String? avatarUrl;

  /// Every network this person is reachable on, not just Matrix — the call
  /// screen shows the same merged-identity glyphs as the inbox, so the name
  /// and badges on a call match the row the user tapped.
  final List<ChatNetwork> networks;

  /// What to put on screen.
  String get label => (displayName != null && displayName!.isNotEmpty)
      ? displayName!
      : matrixUserId;

  @override
  bool operator ==(Object other) =>
      other is CallPeer &&
      other.matrixUserId == matrixUserId &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl &&
      const ListEquality<ChatNetwork>().equals(other.networks, networks);

  @override
  int get hashCode => Object.hash(
    matrixUserId,
    displayName,
    avatarUrl,
    const ListEquality<ChatNetwork>().hash(networks),
  );

  @override
  String toString() => 'CallPeer($label)';
}

/// One call, as a value.
///
/// Immutable so that a transition produces a new session rather than mutating
/// the one a widget is already painting — the same reason every other value in
/// Weft is immutable, and it matters more here because a call changes state
/// several times a second while ICE settles.
@immutable
class CallSession {
  const CallSession({
    required this.callId,
    required this.partyId,
    required this.roomId,
    required this.peer,
    required this.direction,
    required this.state,
    required this.startedAt,
    this.remotePartyId,
    this.videoEnabled = false,
    this.muted = false,
    this.speakerOn = false,
    this.cameraOn = true,
    this.connectedAt,
    this.codecs,
    this.endReason,
  });

  /// The `call_id` shared by both parties. Also the value glare is resolved by.
  final String callId;

  /// This device's `party_id`. Per MSC2746 it identifies the *device*, not the
  /// user, which is why a second device answering is a distinguishable event
  /// rather than an echo of our own.
  final String partyId;

  final String roomId;
  final CallPeer peer;
  final CallDirection direction;

  /// Where the call is now. Kept on the session as well as on the machine so a
  /// widget holding one session has everything it needs to paint a frame.
  final CallState state;

  /// The far end's `party_id`, latched on the answer we selected. Once set,
  /// signalling from any other party for this call is ignored — that is what
  /// stops a second device's late candidates from being fed into a peer
  /// connection negotiated with the first.
  final String? remotePartyId;

  /// Whether video is currently part of the call. Starts false for a voice
  /// call and becomes true only after a successful audio-to-video
  /// renegotiation, never merely because one was requested.
  final bool videoEnabled;

  final bool muted;

  /// Audio routed to the loudspeaker. Tracked here but not acted on by the
  /// state machine: routing is a platform concern and deliberately absent from
  /// [MediaEngine], so the app reads this and drives the OS itself.
  final bool speakerOn;

  /// Local camera capture. Distinct from [videoEnabled] — a video call with the
  /// camera off is still a video call, and turning the camera back on must not
  /// renegotiate.
  final bool cameraOn;

  /// When the call was placed or the invite arrived.
  final DateTime startedAt;

  /// When media first flowed. Null until then, and the anchor the on-screen
  /// duration counts from — counting from [startedAt] would charge the user
  /// for the ringing.
  final DateTime? connectedAt;

  final CodecSummary? codecs;

  /// Non-null exactly when [state] is [CallState.ending] or [CallState.ended].
  final CallEndReason? endReason;

  bool get isOutgoing => direction == CallDirection.outgoing;

  bool get isIncoming => direction == CallDirection.incoming;

  /// How long media has been flowing, or null before it ever did.
  Duration? durationAt(DateTime now) =>
      connectedAt == null ? null : now.difference(connectedAt!);

  CallSession copyWith({
    CallState? state,
    String? remotePartyId,
    bool? videoEnabled,
    bool? muted,
    bool? speakerOn,
    bool? cameraOn,
    DateTime? connectedAt,
    CodecSummary? codecs,
    CallEndReason? endReason,
    CallPeer? peer,
  }) {
    return CallSession(
      callId: callId,
      partyId: partyId,
      roomId: roomId,
      peer: peer ?? this.peer,
      direction: direction,
      state: state ?? this.state,
      startedAt: startedAt,
      remotePartyId: remotePartyId ?? this.remotePartyId,
      videoEnabled: videoEnabled ?? this.videoEnabled,
      muted: muted ?? this.muted,
      speakerOn: speakerOn ?? this.speakerOn,
      cameraOn: cameraOn ?? this.cameraOn,
      connectedAt: connectedAt ?? this.connectedAt,
      codecs: codecs ?? this.codecs,
      endReason: endReason ?? this.endReason,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CallSession &&
      other.callId == callId &&
      other.partyId == partyId &&
      other.roomId == roomId &&
      other.peer == peer &&
      other.direction == direction &&
      other.state == state &&
      other.remotePartyId == remotePartyId &&
      other.videoEnabled == videoEnabled &&
      other.muted == muted &&
      other.speakerOn == speakerOn &&
      other.cameraOn == cameraOn &&
      other.startedAt == startedAt &&
      other.connectedAt == connectedAt &&
      other.codecs == codecs &&
      other.endReason == endReason;

  @override
  int get hashCode => Object.hash(
    callId,
    partyId,
    roomId,
    peer,
    direction,
    state,
    remotePartyId,
    videoEnabled,
    muted,
    speakerOn,
    cameraOn,
    startedAt,
    connectedAt,
    Object.hash(codecs, endReason),
  );

  @override
  String toString() =>
      'CallSession($callId, ${direction.name}, ${state.name}'
      '${videoEnabled ? ', video' : ''}'
      '${endReason != null ? ', ${endReason!.name}' : ''})';
}
