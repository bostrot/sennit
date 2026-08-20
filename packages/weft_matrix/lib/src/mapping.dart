import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

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
/// reactions, replacements, and anything else the timeline should not render as
/// a bubble of its own.
///
/// Relations are folded *in* rather than rendered beside: a message carries the
/// reactions annotating it, the versions replacing it, and the id it answers.
/// All three need [timeline], because the SDK holds relations in the timeline's
/// aggregation tree rather than on the event — with no timeline this maps the
/// event exactly as it arrived, which is right for the inbox preview and wrong
/// for a bubble.
///
/// [resolveSender] decides which annotations are the same person; see
/// [MergedIdentityResolver]. The default treats every sender as their own
/// person, which is correct for an unmerged chat and for the inbox.
WeftMessage? mapEvent(
  sdk.Event event, {
  required ChatNetwork network,
  required String? ownUserId,
  sdk.Timeline? timeline,
  MergedIdentityResolver resolveSender = senderIsIdentity,
}) {
  if (event.type != sdk.EventTypes.Message &&
      event.type != sdk.EventTypes.Sticker &&
      event.type != sdk.EventTypes.Encrypted) {
    return null;
  }

  final content = event.content;

  // A replacement is a relation wearing a message's clothes: same type, same
  // msgtype, a body of `* the new text` for clients that do not understand
  // edits. Rendering it is how an edited message becomes two bubbles, the
  // second one starting with a star.
  if (editTargetEventId(content) != null) return null;

  final msgtype = content['msgtype'] as String?;
  final voice = isVoiceMessage(content);

  final message = WeftMessage(
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
    // The event as sent. Edits are applied below, from the replacement chain,
    // rather than trusted from here: the body is the *original* text until
    // someone asks the timeline for the display event.
    //
    // `event.text`, NOT `event.body`: the SDK's `body` getter substitutes
    // 'Unknown message format of type "m.room.message"' when the content has
    // no body key — which perfectly legal bridged media (captionless photos,
    // albums) sometimes does, and which then rendered as that sentence in the
    // middle of a conversation.
    body: event.redacted
        ? ''
        : (event.text.isNotEmpty ? event.text : _fallbackBody(content)),
    formattedBody: event.redacted ? null : formattedBodyOf(content),
    replyToEventId: replyTargetEventId(content),
    redacted: event.redacted,
    deliveryState: _deliveryFor(event),
    // Marks the message as carrying a file. The value is not a fetchable URL
    // for encrypted rooms, so the UI asks the repository for bytes instead —
    // this only records that something is there to load.
    attachmentUrl: _hasAttachment(content) ? event.eventId : null,
    geoUri: content['geo_uri'] is String ? content['geo_uri'] as String : null,
    durationMs: _durationMs(content),
    mediaWidth: _positiveInfoInt(content, 'w'),
    mediaHeight: _positiveInfoInt(content, 'h'),
    mediaSizeBytes: _positiveInfoInt(content, 'size'),
  );

  // A redacted event has no content left to relate to. Its edits and its
  // reactions are gone from the server too, and showing a tally over "message
  // deleted" would be showing a count of something nobody can read.
  if (timeline == null || event.redacted) return message;

  final resolution = applyEdits(editsFor(event, timeline), message);
  final reactions = aggregateReactions(
    events: reactionsFor(event, timeline),
    resolveSender: resolveSender,
    localUserId: ownUserId,
  );
  if (resolution.history.isEmpty && reactions.isEmpty) return message;

  return resolution.message.copyWith(
    editHistory: resolution.history,
    reactions: reactions,
  );
}

/// The sender's HTML body, when they sent one in the format Matrix defines.
///
/// Guarded on `format` rather than on the key's presence: `formatted_body`
/// without `org.matrix.custom.html` beside it is a body in some *other* format,
/// and handing it to an HTML parser would be reading a document in a language
/// nobody claimed it was written in. Empty is treated as absent, since a sender
/// that set the key to `""` meant no formatting.
String? formattedBodyOf(Map<String, Object?> content) {
  if (content['format'] != 'org.matrix.custom.html') return null;
  final formatted = content['formatted_body'];
  return formatted is String && formatted.isNotEmpty ? formatted : null;
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

/// The event an `m.replace` replaces, or null when this is not a replacement.
///
/// The mirror of [replyTargetEventId], and the two must not be confused: a
/// reply quotes another message, a replacement *becomes* one. The rel_type is
/// what tells them apart, and both can be absent from the same relation block.
String? editTargetEventId(Map<String, Object?> content) {
  final relatesTo = content['m.relates_to'];
  if (relatesTo is! Map) return null;
  if (relatesTo['rel_type'] != sdk.RelationshipTypes.edit) return null;

  final eventId = relatesTo['event_id'];
  return eventId is String && eventId.isNotEmpty ? eventId : null;
}

/// The annotation key an `m.reaction` carries, or null when it carries none.
String? annotationKey(Map<String, Object?> content) {
  final relatesTo = content['m.relates_to'];
  if (relatesTo is! Map) return null;
  if (relatesTo['rel_type'] != sdk.RelationshipTypes.reaction) return null;

  final key = relatesTo['key'];
  return key is String && key.isNotEmpty ? key : null;
}

/// Maps an `m.reaction` event, or null for anything that is not one.
///
/// Null for a redacted annotation too, and by construction rather than by a
/// check: redaction strips `m.relates_to`, so an un-reacted reaction has no
/// target and no key left to read. That is the behaviour the tally wants —
/// counting it would leave a chip standing for a reaction the sender withdrew.
ReactionEvent? mapReaction(sdk.Event event) {
  if (event.type != sdk.EventTypes.Reaction) return null;

  final content = event.content;
  final relatesTo = content['m.relates_to'];
  if (relatesTo is! Map) return null;

  final targetId = relatesTo['event_id'];
  final key = annotationKey(content);
  if (targetId is! String || targetId.isEmpty || key == null) return null;

  return ReactionEvent(
    eventId: event.eventId,
    roomId: event.roomId ?? '',
    senderId: event.senderId,
    targetEventId: targetId,
    key: key,
    timestamp: event.originServerTs,
  );
}

/// Maps an `m.replace` event, or null for anything that is not one.
///
/// The replacement text comes from `m.new_content`, which is the authoritative
/// copy; the top-level `body` is the fallback the spec has senders prepend `* `
/// to so that clients which ignore edits still show something readable. Falling
/// back to it means stripping that star, or every edit in the history sheet
/// reads as a bullet list.
EditEvent? mapEdit(sdk.Event event) {
  if (event.type != sdk.EventTypes.Message) return null;

  final content = event.content;
  final targetId = editTargetEventId(content);
  if (targetId == null) return null;

  final newContent = content['m.new_content'];
  final replacement = newContent is Map<String, Object?> ? newContent : null;

  final body = replacement?['body'];
  return EditEvent(
    eventId: event.eventId,
    roomId: event.roomId ?? '',
    senderId: event.senderId,
    targetEventId: targetId,
    body: body is String ? body : _withoutEditFallback(event.body),
    formattedBody: replacement == null
        ? null
        : formattedBodyOf(replacement.cast<String, Object?>()),
    timestamp: event.originServerTs,
  );
}

/// Removes the `* ` a sender prepends to an edit's fallback body.
///
/// Only the first one, and only when it is followed by something: a message
/// that genuinely reads `* ` is a message about a bullet.
String _withoutEditFallback(String body) =>
    body.length > 2 && body.startsWith('* ') ? body.substring(2) : body;

/// The annotations [timeline] has aggregated against [event].
///
/// Read off the aggregation tree rather than by scanning the timeline, because
/// that tree is where the SDK removes a redacted annotation — a scan would keep
/// counting reactions their senders have taken back.
List<ReactionEvent> reactionsFor(sdk.Event event, sdk.Timeline timeline) =>
    event
        .aggregatedEvents(timeline, sdk.RelationshipTypes.reaction)
        .map(mapReaction)
        .whereType<ReactionEvent>()
        .toList(growable: false);

/// The replacements [timeline] has aggregated against [event].
///
/// Unfiltered by sender: `applyEdits` is what rejects an edit from anyone other
/// than the original author, and it reports what it rejected rather than
/// swallowing it, which is how a bridge attributing edits wrongly becomes
/// visible instead of silent.
List<EditEvent> editsFor(sdk.Event event, sdk.Timeline timeline) => event
    .aggregatedEvents(timeline, sdk.RelationshipTypes.edit)
    .map(mapEdit)
    .whereType<EditEvent>()
    .toList(growable: false);

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

/// What to say for a message with no text and no top-level file.
///
/// A captionless photo says nothing — the bubble draws the picture. Anything
/// else is a shape this client does not know; it gets a quiet placeholder and
/// one diagnostic line naming the content *keys* (never the values — this is
/// message content) so the next report can say what the bridge actually sent.
String _fallbackBody(Map<String, Object?> content) {
  if (_hasAttachment(content)) return '';

  // Bridged albums: a list of media objects under a vendor key
  // (`com.beeper.gallery.images` and friends). Named rather than fetched —
  // per-part download needs upstream SDK support — but "album of 4 photos"
  // beats a sentence about message formats.
  for (final entry in content.entries) {
    final value = entry.value;
    if (value is List && value.isNotEmpty) {
      final first = value.first;
      if (first is Map && (first['url'] is String || first['file'] is Map)) {
        return value.length == 1
            ? 'A photo album'
            : 'A photo album of ${value.length} images';
      }
    }
  }

  assert(() {
    // ignore: avoid_print
    print(
      'weft: unrenderable m.room.message, '
      'msgtype=${content['msgtype']}, keys=${content.keys.toList()}',
    );
    return true;
  }());
  final msgtype = content['msgtype'];
  return msgtype is String && msgtype.isNotEmpty
      ? 'Unsupported message ($msgtype)'
      : 'Unsupported message';
}

/// Reads a positive integer out of `info` — `w`, `h` or `size`, which is where
/// a sender announces the shape and the length of an attachment.
///
/// Defensive about the value's type and sign because `info` is whatever the
/// sending client wrote: a string `"1600"`, a float, a zero from a client that
/// fills the key in whether or not it knows the answer. Anything that is not a
/// usable positive integer comes back null, which the bubble already handles as
/// "unknown" — a zero would otherwise become an aspect ratio nobody can divide
/// by, or a file that claims to be empty.
int? _positiveInfoInt(Map<String, Object?> content, String key) {
  final info = content['info'];
  if (info is! Map) return null;
  final value = info[key];
  if (value is! num) return null;
  final pixels = value.round();
  return pixels > 0 ? pixels : null;
}

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
