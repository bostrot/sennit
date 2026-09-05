import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'calendar_invite.dart';
import 'network.dart';
import 'poll.dart';
import 'relations.dart';

/// What kind of content a message carries. Drives rendering and, for
/// [MessageKind.audio], whether transcription applies.
enum MessageKind {
  text,
  image,
  video,
  audio,
  voice,
  file,
  location,
  sticker,
  poll,
  event,
}

/// Delivery state for an outgoing message.
///
/// Five states, and the ordering below is the one the ticks draw: **one tick
/// sent, two ticks delivered, two blue ticks read**, with [sending] before all
/// of them and [failed] outside the sequence entirely.
///
/// The vocabulary is a decade of WhatsApp and is not Braid's to reinvent. What
/// *is* Braid's is being honest about it — see [resolveDeliveryState], which
/// exists because half the networks here cannot report the top of the scale and
/// a tick that claims a message was read when nobody knows is worse than no tick
/// at all.
enum DeliveryState {
  sending,
  sent,
  delivered,
  read,
  failed;

  /// How far along the sequence this is, for comparing two states.
  ///
  /// [failed] is deliberately below [sending]: it is not a stage of delivery but
  /// the absence of one, and ranking it above `sent` would let a cap "raise" a
  /// failure into a success.
  int get _rank => switch (this) {
    DeliveryState.failed => -1,
    DeliveryState.sending => 0,
    DeliveryState.sent => 1,
    DeliveryState.delivered => 2,
    DeliveryState.read => 3,
  };

  /// Whether this claims at least as much as [other].
  bool atLeast(DeliveryState other) => _rank >= other._rank;
}

/// The strongest state [network] is able to report honestly.
///
/// Not every network has the whole scale, and the ones that do not are not
/// broken — they simply never say the thing. SMS carries a real delivery report
/// and has **no read receipts at all**, so a message on it can be delivered and
/// can never be read; `smsDeliveryState` in `weft_sms` says the same from the
/// other side, and this is the rule the renderer applies so the two cannot
/// disagree. Email is the same shape for the same reason.
///
/// A ceiling rather than a capability list because the question at the bubble is
/// always "how far can this honestly have got", and the answer composes: the
/// weakest ceiling among a merged chat's legs is the one that applies to a
/// message on that leg.
DeliveryState deliveryCeilingFor(ChatNetwork network) => switch (network) {
  ChatNetwork.sms || ChatNetwork.email => DeliveryState.delivered,
  _ => DeliveryState.read,
};

/// What the ticks under an outgoing message should actually say.
///
/// One function rather than a chain of conditions at the bubble, because every
/// one of the rules below is a way of *not* claiming more than is known, and a
/// rule that lives at a call site is a rule the next call site will not have.
///
/// [reported] is what the transport said — for Matrix, the server having echoed
/// the event, which is as strong a guarantee as exists at send time and stops at
/// [DeliveryState.delivered]. Read state is never reported: it is derived from
/// receipts, which is what [readerCount] and [peerCount] are for.
///
/// **The group semantic is *everyone*.** [DeliveryState.read] is returned only
/// when [readerCount] covers every other participant, matching WhatsApp's blue
/// ticks — a group where one person of nine has opened the message is not a
/// message that has been read, and a client that said so would make the mark
/// useless in exactly the conversations it is most looked at. A null
/// [peerCount] means the membership is not known, and the honest answer there is
/// to stop at delivered rather than to guess with the receipts in hand: one
/// receipt out of nine looks identical to one out of one.
///
/// **A message can only rise to what the network can say.** See
/// [deliveryCeilingFor]. This is applied last, so a cap can never turn a
/// [DeliveryState.failed] into a success.
///
/// **Receipts disabled is not the same as nothing read.** With
/// [receiptsEnabled] false the user is not sending public receipts, most bridges
/// stop relaying the remote network's in return, and the honest state is
/// [DeliveryState.delivered] — *unknown*, worded as such by the UI — rather than
/// a permanent two grey ticks that read as "they have not looked at it".
DeliveryState? resolveDeliveryState({
  required DeliveryState? reported,
  required ChatNetwork network,
  int readerCount = 0,
  int? peerCount,
  bool receiptsEnabled = true,
}) {
  if (reported == null) return null;
  // Not a stage of delivery, and nothing below may promote it.
  if (reported == DeliveryState.failed) return DeliveryState.failed;

  final ceiling = deliveryCeilingFor(network);
  var state = reported;

  final readable =
      receiptsEnabled &&
      ceiling.atLeast(DeliveryState.read) &&
      state.atLeast(DeliveryState.delivered) &&
      peerCount != null &&
      peerCount > 0 &&
      readerCount >= peerCount;
  if (readable) state = DeliveryState.read;

  return state.atLeast(ceiling) ? ceiling : state;
}

/// Whether the ticks under [state] are the whole truth.
///
/// False when the user has turned read receipts off, which is the one case where
/// two grey ticks mean "we are not being told" rather than "they have not looked
/// at it". The bubble says so in words rather than leaving a mark the reader
/// would reasonably misread — the setting is theirs and they can change it, but
/// only if they know it is what they are looking at.
bool deliveryStateIsComplete({
  required DeliveryState? state,
  required ChatNetwork network,
  required bool receiptsEnabled,
}) {
  if (state == null || state == DeliveryState.failed) return true;
  if (!deliveryCeilingFor(network).atLeast(DeliveryState.read)) return true;
  return receiptsEnabled || state != DeliveryState.delivered;
}

/// A single message, normalised away from Matrix event shapes.
///
/// The merged timeline orders on [timestamp] with [eventId] and [roomId] as
/// tie-breakers, which is why all three are required and immutable.
@immutable
class WeftMessage {
  const WeftMessage({
    required this.eventId,
    required this.roomId,
    required this.network,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
    required this.kind,
    required this.isOwn,
    this.isAutoReply = false,
    this.body = '',
    this.formattedBody,
    this.transcript,
    this.replyToEventId,
    this.replyPreview,
    this.threadRootId,
    this.threadName,
    this.reactions = const [],
    this.editHistory = const [],
    this.editedAt,
    this.redacted = false,
    this.deliveryState,
    this.attachmentUrl,
    this.attachmentName,
    this.geoUri,
    this.poll,
    this.calendarInvite,
    this.durationMs,
    this.mediaWidth,
    this.mediaHeight,
    this.mediaSizeBytes,
  });

  final String eventId;
  final String roomId;
  final ChatNetwork network;
  final String senderId;
  final String senderName;

  /// Origin timestamp. For bridged messages this is the remote network's own
  /// send time, which is what makes cross-network interleaving meaningful.
  final DateTime timestamp;

  final MessageKind kind;
  final bool isOwn;

  /// Whether a machine wrote this rather than a person.
  ///
  /// True for a Braid auto-reply — the sender's or the user's own — read from
  /// the `com.bostrot.weft.auto_reply` key the sender puts on the event.
  /// Carried on the message for two consumers: the bubble, which says so rather
  /// than letting the user mistake their model's words for their own six months
  /// later, and `shouldReply` in `weft_autoreply`, which refuses to answer one.
  ///
  /// **False is not "a person wrote this".** It is "nothing here says
  /// otherwise", and a custom event key survives no bridge: the same reply
  /// relayed to WhatsApp comes back with the flag gone. That is why the loop
  /// guard that actually holds is a hard cap per conversation rather than this
  /// field.
  final bool isAutoReply;

  /// Plain-text body, already stripped of formatting. Indexed for search.
  final String body;

  /// The sender's `org.matrix.custom.html` body, exactly as it arrived — and
  /// therefore **not** sanitised. Null when the message was sent as plain text,
  /// which is most of them.
  ///
  /// Stored raw rather than pre-parsed for two reasons. `weft_domain` has no
  /// parser and must not grow one: it is the vocabulary every other package
  /// shares, and a package that parsed HTML could not stay Flutter-free *and*
  /// storage-free for long. And the same string feeds three consumers — the
  /// bubble, the search index's plain-text projection, and a notification
  /// body — each of which parses at its own edge through the one allowlist in
  /// `weft_richtext`'s `parseFormattedBody`. Anything reading this field
  /// directly into a renderer is a bug: that allowlist is the security
  /// boundary, and this is untrusted text from whatever client or bridge sent
  /// it.
  final String? formattedBody;

  /// Transcribed text for [MessageKind.voice] / [MessageKind.audio]. Also
  /// indexed for search, which is how voice notes become findable.
  final String? transcript;

  final String? replyToEventId;

  /// What [replyToEventId] resolved to, or null when nothing has resolved it.
  ///
  /// Null is *not* "this is not a reply" — that is [replyToEventId] being null.
  /// A mapper that can see only one room of a merged conversation leaves this
  /// null for a target it could not find, so the layer above can search the
  /// other legs before falling back to [ReplyPreview.stub]. Resolving to a stub
  /// too early would hide a target that is on screen two bubbles up.
  final ReplyPreview? replyPreview;

  /// The event this message hangs off as a thread reply — the `m.thread`
  /// relation's target. Null for the overwhelming majority of messages, and for
  /// the thread's own root.
  ///
  /// Separate from [replyToEventId], and the separation is load-bearing. Almost
  /// every thread reply *also* carries an `m.in_reply_to` — the spec's own
  /// fallback, so that a client with no thread support renders the exchange as
  /// a chain of replies rather than losing it — and reading the reply fallback
  /// as a thread relation would put every ordinary reply in a thread of its own.
  /// The two are read from different places in `m.relates_to` for exactly that
  /// reason: `rel_type` names the thread, the nested `m.in_reply_to` names the
  /// reply.
  ///
  /// A root message does not know it is one. Whether an event has a thread
  /// hanging off it is a property of the *other* events in the room, which is
  /// why it is answered by `groupThreads` over a whole timeline rather than by a
  /// field here that no single event could fill in.
  final String? threadRootId;

  /// Whether this message is a reply inside a thread rather than a room-level
  /// message. The flat timeline hides these behind the root's indicator.
  bool get isThreadReply => threadRootId != null;

  /// The name of the thread this message belongs to, when the bridge said so.
  ///
  /// Carried per message rather than only on the root because the bridges do not
  /// agree about where to put it: some stamp a Telegram forum topic's name onto
  /// the topic's opening event, others onto every message in the topic. Reading
  /// it from wherever it turns up means one field answers both, and
  /// `groupThreads` prefers the root's when there is one.
  ///
  /// Null for a Matrix thread, which has no name — only the message it hangs
  /// off. That is not a gap to fill in with a placeholder: the root's own words
  /// are what a Matrix client shows, and they are usually better than a name
  /// would have been.
  final String? threadName;

  /// Reactions on this message, one tally per key, each already collapsed to
  /// one entry per person. Empty for the overwhelming majority of messages.
  ///
  /// Produced by `aggregateReactions` in `weft_richtext`, never assembled by
  /// hand: counting annotation *events* renders one person who reacted on two
  /// legs of a merged chat as two.
  final List<ReactionTally> reactions;

  /// Every version of this message, oldest first and ending with the one [body]
  /// now shows, or empty when it was never edited.
  ///
  /// Carried on the message because the history sheet opens from the bubble and
  /// nothing else has the versions: the SDK resolves an edit by replacing the
  /// content it hands over, so the words that were replaced exist only in the
  /// replacement chain this list preserves.
  final List<EditRecord> editHistory;

  final DateTime? editedAt;
  final bool redacted;
  final DeliveryState? deliveryState;
  final String? attachmentUrl;

  /// The attachment's name on disk, when the sender said so *separately* from
  /// [body] — the MSC2530 `filename` key.
  ///
  /// Its presence is what makes [body] unambiguous, and that is the whole point
  /// of carrying it. Without a `filename`, `body` is the name for a plain
  /// attachment and the caption for a captioned one, and nothing in the event
  /// distinguishes them: `attachmentCaption` has to guess with a heuristic, and
  /// the guess is wrong in both directions — "final.report" under a photo is a
  /// real caption read as a name, and a name like `at the beach` (no extension,
  /// spaces, entirely legal on every filesystem the picker can reach) is a name
  /// read as a caption and printed under the picture.
  ///
  /// Non-null therefore means exactly one thing: **[body] is a caption**. Null
  /// means the sender did not say, not that there is no name — the heuristic is
  /// still the best available answer there, and still applies.
  final String? attachmentName;

  /// `geo:` URI of an [MessageKind.location] message, verbatim from the event.
  final String? geoUri;

  /// The aggregated poll, for [MessageKind.poll] messages.
  final PollData? poll;

  /// A calendar entry proposed by this message, answers folded in.
  final CalendarInvite? calendarInvite;
  final int? durationMs;

  /// Pixel size of the attached image or video, when the sender announced it.
  ///
  /// Carried on the message rather than derived from the bytes because the
  /// bubble has to reserve the right shape *before* the attachment has been
  /// downloaded — an encrypted photo takes a round trip and a decrypt to
  /// measure, and laying out a square placeholder that becomes a 16:9 photo
  /// reflows the whole timeline under the reader's thumb. Null is normal and
  /// not an error: plenty of clients omit `info.w`/`info.h`, and Weft's own
  /// sender omits them for a video whose header could not be probed.
  final int? mediaWidth;
  final int? mediaHeight;

  /// Length of the attached file in bytes, as the sender announced it.
  ///
  /// The one number a file bubble needs and cannot work out for itself: the
  /// bytes are not downloaded until the user asks for them, and the whole point
  /// of showing "18.4 MB" beside a name is to let them decide *before* that
  /// happens. Null where the sender omitted `info.size`, which is common enough
  /// that the bubble simply shows no size rather than a zero.
  final int? mediaSizeBytes;

  /// Aspect ratio of the attachment, when both dimensions are known.
  double? get mediaAspectRatio {
    final w = mediaWidth;
    final h = mediaHeight;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }

  bool get isEdited => editedAt != null;
  bool get canTranscribe =>
      (kind == MessageKind.voice || kind == MessageKind.audio) && !redacted;

  /// Text used for search indexing: body plus transcript, so a query matches
  /// spoken words as readily as typed ones.
  String get searchableText {
    final t = transcript;
    if (t == null || t.isEmpty) return body;
    if (body.isEmpty) return t;
    return '$body\n$t';
  }

  /// Copies with the fields that can change after an event has been mapped.
  ///
  /// Every field is re-listed by hand below, including the ones this signature
  /// does not offer: **a new field that is not added to the constructor call is
  /// silently dropped on the first copy**, and the copies are not rare — a
  /// finished transcription, a resolved reply, an applied edit all go through
  /// here.
  ///
  /// [formattedBody] and [replyPreview] take a sentinel rather than the `??`
  /// the other parameters use, because for these two null is a value a caller
  /// genuinely means: an edit that drops formatting must clear the old HTML, or
  /// the bubble renders the previous message's markup around the new words.
  WeftMessage copyWith({
    String? geoUri,
    PollData? poll,
    CalendarInvite? calendarInvite,
    String? body,
    Object? formattedBody = _unchanged,
    String? transcript,
    Object? replyPreview = _unchanged,
    List<ReactionTally>? reactions,
    List<EditRecord>? editHistory,
    DateTime? editedAt,
    bool? redacted,
    DeliveryState? deliveryState,
  }) {
    return WeftMessage(
      eventId: eventId,
      roomId: roomId,
      network: network,
      senderId: senderId,
      senderName: senderName,
      timestamp: timestamp,
      kind: kind,
      isOwn: isOwn,
      isAutoReply: isAutoReply,
      body: body ?? this.body,
      formattedBody: identical(formattedBody, _unchanged)
          ? this.formattedBody
          : formattedBody as String?,
      transcript: transcript ?? this.transcript,
      replyToEventId: replyToEventId,
      replyPreview: identical(replyPreview, _unchanged)
          ? this.replyPreview
          : replyPreview as ReplyPreview?,
      threadRootId: threadRootId,
      threadName: threadName,
      reactions: reactions ?? this.reactions,
      editHistory: editHistory ?? this.editHistory,
      editedAt: editedAt ?? this.editedAt,
      redacted: redacted ?? this.redacted,
      deliveryState: deliveryState ?? this.deliveryState,
      attachmentUrl: attachmentUrl,
      attachmentName: attachmentName,
      geoUri: geoUri ?? this.geoUri,
      poll: poll ?? this.poll,
      calendarInvite: calendarInvite ?? this.calendarInvite,
      durationMs: durationMs,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
      mediaSizeBytes: mediaSizeBytes,
    );
  }

  static const Object _unchanged = Object();

  /// Identity is `(eventId, roomId)` — the pair that names one event, and the
  /// pair the merge tie-break orders on. Everything after it is what can change
  /// *for that same event*: a body that was edited, a transcript that arrived,
  /// a reaction that landed.
  ///
  /// Both halves matter. Without the identity pair, two different messages
  /// carrying the same text would compare equal. Without the mutable half, a
  /// bubble that has just gained a reaction compares equal to the one without
  /// it, and any list diff or `select` built on that never redraws — the
  /// reaction is in the model and invisible on screen, which is the worst of
  /// the three outcomes because nothing looks broken.
  @override
  bool operator ==(Object other) =>
      other is WeftMessage &&
      other.eventId == eventId &&
      other.roomId == roomId &&
      other.body == body &&
      other.formattedBody == formattedBody &&
      other.transcript == transcript &&
      other.editedAt == editedAt &&
      other.redacted == redacted &&
      other.deliveryState == deliveryState &&
      other.replyPreview == replyPreview &&
      const ListEquality<ReactionTally>().equals(other.reactions, reactions) &&
      const ListEquality<EditRecord>().equals(other.editHistory, editHistory);

  @override
  int get hashCode => Object.hash(
    eventId,
    roomId,
    body,
    formattedBody,
    transcript,
    editedAt,
    redacted,
    deliveryState,
    replyPreview,
    const ListEquality<ReactionTally>().hash(reactions),
    const ListEquality<EditRecord>().hash(editHistory),
  );

  @override
  String toString() =>
      'WeftMessage($eventId in $roomId @ ${timestamp.toIso8601String()})';
}
