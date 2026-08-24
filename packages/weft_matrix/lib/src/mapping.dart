import 'dart:convert';

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

  // Every spelling the event carries, tried until one resolves: an id that
  // is a repository URL — "github.com/bostrot/mautrix-mattermost" is real —
  // must not eclipse the displayname and bridgebot sitting beside it.
  final protocol = content['protocol'];
  final candidates = <String>[
    if (protocol is String) protocol,
    if (protocol is Map) ...[
      if (protocol['id'] is String) protocol['id'] as String,
      if (protocol['displayname'] is String) protocol['displayname'] as String,
    ],
  ];
  for (final candidate in candidates) {
    final network = ChatNetwork.fromBridgeProtocol(candidate);
    if (network != ChatNetwork.unknown) return network;
  }

  // The bridgebot's localpart still names the network.
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

  // Who *created* the room outranks who is in it: a bridge portal is created
  // by the bridge bot, while a Matrix-native room a bridge merely relays
  // into is created by a person.
  final creator = room.getState(sdk.EventTypes.RoomCreate)?.senderId;
  if (creator != null) {
    final fromCreator = networkFromBridgeBotId(creator);
    if (fromCreator != ChatNetwork.unknown) return fromCreator;
  }

  // Ghost-localpart fallback, by *majority*: one bridged ghost invited into
  // a Matrix room must not re-badge the whole room — that is exactly how a
  // native group with a single relay ghost stopped being a Matrix chat.
  final tally = <ChatNetwork, int>{};
  var others = 0;
  for (final participant in room.getParticipants()) {
    if (participant.id == room.client.userID) continue;
    others++;
    final network = networkFromUserId(participant.id);
    if (network != ChatNetwork.matrix) {
      tally[network] = (tally[network] ?? 0) + 1;
    }
  }
  for (final entry in tally.entries) {
    if (entry.value * 2 > others) return entry.key;
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
  // MSC3381 polls, both the unstable prefix every bridge sends today and the
  // stable one they will. The start event is the bubble; responses and the
  // end event are folded in from its reference relations, so the tally is
  // wherever the timeline has aggregated it to.
  if (event.type == _pollStartUnstable || event.type == _pollStartStable) {
    final poll = _pollFrom(event, timeline: timeline, ownUserId: ownUserId);
    if (poll == null) return null;
    return WeftMessage(
      eventId: event.eventId,
      roomId: event.roomId ?? '',
      network: network,
      senderId: event.senderId,
      senderName: event.senderFromMemoryOrFallback.calcDisplayname(),
      timestamp: event.originServerTs,
      kind: MessageKind.poll,
      isOwn: event.senderId == ownUserId,
      body: poll.question,
      redacted: event.redacted,
      deliveryState: _deliveryFor(event),
      poll: poll,
    );
  }

  // A Weft calendar invitation rides an ordinary message under a custom key,
  // so every other client still shows the text (and the .ics, where one was
  // attached). Weft peers additionally get the negotiation: answers arrive as
  // reference relations and fold onto the invite here.
  // The newest version of the event, because a moved appointment arrives as
  // an m.replace and the block worth reading is the replacement's.
  final display = timeline == null ? event : event.getDisplayEvent(timeline);
  if (display.content[kCalendarInviteKey] is Map ||
      event.content[kCalendarInviteKey] is Map) {
    final invite = _calendarInviteFrom(
      display.content[kCalendarInviteKey] is Map ? display : event,
      relationsOf: event,
      timeline: timeline,
    );
    if (invite != null) {
      return WeftMessage(
        eventId: event.eventId,
        roomId: event.roomId ?? '',
        network: network,
        senderId: event.senderId,
        senderName: event.senderFromMemoryOrFallback.calcDisplayname(),
        timestamp: event.originServerTs,
        kind: MessageKind.event,
        isOwn: event.senderId == ownUserId,
        body: display.text,
        redacted: event.redacted,
        deliveryState: _deliveryFor(event),
        calendarInvite: invite,
      );
    }
  }

  // A call leaves marks in the room, and a conversation that hides them reads
  // as if nothing happened — "someone called" is exactly the kind of event a
  // person scrolls back to find. Invite, hangup and reject are the three that
  // mean something to a reader; answer, candidates and renegotiation are
  // plumbing.
  if (_callEventBodies.containsKey(event.type)) {
    return WeftMessage(
      eventId: event.eventId,
      roomId: event.roomId ?? '',
      network: network,
      senderId: event.senderId,
      senderName: event.senderFromMemoryOrFallback.calcDisplayname(),
      timestamp: event.originServerTs,
      kind: MessageKind.event,
      isOwn: event.senderId == ownUserId,
      body: _callEventBodies[event.type]!,
      redacted: event.redacted,
      deliveryState: _deliveryFor(event),
    );
  }

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

  // An invitation whose custom block a bridge stripped down to the readable
  // line. Rebuilt here so the receiving Weft gets the same card the sender
  // rendered, answers folding in from the local room's relations. Notice too:
  // some bridges echo relayed messages as m.notice.
  if (msgtype == sdk.MessageTypes.Text || msgtype == sdk.MessageTypes.Notice) {
    final bridgedInvite = _bridgedCalendarInviteFrom(
      display,
      relationsOf: event,
      timeline: timeline,
    );
    if (bridgedInvite == null && event.text.contains('📅')) {
      // A calendar-looking body that did not parse. Kept quiet in release
      // builds by assert semantics being irrelevant here — this is a plain
      // trace so a device log can show what a bridge actually delivered.
      // ignore: avoid_print
      print(
        'weft: calendar-looking body did not parse as an invite: '
        '${jsonEncode(event.text)} (msgtype: $msgtype)',
      );
    }
    if (bridgedInvite != null) {
      return WeftMessage(
        eventId: event.eventId,
        roomId: event.roomId ?? '',
        network: network,
        senderId: event.senderId,
        senderName: event.senderFromMemoryOrFallback.calcDisplayname(),
        timestamp: event.originServerTs,
        kind: MessageKind.event,
        isOwn: event.senderId == ownUserId,
        body: display.text,
        redacted: event.redacted,
        deliveryState: _deliveryFor(event),
        calendarInvite: bridgedInvite,
      );
    }
  }

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

/// The call events worth a bubble, and what that bubble says.
const Map<String, String> _callEventBodies = {
  sdk.EventTypes.CallInvite: '📞 Call started',
  sdk.EventTypes.CallHangup: '📞 Call ended',
  sdk.EventTypes.CallReject: '📞 Call declined',
};

const String _pollStartUnstable = 'org.matrix.msc3381.poll.start';
const String _pollStartStable = 'm.poll.start';
const String _pollResponseUnstable = 'org.matrix.msc3381.poll.response';
const String _pollResponseStable = 'm.poll.response';
const String _pollEndUnstable = 'org.matrix.msc3381.poll.end';
const String _pollEndStable = 'm.poll.end';

/// MSC1767 text: `{'org.matrix.msc1767.text': '…'}` or `{'m.text': …}`.
String? _extensibleText(Object? block) {
  if (block is! Map) return null;
  final unstable = block['org.matrix.msc1767.text'];
  if (unstable is String) return unstable;
  final stable = block['m.text'];
  if (stable is String) return stable;
  // m.text may itself be a list of representations.
  if (stable is List) {
    for (final rep in stable) {
      if (rep is Map && rep['body'] is String) return rep['body'] as String;
    }
  }
  return null;
}

/// Parses the start event and folds in whatever responses the timeline holds.
PollData? _pollFrom(
  sdk.Event event, {
  sdk.Timeline? timeline,
  String? ownUserId,
}) {
  final start =
      event.content[_pollStartUnstable] ?? event.content[_pollStartStable];
  if (start is! Map) return null;

  final question = _extensibleText(start['question']) ?? '';
  final rawAnswers = start['answers'];
  if (question.isEmpty || rawAnswers is! List) return null;

  final options = <PollOption>[
    for (final answer in rawAnswers)
      if (answer is Map && answer['id'] is String)
        PollOption(
          id: answer['id'] as String,
          text: _extensibleText(answer) ?? '',
        ),
  ];
  if (options.isEmpty) return null;

  final maxSelections = switch (start['max_selections']) {
    final int n when n > 0 => n,
    _ => 1,
  };

  var ended = false;
  // Latest response per voter wins — MSC3381's rule.
  final latest = <String, sdk.Event>{};
  if (timeline != null) {
    for (final related in event.aggregatedEvents(
      timeline,
      sdk.RelationshipTypes.reference,
    )) {
      if (related.type == _pollEndUnstable || related.type == _pollEndStable) {
        ended = true;
        continue;
      }
      if (related.type != _pollResponseUnstable &&
          related.type != _pollResponseStable) {
        continue;
      }
      final previous = latest[related.senderId];
      if (previous == null ||
          related.originServerTs.isAfter(previous.originServerTs)) {
        latest[related.senderId] = related;
      }
    }
  }

  final validIds = {for (final option in options) option.id};
  final votes = <String, int>{};
  final ownVotes = <String>{};
  for (final entry in latest.entries) {
    final block =
        entry.value.content[_pollResponseUnstable] ??
        entry.value.content[_pollResponseStable];
    if (block is! Map) continue;
    final answers = block['answers'];
    if (answers is! List) continue;
    // Spec: more selections than allowed invalidates the whole response.
    final chosen = answers
        .whereType<String>()
        .where(validIds.contains)
        .take(maxSelections)
        .toList();
    for (final id in chosen) {
      votes[id] = (votes[id] ?? 0) + 1;
      if (entry.key == ownUserId) ownVotes.add(id);
    }
  }

  return PollData(
    question: question,
    options: options,
    votes: votes,
    ownVotes: ownVotes,
    ended: ended,
    maxSelections: maxSelections,
  );
}

/// The content key a Weft calendar invitation rides under.
const String kCalendarInviteKey = 'com.bostrot.weft.calendar';

/// The relation type its answers use.
const String kCalendarResponseType = 'com.bostrot.weft.calendar.response';

/// The human-readable line [sendCalendarInvite] writes into the body — and
/// the only part of an invitation that survives a trip through a bridge.
/// Matching it on the way back in is what makes an invite sent over Signal
/// or WhatsApp interactive for a Weft on the receiving end.
final RegExp bridgedCalendarInvitePattern = RegExp(
  r'^📅 (.+) — (\d{1,2})\.(\d{1,2})\.(\d{4}), (\d{1,2}):(\d{2})$',
);

CalendarInvite? _bridgedCalendarInviteFrom(
  sdk.Event event, {
  sdk.Event? relationsOf,
  sdk.Timeline? timeline,
}) {
  // An event that still carries the custom key takes the native path.
  if (event.content[kCalendarInviteKey] is Map) return null;
  final match = bridgedCalendarInvitePattern.firstMatch(event.text.trim());
  if (match == null) return null;
  final start = DateTime(
    int.parse(match[4]!),
    int.parse(match[3]!),
    int.parse(match[2]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
  return CalendarInvite(
    // The original uid was stripped with the rest of the block; the event id
    // is just as unique and stable within this room.
    uid: 'bridged-${event.eventId}',
    title: match[1]!,
    start: start,
    end: null,
    responses: _calendarResponsesFor(relationsOf ?? event, timeline: timeline),
  );
}

CalendarInvite? _calendarInviteFrom(
  sdk.Event event, {
  sdk.Event? relationsOf,
  sdk.Timeline? timeline,
}) {
  final block = event.content[kCalendarInviteKey];
  if (block is! Map) return null;
  final uid = block['uid'];
  final title = block['title'];
  final start = DateTime.tryParse(block['start'] as String? ?? '');
  if (uid is! String || title is! String || start == null) return null;

  return CalendarInvite(
    uid: uid,
    title: title,
    start: start.toLocal(),
    end: DateTime.tryParse(block['end'] as String? ?? '')?.toLocal(),
    // Answers reference the *original* event id, edits notwithstanding.
    responses: _calendarResponsesFor(relationsOf ?? event, timeline: timeline),
  );
}

List<CalendarResponse> _calendarResponsesFor(
  sdk.Event event, {
  sdk.Timeline? timeline,
}) {
  final responses = <String, CalendarResponse>{};
  if (timeline != null) {
    // Latest answer per person wins, same rule as polls.
    final latest = <String, sdk.Event>{};
    for (final related in event.aggregatedEvents(
      timeline,
      sdk.RelationshipTypes.reference,
    )) {
      if (related.type != kCalendarResponseType) continue;
      final previous = latest[related.senderId];
      if (previous == null ||
          related.originServerTs.isAfter(previous.originServerTs)) {
        latest[related.senderId] = related;
      }
    }
    for (final entry in latest.entries) {
      final reply = switch (entry.value.content['response']) {
        'accept' => CalendarReply.accepted,
        'decline' => CalendarReply.declined,
        'reschedule' => CalendarReply.reschedule,
        _ => null,
      };
      if (reply == null) continue;
      responses[entry.key] = CalendarResponse(
        senderId: entry.key,
        senderName: entry.value.senderFromMemoryOrFallback.calcDisplayname(),
        reply: reply,
        proposedStart: DateTime.tryParse(
          entry.value.content['proposed_start'] as String? ?? '',
        ),
      );
    }
  }
  return responses.values.toList(growable: false);
}
