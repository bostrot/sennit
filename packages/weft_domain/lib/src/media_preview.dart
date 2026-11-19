import 'message.dart';

/// Largest video the timeline downloads by itself, to draw a poster frame or to
/// loop a GIF in place.
///
/// Bridged WhatsApp, Signal and Meta videos arrive with no `thumbnail_url` at
/// all — the bridges relay the film and its size and nothing else — so the only
/// poster there is to show is a frame of the film. A WhatsApp clip or GIF is a
/// few megabytes; a feature film is not, and stays a tap away.
const int kPreviewVideoMaxBytes = 16 * 1024 * 1024;

/// Largest GIF fetched whole for the bubble instead of its still thumbnail.
const int kPreviewAnimatedImageMaxBytes = 8 * 1024 * 1024;

/// Whether the bubble's preview of [message] is the original file rather than
/// the event's thumbnail.
///
/// True only for an animated image: the thumbnail of a GIF is one JPEG frame,
/// and showing it is what made every GIF look like a photo. A size nobody
/// announced is allowed, because GIFs are small far more often than not and the
/// SDK hands back the original anyway when the event has no thumbnail.
bool previewUsesOriginal(WeftMessage message) {
  if (!message.isAnimatedImage) return false;
  final size = message.mediaSizeBytes;
  return size == null || size <= kPreviewAnimatedImageMaxBytes;
}

/// Whether the bubble may download [message]'s video to show it: a poster frame
/// when the event carried no thumbnail, and the loop itself for a GIF.
///
/// An ordinary video needs an announced size within [kPreviewVideoMaxBytes] —
/// downloading an unknown amount to draw one frame is not a trade to make on
/// someone's mobile data. A GIF-flagged one is allowed without a size: the
/// sender said it is a GIF, and looping in place is the whole of what it is for.
bool previewDownloadsVideo(WeftMessage message) {
  if (message.kind != MessageKind.video || message.redacted) return false;
  final size = message.mediaSizeBytes;
  if (size == null) return message.loopsInline;
  return size <= kPreviewVideoMaxBytes;
}
