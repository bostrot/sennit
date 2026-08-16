import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';

/// State event types bridges use to announce themselves.
const List<String> bridgeStateEventTypes = ['m.bridge', 'uk.half-shot.bridge'];

/// Reads the network out of an `m.bridge` state event's content.
///
/// Shape per MSC2346: `{"protocol": {"id": "whatsapp", "displayname": "..."}}`.
/// Some bridges put a bare string in `protocol` instead, so both are accepted.
ChatNetwork networkFromBridgeStateContent(Map<String, Object?>? content) {
  if (content == null) return ChatNetwork.unknown;

  final protocol = content['protocol'];
  if (protocol is String) return ChatNetwork.fromBridgeProtocol(protocol);
  if (protocol is Map) {
    final id = protocol['id'] ?? protocol['displayname'];
    if (id is String) return ChatNetwork.fromBridgeProtocol(id);
  }

  // Older bridges only set the bridgebot; its localpart still names the network.
  final bridgebot = content['bridgebot'];
  if (bridgebot is String) return networkFromBridgeBotId(bridgebot);

  return ChatNetwork.unknown;
}

/// Resolves the network from a bridge *bot* id, e.g. `@whatsappbot:example.org`.
///
/// Distinct from [networkFromUserId]: a bridgebot localpart usually has no
/// underscore to split on, and instead carries a `bot` suffix. Returns
/// [ChatNetwork.unknown] rather than defaulting to Matrix, because a caller
/// asking about a bridgebot wants to know when the answer is "no idea".
ChatNetwork networkFromBridgeBotId(String userId) {
  var localpart = userId.startsWith('@') ? userId.substring(1) : userId;
  final colon = localpart.indexOf(':');
  if (colon >= 0) localpart = localpart.substring(0, colon);
  if (localpart.startsWith('_')) localpart = localpart.substring(1);

  // `whatsappbot`, `whatsapp_bot` and `whatsapp` all name the same bridge.
  localpart = localpart.replaceFirst(RegExp(r'[-_]?bot$'), '');

  return ChatNetwork.fromBridgeProtocol(localpart);
}

/// Infers the network from a user id.
///
/// Bridge ghosts are namespaced by the bridge — `@whatsapp_4915112345678:hs`,
/// `@_discord_12345:hs`, `@telegram_9876:hs`. A localpart with no underscore is
/// a native Matrix account.
///
/// This is a heuristic and deliberately secondary to [networkFromBridgeStateContent]:
/// a real user who happens to be called `@signal_fan:hs` would be misread, which
/// is why room state wins whenever it exists.
ChatNetwork networkFromUserId(String userId) {
  var localpart = userId.startsWith('@') ? userId.substring(1) : userId;
  final colon = localpart.indexOf(':');
  if (colon >= 0) localpart = localpart.substring(0, colon);

  // Some bridges prefix with an underscore to keep ghosts out of search.
  if (localpart.startsWith('_')) localpart = localpart.substring(1);

  final underscore = localpart.indexOf('_');
  if (underscore <= 0) return ChatNetwork.matrix;

  final candidate = ChatNetwork.fromBridgeProtocol(
    localpart.substring(0, underscore),
  );
  return candidate == ChatNetwork.unknown ? ChatNetwork.matrix : candidate;
}

/// Determines which network a room belongs to.
///
/// Room state first, then the ghost-localpart heuristic across the room's
/// members, then Matrix as the honest default.
ChatNetwork networkForRoom(sdk.Room room) {
  for (final type in bridgeStateEventTypes) {
    final states = room.states[type];
    if (states == null) continue;
    for (final event in states.values) {
      final network = networkFromBridgeStateContent(event.content);
      if (network != ChatNetwork.unknown) return network;
    }
  }

  for (final participant in room.getParticipants()) {
    if (participant.id == room.client.userID) continue;
    final network = networkFromUserId(participant.id);
    if (network != ChatNetwork.matrix) return network;
  }

  return ChatNetwork.matrix;
}

/// Maps a Matrix msgtype onto Weft's content kinds.
MessageKind messageKindFromMsgtype(String? msgtype, {bool isVoice = false}) {
  return switch (msgtype) {
    sdk.MessageTypes.Image => MessageKind.image,
    sdk.MessageTypes.Video => MessageKind.video,
    sdk.MessageTypes.Audio => isVoice ? MessageKind.voice : MessageKind.audio,
    sdk.MessageTypes.File => MessageKind.file,
    sdk.MessageTypes.Location => MessageKind.location,
    sdk.MessageTypes.Sticker => MessageKind.sticker,
    sdk.MessageTypes.Emote || sdk.MessageTypes.Notice => MessageKind.text,
    _ => MessageKind.text,
  };
}

/// Whether an audio event is a voice message rather than a music file.
///
/// MSC3245 marks voice messages with an `org.matrix.msc3245.voice` key; most
/// bridges set it, and the waveform extension is a reliable secondary signal.
bool isVoiceMessage(Map<String, Object?> content) {
  return content.containsKey('org.matrix.msc3245.voice') ||
      content.containsKey('org.matrix.msc1767.audio');
}

/// Converts a Matrix event into Weft's message model.
///
/// Returns null for events that are not conversation content — state changes,
/// reactions, and anything the timeline should not render as a bubble.
WeftMessage? mapEvent(
  sdk.Event event, {
  required ChatNetwork network,
  required String? ownUserId,
  sdk.Timeline? timeline,
}) {
  if (event.type != sdk.EventTypes.Message &&
      event.type != sdk.EventTypes.Sticker &&
      event.type != sdk.EventTypes.Encrypted) {
    return null;
  }

  final content = event.content;
  final msgtype = content['msgtype'] as String?;
  final voice = isVoiceMessage(content);

  return WeftMessage(
    eventId: event.eventId,
    roomId: event.roomId ?? '',
    network: network,
    senderId: event.senderId,
    senderName: event.senderFromMemoryOrFallback.calcDisplayname(),
    timestamp: event.originServerTs,
    kind: event.type == sdk.EventTypes.Sticker
        ? MessageKind.sticker
        : messageKindFromMsgtype(msgtype, isVoice: voice),
    isOwn: event.senderId == ownUserId,
    // `body` already resolves edits and falls back sensibly for media.
    body: event.redacted ? '' : event.body,
    replyToEventId: replyTargetEventId(content),
    // The SDK exposes edits as aggregated replacements, which requires the
    // timeline that holds the aggregations. Without one, report no edit rather
    // than guessing.
    editedAt:
        timeline != null &&
            event.hasAggregatedEvents(timeline, sdk.RelationshipTypes.edit)
        ? event.originServerTs
        : null,
    redacted: event.redacted,
    deliveryState: _deliveryFor(event),
    // Marks the message as carrying a file. The value is not a fetchable URL
    // for encrypted rooms, so the UI asks the repository for bytes instead —
    // this only records that something is there to load.
    attachmentUrl: _hasAttachment(content) ? event.eventId : null,
    durationMs: _durationMs(content),
  );
}

/// Extracts a rich reply's target.
///
/// Replies are *not* an `m.relates_to` rel_type — they are the nested
/// `m.in_reply_to` object, which is why this can't go through the SDK's
/// `relationshipType`.
String? replyTargetEventId(Map<String, Object?> content) {
  final relatesTo = content['m.relates_to'];
  if (relatesTo is! Map) return null;

  final inReplyTo = relatesTo['m.in_reply_to'];
  if (inReplyTo is! Map) return null;

  final eventId = inReplyTo['event_id'];
  return eventId is String && eventId.isNotEmpty ? eventId : null;
}

DeliveryState? _deliveryFor(sdk.Event event) {
  // Matrix has no delivery receipts, only read receipts; `synced` means the
  // server accepted and echoed the event, which is the strongest guarantee
  // available at send time. Read state is applied separately from receipts.
  return switch (event.status) {
    sdk.EventStatus.error => DeliveryState.failed,
    sdk.EventStatus.sending => DeliveryState.sending,
    sdk.EventStatus.sent => DeliveryState.sent,
    sdk.EventStatus.synced => DeliveryState.delivered,
  };
}

/// Whether the event carries a file, plain (`url`) or encrypted (`file`).
bool _hasAttachment(Map<String, Object?> content) =>
    content['url'] is String || content['file'] is Map;

int? _durationMs(Map<String, Object?> content) {
  final info = content['info'];
  if (info is Map && info['duration'] is num) {
    return (info['duration'] as num).round();
  }
  final audio = content['org.matrix.msc1767.audio'];
  if (audio is Map && audio['duration'] is num) {
    return (audio['duration'] as num).round();
  }
  return null;
}
