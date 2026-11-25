import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  /// A noisy photo, so JPEG cannot squeeze it to nothing.
  Uint8List photo(int width, int height, {bool alpha = false}) {
    final rng = math.Random(7);
    final image = img.Image(
      width: width,
      height: height,
      numChannels: alpha ? 4 : 3,
    );
    for (final p in image) {
      p
        ..r = rng.nextInt(256)
        ..g = rng.nextInt(256)
        ..b = rng.nextInt(256);
      if (alpha) p.a = 128;
    }
    return alpha ? img.encodePng(image) : img.encodeJpg(image, quality: 95);
  }

  img.Image decode(Uint8List bytes) => img.decodeImage(bytes)!;

  test('a photo is scaled to the longest edge', () async {
    final shrunk = await shrinkImage(
      photo(800, 400),
      const ShrinkPlan(longestEdge: 200, jpegQuality: 85, maxBytes: null),
    );
    final image = decode(shrunk!.bytes);
    expect((image.width, image.height), (200, 100));
    expect(shrunk.mimeType, 'image/jpeg');
  });

  test('a photo is brought under the byte limit', () async {
    final original = photo(600, 600);
    final shrunk = await shrinkImage(
      original,
      ShrinkPlan(
        longestEdge: null,
        jpegQuality: 92,
        maxBytes: original.length ~/ 4,
      ),
    );
    expect(shrunk!.bytes.length, lessThanOrEqualTo(original.length ~/ 4));
  });

  test('transparency survives as a PNG', () async {
    final shrunk = await shrinkImage(
      photo(400, 400, alpha: true),
      const ShrinkPlan(longestEdge: 100, jpegQuality: 85, maxBytes: null),
    );
    expect(shrunk!.mimeType, 'image/png');
    expect(decode(shrunk.bytes).hasAlpha, isTrue);
  });

  test('bytes that are not a photo come back as null', () async {
    expect(
      await shrinkImage(
        Uint8List.fromList(List.filled(64, 7)),
        const ShrinkPlan(longestEdge: 100, jpegQuality: 85, maxBytes: null),
      ),
      isNull,
    );
  });

  test('a limit no photo can meet comes back as null', () async {
    expect(
      await shrinkImage(
        photo(400, 400),
        const ShrinkPlan(longestEdge: null, jpegQuality: 85, maxBytes: 10),
      ),
      isNull,
    );
  });
}
