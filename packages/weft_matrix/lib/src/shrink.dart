import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:weft_attachments/weft_attachments.dart';

/// A photo scaled and re-encoded for sending.
@immutable
class ShrunkImage {
  const ShrunkImage({required this.bytes, required this.mimeType});

  final Uint8List bytes;

  /// `image/jpeg`, or `image/png` for a picture with transparency, which a
  /// JPEG would fill in black.
  final String mimeType;
}

/// [bytes] scaled to [plan], on a background isolate; null when they will not
/// decode or cannot be brought under [ShrinkPlan.maxBytes].
///
/// Re-encoding also drops the file's metadata, the location a camera wrote
/// into it included. The pixels are turned upright first, since the
/// orientation tag that said which way was up goes with the rest.
Future<ShrunkImage?> shrinkImage(Uint8List bytes, ShrinkPlan plan) =>
    compute(_shrink, (bytes: bytes, plan: plan));

/// The isolate body of [shrinkImage]. Top-level because `compute` cannot send
/// a closure.
ShrunkImage? _shrink(({Uint8List bytes, ShrinkPlan plan}) request) {
  final plan = request.plan;
  final decoded = img.decodeImage(request.bytes);
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) return null;
  var image = img.bakeOrientation(decoded);

  final edge = plan.longestEdge;
  if (edge != null) image = _fit(image, edge);

  final alpha = image.hasAlpha;
  var quality = plan.jpegQuality;
  // Each round either lowers the JPEG quality a step or, once that has gone
  // as far as is still pleasant to look at, takes a quarter off the edges.
  // Eight rounds take a 48 MP photo below a megabyte; one that still does not
  // fit is not worth sending as a smudge.
  for (var round = 0; round < 8; round++) {
    final encoded = alpha
        ? img.encodePng(image)
        : img.encodeJpg(image, quality: quality);
    final max = plan.maxBytes;
    if (max == null || encoded.length <= max) {
      return ShrunkImage(
        bytes: encoded,
        mimeType: alpha ? 'image/png' : 'image/jpeg',
      );
    }
    if (!alpha && quality > 60) {
      quality = math.max(60, quality - 10);
    } else {
      image = _fit(image, (math.max(image.width, image.height) * 0.75).round());
    }
  }
  return null;
}

img.Image _fit(img.Image image, int edge) {
  final longest = math.max(image.width, image.height);
  if (longest <= edge) return image;
  final scale = edge / longest;
  return img.copyResize(
    image,
    width: math.max(1, (image.width * scale).round()),
    height: math.max(1, (image.height * scale).round()),
    interpolation: img.Interpolation.average,
  );
}
