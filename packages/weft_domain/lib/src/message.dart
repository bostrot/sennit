import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'network.dart';
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
enum DeliveryState { sending, sent, delivered, read, failed }

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
    this.body = '',
    this.formattedBody,
    this.transcript,
    this.replyToEventId,
    this.replyPreview,
    this.reactions = const [],
    this.editHistory = const [],
    this.editedAt,
    this.redacted = false,
    this.deliveryState,
    this.attachmentUrl,
    this.geoUri,
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

  /// `geo:` URI of an [MessageKind.location] message, verbatim from the event.
  final String? geoUri;
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
      body: body ?? this.body,
      formattedBody: identical(formattedBody, _unchanged)
          ? this.formattedBody
          : formattedBody as String?,
      transcript: transcript ?? this.transcript,
      replyToEventId: replyToEventId,
      replyPreview: identical(replyPreview, _unchanged)
          ? this.replyPreview
          : replyPreview as ReplyPreview?,
      reactions: reactions ?? this.reactions,
      editHistory: editHistory ?? this.editHistory,
      editedAt: editedAt ?? this.editedAt,
      redacted: redacted ?? this.redacted,
      deliveryState: deliveryState ?? this.deliveryState,
      attachmentUrl: attachmentUrl,
      geoUri: geoUri ?? this.geoUri,
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
