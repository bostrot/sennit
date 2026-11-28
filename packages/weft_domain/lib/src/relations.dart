/// The value types a message's relations resolve to.
///
/// These live in `weft_domain` rather than beside the aggregation that produces
/// them, and the reason is a dependency direction that cannot be argued with:
/// `weft_richtext` depends on `weft_domain`, so if [WeftMessage] is to carry a
/// reaction tally or an edit history as fields, those types cannot be owned by
/// `weft_richtext`. The alternative — the message carrying primitive shapes
/// (`Map<String, int>`, parallel lists) and every renderer re-deriving meaning
/// from them — trades one import for three places to get the same derivation
/// wrong.
///
/// So: `weft_domain` owns the *nouns*, `weft_richtext/src/relations.dart` owns
/// the *verbs* (`aggregateReactions`, `applyEdits`, `resolveReplyTarget`).
/// Nothing here knows what a Matrix annotation is.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'message.dart';
import 'network.dart';

/// One emoji's worth of reaction, with everyone who sent it.
///
/// Counts *people*, not events. In a merged chat the same person can react on
/// the WhatsApp leg and on the Signal leg — two annotation events, in two rooms,
/// from two bridge ghosts — and they are one thumbs-up. The dedupe happens in
/// `aggregateReactions`; by the time a tally exists, [senderIds] holds one entry
/// per distinct human.
@immutable
class ReactionTally {
  const ReactionTally({
    required this.key,
    required this.senderIds,
    required this.firstReactedAt,
    this.byLocalUser = false,
    this.localEventId,
  });

  /// The reaction key, already normalised — see `normaliseReactionKey`. `👍`
  /// and `👍️` (the same emoji with a variation selector) arrive as different
  /// strings and tally together under one of them.
  final String key;

  /// One sender id per distinct person, in the order they first reacted.
  ///
  /// Raw ids, not identity keys: the long-press sender list has to resolve
  /// display names, and a unified contact id resolves to a contact, not to the
  /// handle who actually pressed the emoji.
  final List<String> senderIds;

  /// When the first of these reactions landed. The tally's sort key, which is
  /// what keeps a reaction bar from reshuffling under the reader's thumb as
  /// counts change.
  final DateTime firstReactedAt;

  final bool byLocalUser;

  /// The local user's own annotation event, when [byLocalUser].
  ///
  /// Un-reacting is a redaction of *that event*, so the id has to survive
  /// aggregation — there is no way to recover it from the tally otherwise, and
  /// re-querying the timeline for "my reaction with this key" is a race against
  /// the user's second tap.
  final String? localEventId;

  int get count => senderIds.length;

  @override
  bool operator ==(Object other) =>
      other is ReactionTally &&
      other.key == key &&
      other.byLocalUser == byLocalUser &&
      other.localEventId == localEventId &&
      other.firstReactedAt == firstReactedAt &&
      const ListEquality<String>().equals(other.senderIds, senderIds);

  @override
  int get hashCode => Object.hash(
    key,
    byLocalUser,
    localEventId,
    firstReactedAt,
    const ListEquality<String>().hash(senderIds),
  );

  @override
  String toString() =>
      'ReactionTally($key ×$count${byLocalUser ? ', mine' : ''})';
}

/// Whether [key] is a custom emoji: a picture, not a character.
///
/// MSC4027 reactions — Element, Cinny, FluffyChat's image packs — put the
/// picture's `mxc://` URI where the emoji would go. Drawn as text it is a
/// server name and forty random letters, which is what the long-press row
/// showed for a reader who had once tapped someone's custom-emoji chip: the
/// URI went into the recents, from there into the quick row, and wrapped the
/// row round it. Every place that draws a key asks this first.
bool isImageReactionKey(String key) => key.trim().startsWith('mxc://');

/// What stands for an image reaction where only text fits — an inbox line, a
/// notification — when the sender gave it no shortcode.
const String kImageReactionStandIn = '🖼️';

/// One version of a message body, for the edit-history sheet.
@immutable
class EditRecord {
  const EditRecord({
    required this.eventId,
    required this.body,
    required this.timestamp,
    this.formattedBody,
  });

  /// The event this version came from: the original event id for the first
  /// record, the `m.replace` event id for each subsequent one.
  final String eventId;

  final String body;
  final String? formattedBody;

  /// Origin timestamp of the version, so the sheet can show when each edit
  /// happened rather than only that one did.
  final DateTime timestamp;

  @override
  bool operator ==(Object other) =>
      other is EditRecord &&
      other.eventId == eventId &&
      other.body == body &&
      other.formattedBody == formattedBody &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(eventId, body, formattedBody, timestamp);

  @override
  String toString() => 'EditRecord($eventId @ ${timestamp.toIso8601String()})';
}

/// What a reply chip needs to render, resolved or not.
///
/// Two states, and the second is the point. A reply whose target has not been
/// paginated in yet is still a reply: the chip renders as a stub — the tap
/// target is live, because tapping it is how the timeline gets told to go and
/// fetch the thing — rather than silently vanishing and leaving an answer with
/// no visible question.
@immutable
class ReplyPreview {
  const ReplyPreview({
    required this.eventId,
    required this.roomId,
    required this.senderId,
    required this.senderName,
    required this.kind,
    this.network,
    this.body = '',
    this.redacted = false,
  });

  /// The target is known by id and by nothing else — not loaded, or loaded in a
  /// source room this timeline has not reached yet.
  const ReplyPreview.stub(this.eventId)
    : roomId = null,
      senderId = null,
      senderName = null,
      kind = null,
      network = null,
      body = '',
      redacted = false;

  /// The replied-to event. Always present: it is what `m.in_reply_to` named,
  /// and what a tap scrolls to.
  final String eventId;

  /// The source room the target actually lives in, which in a merged chat need
  /// not be the room the reply was sent to.
  final String? roomId;

  final String? senderId;
  final String? senderName;
  final MessageKind? kind;
  final ChatNetwork? network;

  /// One line of the target's text, already collapsed and truncated. Empty for
  /// a redacted target or for a message that is all attachment.
  final String body;

  final bool redacted;

  bool get isStub => roomId == null;

  @override
  bool operator ==(Object other) =>
      other is ReplyPreview &&
      other.eventId == eventId &&
      other.roomId == roomId &&
      other.senderId == senderId &&
      other.senderName == senderName &&
      other.kind == kind &&
      other.network == network &&
      other.body == body &&
      other.redacted == redacted;

  @override
  int get hashCode => Object.hash(
    eventId,
    roomId,
    senderId,
    senderName,
    kind,
    network,
    body,
    redacted,
  );

  @override
  String toString() =>
      isStub ? 'ReplyPreview.stub($eventId)' : 'ReplyPreview($eventId, $body)';
}
