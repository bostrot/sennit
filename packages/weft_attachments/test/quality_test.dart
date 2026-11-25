import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/fixtures.dart';

void main() {
  AttachmentSource photo({
    required int width,
    required int height,
    int sizeBytes = 2 * 1024 * 1024,
    String filename = 'IMG_0001.jpg',
  }) => AttachmentSource(
    filename: filename,
    sizeBytes: sizeBytes,
    header: Uint8List.fromList(jpeg(width: width, height: height)),
  );

  group('MediaQuality.fromId', () {
    test('reads what it stored', () {
      for (final q in MediaQuality.values) {
        expect(MediaQuality.fromId(q.id), q);
      }
    });

    test('anything else is the original', () {
      expect(MediaQuality.fromId(null), MediaQuality.original);
      expect(MediaQuality.fromId('ultra'), MediaQuality.original);
    });
  });

  group('planShrink', () {
    test('the original goes untouched while it fits', () {
      expect(
        planShrink(
          photo(width: 4000, height: 3000),
          quality: MediaQuality.original,
          network: ChatNetwork.matrix,
        ),
        isNull,
      );
    });

    test('the original is scaled down only to fit a network', () {
      expect(
        planShrink(
          photo(width: 4000, height: 3000, sizeBytes: 12 * 1024 * 1024),
          quality: MediaQuality.original,
          network: ChatNetwork.discord,
        ),
        const ShrinkPlan(
          longestEdge: null,
          jpegQuality: 92,
          maxBytes: 10 * 1024 * 1024,
        ),
      );
    });

    test('the homeserver limit counts when it is the lower one', () {
      final plan = planShrink(
        photo(width: 4000, height: 3000, sizeBytes: 12 * 1024 * 1024),
        quality: MediaQuality.original,
        network: ChatNetwork.whatsapp,
        maxUploadBytes: 8 * 1024 * 1024,
      );
      expect(plan?.maxBytes, 8 * 1024 * 1024);
    });

    test('high caps the longest edge', () {
      final plan = planShrink(
        photo(width: 3000, height: 4000),
        quality: MediaQuality.high,
        network: ChatNetwork.matrix,
      );
      expect(plan?.longestEdge, 2560);
      expect(plan?.maxBytes, isNull);
    });

    test('a photo already inside the cap is left alone', () {
      expect(
        planShrink(
          photo(width: 1200, height: 900, sizeBytes: 300 * 1024),
          quality: MediaQuality.dataSaver,
          network: ChatNetwork.telegram,
        ),
        isNull,
      );
    });

    test('only still photos are touched', () {
      final animated = AttachmentSource(
        filename: 'party.gif',
        sizeBytes: 30 * 1024 * 1024,
        header: Uint8List.fromList(gif(width: 4000, height: 4000)),
      );
      final video = AttachmentSource(
        filename: 'clip.mp4',
        sizeBytes: 30 * 1024 * 1024,
        header: Uint8List.fromList(isoBaseMedia(brand: 'isom')),
      );
      for (final source in [animated, video]) {
        expect(
          planShrink(
            source,
            quality: MediaQuality.dataSaver,
            network: ChatNetwork.discord,
          ),
          isNull,
          reason: source.filename,
        );
      }
    });
  });
}
