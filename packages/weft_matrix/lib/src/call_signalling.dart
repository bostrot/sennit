import 'dart:async';
import 'dart:convert';

import 'package:matrix/matrix.dart' as sdk;
import 'package:meta/meta.dart';
import 'package:weft_call/weft_call.dart';

/// The MSC2746 protocol version Weft speaks, stamped on every event it sends.
///
/// A string, not the integer `0` the pre-MSC dialect used. Both still arrive on
/// the wire and [_versionOf] normalises them, but Weft only ever *writes* this
/// one.
const String kVoipProtocolVersion = '1';

/// What went wrong putting a call event on the wire.
///
/// Shaped like [PusherRegistrationException]: [retryable] separates "the
/// network was bad" from "there is no such room", because a call cannot wait
/// out a backoff — a candidate that arrives after the callee gave up is worse
/// than one that never arrives, so the call service needs to know which
/// failures are worth a second attempt at all.
class CallSignallingException implements Exception {
  const CallSignallingException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => 'CallSignallingException($message)';
}

/// One `m.call.*` event reduced to the five things the mapping needs.
///
/// This type exists so that the parsing below is testable from a plain `Map`.
/// The SDK's own event classes cannot be built without a `Room`, which cannot
/// be built without a `Client`, which cannot be built without a database — so a
/// mapper that took an `sdk.Event` directly would put a sqflite instance
/// between every test and the thing worth asserting, which is whether a
/// version-0 invite with no `party_id` still rings.
@immutable
class MatrixCallEvent {
  const MatrixCallEvent({
    required this.type,
    required this.senderId,
    required this.content,
    this.roomId,
    this.sentAt,
  });

  /// The event type, e.g. `m.call.invite`. For an event that arrived encrypted
  /// this is the *decrypted* type: the SDK replaces `m.room.encrypted` before
  /// the event reaches `Client.onCallEvents`.
  final String type;

  final String senderId;
  final Map<String, Object?> content;

  /// Null only for a to-device event that omitted `room_id`, which is a
  /// malformed invite — there is nowhere to answer it.
  final String? roomId;

  /// When the sender sent it, not when we read it. An invite that sat in a
  /// sync backlog for two minutes must not ring, and that decision is
  /// [CallStateMachine]'s to make, so it needs the origin time rather than the
  /// arrival time.
  final DateTime? sentAt;

  /// Reduces one event off `Client.onCallEvents`, or null when it carries
  /// nothing this layer can use.
  ///
  /// Three kinds arrive on that stream and only two are usable:
  ///
  /// - a timeline [sdk.Event], carrying a room and an origin timestamp;
  /// - an [sdk.ToDeviceEvent], carrying its room id inside the content and no
  ///   timestamp at all, so [receivedAt] stands in;
  /// - an [sdk.ToDeviceEventDecryptionError], which is an event we could not
  ///   decrypt. Its `content` is the *encrypted* content, so reading `call_id`
  ///   out of it would produce a signal for a call that does not exist.
  static MatrixCallEvent? fromSdk(
    sdk.BasicEventWithSender event, {
    DateTime? receivedAt,
  }) {
    if (event is sdk.ToDeviceEventDecryptionError) return null;
    // An event still typed as encrypted never got decrypted. Nothing inside it
    // is readable and pretending otherwise turns a key problem into a
    // mysteriously silent call.
    if (event.type == sdk.EventTypes.Encrypted) return null;

    final content = event.content;
    final now = receivedAt ?? DateTime.now();

    if (event is sdk.Event) {
      return MatrixCallEvent(
        type: event.type,
        senderId: event.senderId,
        content: content,
        roomId: event.room.id,
        sentAt: _originTime(event, now),
      );
    }

    return MatrixCallEvent(
      type: event.type,
      senderId: event.senderId,
      content: content,
      roomId: _string(content['room_id']),
      sentAt: now,
    );
  }

  /// When the event was really sent, preferring `unsigned.age` over
  /// `origin_server_ts`.
  ///
  /// The two disagree whenever the phone's clock and the homeserver's do, and
  /// the difference is not academic: `origin_server_ts` is compared against a
  /// *local* `DateTime.now()` to decide whether a 60-second invite has expired,
  /// so a device an hour fast would silently drop every incoming call. `age` is
  /// a duration and carries no clock at all.
  static DateTime _originTime(sdk.Event event, DateTime now) {
    final age = event.unsigned?['age'];
    if (age is int && age >= 0) {
      return now.subtract(Duration(milliseconds: age));
    }
    return event.originServerTs;
  }
}

/// Parses one `m.call.*` event into the input [CallStateMachine] consumes, or
/// null when it is not a signal this build acts on.
///
/// Null covers four cases, all of them ordinary rather than exceptional:
///
/// 1. **Not a 1:1 call event.** `Client.onCallEvents` is fed by a regexp that
///    also matches `m.room.redaction`, `com.famedly.call.*` group-call traffic
///    and `org.matrix.msc3401.*`. None of those belong to a 1:1 call.
/// 2. **Our own echo.** Every event we send comes back down `/sync` in the
///    room's timeline. Feeding our own invite back into the machine would look
///    exactly like the far end calling us.
/// 3. **A shape that cannot be acted on** — no `call_id`, an invite with no
///    offer, a `select_answer` naming nobody.
/// 4. **An event type Weft does not implement**: `m.call.replaces`,
///    `m.call.asserted_identity`, `m.call.sdp_stream_metadata_changed`. The
///    omissions are deliberate and recorded in `weft_call`'s library doc.
///
/// What it deliberately does *not* filter is anything the state machine already
/// decides: an expired invite, an unsupported `version`, an `invitee` naming
/// somebody else. Those are all passed through, because a rule enforced in two
/// places is a rule that can disagree with itself.
CallSignal? parseCallSignal(
  MatrixCallEvent event, {
  required String localUserId,
  required String localPartyId,
}) {
  final content = event.content;
  final callId = _string(content['call_id']);
  if (callId == null) return null;

  final partyId = _string(content['party_id']) ?? '';

  // Our own event, come back down /sync. `party_id` identifies the *device*,
  // so this drops only this device's traffic — another device of the same user
  // is a genuine second party and MSC2746's whole `select_answer` dance exists
  // for it.
  if (event.senderId == localUserId && partyId == localPartyId) return null;

  switch (event.type) {
    case sdk.EventTypes.CallInvite:
      final roomId = event.roomId;
      final sentAt = event.sentAt;
      final offer = _description(content['offer'], SdpType.offer);
      if (roomId == null || sentAt == null || offer == null) return null;
      return CallInviteSignal(
        callId: callId,
        partyId: partyId,
        senderId: event.senderId,
        roomId: roomId,
        offer: offer,
        sentAt: sentAt,
        lifetime: _duration(content['lifetime']) ?? kDefaultInviteLifetime,
        video: sdpOffersVideo(offer.sdp),
        invitee: _string(content['invitee']),
        version: _versionOf(content['version']),
      );

    case sdk.EventTypes.CallAnswer:
      final answer = _description(content['answer'], SdpType.answer);
      if (answer == null) return null;
      return CallAnswerSignal(
        callId: callId,
        partyId: partyId,
        senderId: event.senderId,
        answer: answer,
        video: sdpOffersVideo(answer.sdp),
      );

    case sdk.EventTypes.CallCandidates:
      final candidates = _candidates(content['candidates']);
      if (candidates.isEmpty) return null;
      return CallCandidatesSignal(
        callId: callId,
        partyId: partyId,
        senderId: event.senderId,
        candidates: candidates,
      );

    case sdk.EventTypes.CallSelectAnswer:
      final selected = _string(content['selected_party_id']);
      if (selected == null) return null;
      return CallSelectAnswerSignal(
        callId: callId,
        partyId: partyId,
        senderId: event.senderId,
        selectedPartyId: selected,
      );

    case sdk.EventTypes.CallHangup:
      return CallHangupSignal(
        callId: callId,
        partyId: partyId,
        senderId: event.senderId,
        reason: _string(content['reason']),
      );

    case sdk.EventTypes.CallReject:
      return CallRejectSignal(
        callId: callId,
        partyId: partyId,
        senderId: event.senderId,
        reason: _string(content['reason']),
      );

    case sdk.EventTypes.CallNegotiate:
      // `description` is an offer or an answer depending on who started the
      // renegotiation, so unlike the two above there is no default to fall
      // back on: an unreadable `type` here is unusable.
      final description = _description(content['description'], null);
      if (description == null) return null;
      return CallNegotiateSignal(
        callId: callId,
        partyId: partyId,
        senderId: event.senderId,
        description: description,
        video: sdpOffersVideo(description.sdp),
      );

    default:
      return null;
  }
}

/// The event type one outbound intent goes out as.
String callEventType(SignallingIntent intent) => switch (intent) {
  SendInvite() => sdk.EventTypes.CallInvite,
  SendAnswer() => sdk.EventTypes.CallAnswer,
  SendCandidates() => sdk.EventTypes.CallCandidates,
  SendSelectAnswer() => sdk.EventTypes.CallSelectAnswer,
  SendHangup() => sdk.EventTypes.CallHangup,
  SendReject() => sdk.EventTypes.CallReject,
  SendNegotiate() => sdk.EventTypes.CallNegotiate,
};

/// The event content one outbound intent goes out as.
///
/// [invitee] is the peer's Matrix user id and belongs only on an invite. MSC2746
/// makes it optional and defines its absence as "any member of the room other
/// than the sender" — which in a room with a bridge bot, an integration manager
/// or a second admin means ringing everyone. Weft always names the peer.
Map<String, Object?> callEventContent(
  SignallingIntent intent, {
  String? invitee,
  String version = kVoipProtocolVersion,
}) {
  final base = <String, Object?>{
    'call_id': intent.callId,
    'party_id': intent.partyId,
    'version': version,
  };

  return switch (intent) {
    SendInvite() => {
      ...base,
      'lifetime': intent.lifetime.inMilliseconds,
      'offer': _descriptionJson(intent.offer),
      'invitee': ?invitee,
    },
    SendAnswer() => {...base, 'answer': _descriptionJson(intent.answer)},
    SendCandidates() => {
      ...base,
      'candidates': [
        for (final candidate in intent.candidates) _candidateJson(candidate),
      ],
    },
    SendSelectAnswer() => {
      ...base,
      'selected_party_id': intent.selectedPartyId,
    },
    SendHangup() => {...base, 'reason': intent.reason.wireReason},
    // The Matrix SDK sends `m.call.reject` with no `reason` at all, and
    // MSC2746 defines none. Weft sends one anyway: a call refused because the
    // callee was already on another one is a different sentence to show the
    // caller than a call somebody declined, and there is no other way to tell
    // them apart. An unknown key is ignored by every other client, so the cost
    // of being wrong about this is nil.
    SendReject() => {...base, 'reason': intent.reason.wireReason},
    SendNegotiate() => {
      ...base,
      'lifetime': intent.lifetime.inMilliseconds,
      'description': _descriptionJson(intent.description),
    },
  };
}

/// Whether an SDP blob offers video.
///
/// MSC2746 carries no video flag: whether a call is a video call is a property
/// of the SDP, and every client works it out by looking for a media section. A
/// section with port `0` is a *rejected* one — that is how a video call is
/// downgraded to audio during renegotiation — so counting it would leave the
/// call screen showing a camera button for a stream that no longer exists.
bool sdpOffersVideo(String sdp) {
  for (final line in const LineSplitter().convert(sdp)) {
    if (!line.startsWith('m=video')) continue;
    final port = line.split(' ').elementAtOrNull(1);
    if (port == '0') continue;
    return true;
  }
  return false;
}

/// Where a call event is put on the wire.
///
/// An interface rather than an `sdk.Client` for the reason on
/// [MatrixApiSession]: the whole of the intent-to-wire mapping — which type,
/// which keys, whether a reject carries a reason — is assertable against a
/// recording fake, and none of it needs a homeserver. The one implementation
/// that does is [MatrixCallEventSink.forClient], and it is twelve lines.
abstract class MatrixCallEventSink {
  /// Sends through a live client, encrypting when the room is encrypted.
  const factory MatrixCallEventSink.forClient(sdk.Client client) =
      _ClientCallEventSink;

  Future<void> send({
    required String roomId,
    required String type,
    required Map<String, Object?> content,
  });
}

class _ClientCallEventSink implements MatrixCallEventSink {
  const _ClientCallEventSink(this._client);

  final sdk.Client _client;

  @override
  Future<void> send({
    required String roomId,
    required String type,
    required Map<String, Object?> content,
  }) async {
    final room = _client.getRoomById(roomId);
    if (room == null) {
      throw CallSignallingException(
        'Weft is not in the room this call belongs to ($roomId).',
      );
    }

    // The same three lines `Room._sendContent` and the SDK's own VoIP stack
    // use, rather than `room.sendEvent`, because that one puts a local echo in
    // the timeline: a call places dozens of `m.call.candidates` events and
    // every one of them would appear in the conversation as a pending message.
    //
    // This is also the whole of the encrypted-room story. A call event is an
    // ordinary room event, so it goes through megolm exactly like a message,
    // and the far end's SDK decrypts it before it reaches `onCallEvents`.
    final mustEncrypt = room.encrypted && _client.encryptionEnabled;
    final payload = mustEncrypt
        ? await _client.encryption!.encryptGroupMessagePayload(
            roomId,
            content,
            type: type,
          )
        : content;

    try {
      await _client.sendMessage(
        roomId,
        payload.containsKey('ciphertext') ? sdk.EventTypes.Encrypted : type,
        _client.generateUniqueTransactionId(),
        payload,
      );
    } on Object catch (error) {
      throw CallSignallingException(
        'Could not send $type: $error',
        retryable: true,
      );
    }
  }
}

/// Both directions of a 1:1 call's Matrix signalling.
///
/// Reading is `signalsFrom(client.onCallEvents.stream)`; writing is [send].
/// Neither holds a client of its own — the stream is passed in and the writing
/// goes through [MatrixCallEventSink] — which is what lets the call service be
/// tested against a fake homeserver that is a `StreamController` and a list.
class MatrixCallSignalling {
  MatrixCallSignalling({
    required this.localUserId,
    required this.localPartyId,
    required MatrixCallEventSink sink,
    DateTime Function()? clock,
  }) : _sink = sink,
       _clock = clock ?? DateTime.now;

  /// Builds signalling for a signed-in client.
  ///
  /// `party_id` is the device id, as MSC2746 suggests and every other client
  /// does. It must be stable for the session: a party id that changed mid-call
  /// would look to the far end like a second device answering.
  factory MatrixCallSignalling.forClient(sdk.Client client) {
    final userId = client.userID;
    final deviceId = client.deviceID;
    if (userId == null || deviceId == null) {
      throw const CallSignallingException(
        'You are not signed in, so Weft cannot place or receive calls.',
      );
    }
    return MatrixCallSignalling(
      localUserId: userId,
      localPartyId: deviceId,
      sink: MatrixCallEventSink.forClient(client),
    );
  }

  final String localUserId;

  /// This device's `party_id`, and the value every outbound event is stamped
  /// with by [CallStateMachine].
  final String localPartyId;

  final MatrixCallEventSink _sink;
  final DateTime Function() _clock;

  /// Maps one SDK event, or null when it is not ours to act on.
  CallSignal? read(sdk.BasicEventWithSender event) {
    final reduced = MatrixCallEvent.fromSdk(event, receivedAt: _clock());
    if (reduced == null) return null;
    return parseCallSignal(
      reduced,
      localUserId: localUserId,
      localPartyId: localPartyId,
    );
  }

  /// Turns `Client.onCallEvents` into the machine's inputs.
  ///
  /// The SDK delivers call events in batches because one `/sync` can carry a
  /// whole call's worth. Order within a batch is preserved, which matters: a
  /// batch that holds an answer and then candidates must not deliver the
  /// candidates first, or they are buffered when they did not need to be.
  Stream<CallSignal> signalsFrom(
    Stream<List<sdk.BasicEventWithSender>> events,
  ) {
    return events.expand((batch) => [for (final event in batch) ?read(event)]);
  }

  /// Puts one outbound intent on the wire.
  ///
  /// [roomId] is passed rather than read off the intent because only
  /// [SendInvite] carries one — every later event in a call belongs to the room
  /// the call is already in, and the call service is what knows it.
  Future<void> send(
    SignallingIntent intent, {
    required String roomId,
    String? invitee,
  }) {
    return _sink.send(
      roomId: roomId,
      type: callEventType(intent),
      content: callEventContent(intent, invitee: invitee),
    );
  }
}

// ---------------------------------------------------------------------------
// Defensive parsing. A shape change on the wire should be a dropped event, not
// a cast exception taking the sync loop down with it.
// ---------------------------------------------------------------------------

String? _string(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return value;
}

/// `version` is `"1"` in MSC2746 and the *integer* `0` in the dialect that
/// preceded it, so both shapes are real and both have to normalise to the
/// strings [CallStateMachine.supportedVersions] is written in.
String _versionOf(Object? value) => switch (value) {
  final String version when version.isNotEmpty => version,
  final int version => '$version',
  _ => '0',
};

Duration? _duration(Object? value) =>
    value is int && value > 0 ? Duration(milliseconds: value) : null;

/// Reads an `offer` / `answer` / `description` object.
///
/// [fallback] is the type to assume when the event says nothing, and is null
/// for `m.call.negotiate`, where the description may legitimately be either and
/// guessing wrong turns a renegotiation into a dropped call.
SessionDescription? _description(Object? value, SdpType? fallback) {
  if (value is! Map) return null;
  final sdp = _string(value['sdp']);
  if (sdp == null) return null;

  final rawType = _string(value['type']);
  final type = rawType == null ? fallback : SdpType.fromWire(rawType);
  if (type == null) return null;

  return SessionDescription(type: type, sdp: sdp);
}

Map<String, Object?> _descriptionJson(SessionDescription description) => {
  'type': description.type.wireType,
  'sdp': description.sdp,
};

List<IceCandidate> _candidates(Object? value) {
  if (value is! List) return const [];
  return [
    for (final raw in value)
      if (raw is Map)
        // An empty `candidate` is MSC2746's end-of-candidates marker and must
        // survive: a peer that never learns gathering has finished waits out
        // its own ICE timeout instead of failing over.
        if (raw['candidate'] case final String candidate)
          IceCandidate(
            candidate: candidate,
            sdpMid: _string(raw['sdpMid']),
            sdpMLineIndex: raw['sdpMLineIndex'] is int
                ? raw['sdpMLineIndex']! as int
                : null,
          ),
  ];
}

Map<String, Object?> _candidateJson(IceCandidate candidate) => {
  'candidate': candidate.candidate,
  'sdpMid': ?candidate.sdpMid,
  'sdpMLineIndex': ?candidate.sdpMLineIndex,
};
