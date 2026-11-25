import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'detect.dart';

/// How much of a photo goes out when it is sent.
enum MediaQuality {
  /// The file as it is — scaled down only when the network or the homeserver
  /// would refuse it otherwise.
  original('original', null, 92),

  /// A longest edge of 2560 pixels: sharp on any screen, a fraction of a
  /// camera original's size.
  high('high', 2560, 85),

  /// A longest edge of 1280 pixels, for a metered connection.
  dataSaver('data_saver', 1280, 72);

  const MediaQuality(this.id, this.longestEdge, this.jpegQuality);

  /// Stable identifier, as stored in the settings table.
  final String id;

  /// The longest edge a photo is scaled to fit, or null for no cap.
  final int? longestEdge;

  /// The JPEG quality a re-encoded photo starts at.
  final int jpegQuality;

  /// The stored [id] back as a quality; [original] for anything unknown, which
  /// is what Sennit always did.
  static MediaQuality fromId(String? id) => MediaQuality.values.firstWhere(
    (q) => q.id == id,
    orElse: () => MediaQuality.original,
  );
}

/// The largest photo [network] takes, in bytes, or null when the homeserver's
/// own limit is the only one that matters.
///
/// The bridge has to upload the file again on the other side, and when it is
/// too large for that network the message fails over there — after Sennit has
/// shown it as sent.
int? mediaByteLimitFor(ChatNetwork network) => switch (network) {
  ChatNetwork.twitter => 5 * _mb,
  ChatNetwork.instagram => 8 * _mb,
  ChatNetwork.discord => 10 * _mb,
  ChatNetwork.telegram => 10 * _mb,
  ChatNetwork.whatsapp => 16 * _mb,
  ChatNetwork.messenger => 25 * _mb,
  _ => null,
};

const int _mb = 1024 * 1024;

/// Still-image formats a photo can be re-encoded from. GIF stays out — it is
/// usually animated, and a still JPEG of its first frame is not what was sent
/// — and so does HEIC, which there is no pure-Dart decoder for.
const Set<String> _shrinkable = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/bmp',
};

/// What to do to a photo before it is uploaded.
@immutable
class ShrinkPlan {
  const ShrinkPlan({
    required this.longestEdge,
    required this.jpegQuality,
    required this.maxBytes,
  });

  /// The longest edge to fit, or null to keep the size and only re-encode.
  final int? longestEdge;

  /// The JPEG quality to start at.
  final int jpegQuality;

  /// The size the result must come in under, or null for no limit.
  final int? maxBytes;

  @override
  bool operator ==(Object other) =>
      other is ShrinkPlan &&
      other.longestEdge == longestEdge &&
      other.jpegQuality == jpegQuality &&
      other.maxBytes == maxBytes;

  @override
  int get hashCode => Object.hash(longestEdge, jpegQuality, maxBytes);

  @override
  String toString() => 'ShrinkPlan($longestEdge px, q$jpegQuality, $maxBytes)';
}

/// Whether [source] has to be scaled down before it is sent at [quality] on
/// [network], and how; null to send it untouched.
///
/// [maxUploadBytes] is the homeserver's limit, 0 when it did not say. Only
/// photos are ever touched. A photo already inside every limit is sent as it
/// is, so choosing a lower quality never makes a small picture worse.
ShrinkPlan? planShrink(
  AttachmentSource source, {
  required MediaQuality quality,
  required ChatNetwork network,
  int maxUploadBytes = 0,
}) {
  if (!_shrinkable.contains(sniffMimeType(source))) return null;

  final limits = [
    ?mediaByteLimitFor(network),
    if (maxUploadBytes > 0) maxUploadBytes,
  ];
  final maxBytes = limits.isEmpty
      ? null
      : limits.reduce((a, b) => a < b ? a : b);

  final edge = quality.longestEdge;
  final dimensions = probeImageDimensions(source.header);
  // Unknown dimensions under a cap are treated as over it: a decoder that can
  // read the file finds out, and one that is already small comes back as is.
  final tooWide =
      edge != null && (dimensions == null || dimensions.longestEdge > edge);
  final tooHeavy = maxBytes != null && source.sizeBytes > maxBytes;
  if (!tooWide && !tooHeavy) return null;

  return ShrinkPlan(
    longestEdge: edge,
    jpegQuality: quality.jpegQuality,
    maxBytes: maxBytes,
  );
}
