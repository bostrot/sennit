import 'package:meta/meta.dart';

import 'network.dart';

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
    this.transcript,
    this.replyToEventId,
    this.editedAt,
    this.redacted = false,
    this.deliveryState,
    this.attachmentUrl,
    this.durationMs,
    this.mediaWidth,
    this.mediaHeight,
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

  /// Transcribed text for [MessageKind.voice] / [MessageKind.audio]. Also
  /// indexed for search, which is how voice notes become findable.
  final String? transcript;

  final String? replyToEventId;
  final DateTime? editedAt;
  final bool redacted;
  final DeliveryState? deliveryState;
  final String? attachmentUrl;
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

  WeftMessage copyWith({
    String? body,
    String? transcript,
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
      transcript: transcript ?? this.transcript,
      replyToEventId: replyToEventId,
      editedAt: editedAt ?? this.editedAt,
      redacted: redacted ?? this.redacted,
      deliveryState: deliveryState ?? this.deliveryState,
      attachmentUrl: attachmentUrl,
      durationMs: durationMs,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WeftMessage &&
      other.eventId == eventId &&
      other.roomId == roomId;

  @override
  int get hashCode => Object.hash(eventId, roomId);

  @override
  String toString() =>
      'WeftMessage($eventId in $roomId @ ${timestamp.toIso8601String()})';
}
