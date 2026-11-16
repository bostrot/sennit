import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/services/attachments/video_poster.dart';

/// A video Sennit sent used to arrive as an empty box with a play button: the
/// preview was scaled down from the file's own bytes, and an MP4 is not a
/// picture. These pin which bytes the preview is made from.
void main() {
  // `ftyp` at offset 4 is what makes the sniffer call this an MP4.
  Uint8List mp4Header() => Uint8List.fromList([
    0, 0, 0, 0x18, ...'ftypisom'.codeUnits, 0, 0, 0, 0, //
    ...'isomiso2'.codeUnits,
  ]);
  Uint8List jpegHeader() => Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0,
    0x10,
    ...'JFIF'.codeUnits,
  ]);

  UploadPlan plan(String name, Uint8List header, int size) {
    final decision = planUpload(
      AttachmentSource(filename: name, sizeBytes: size, header: header),
      encrypted: false,
      maxUploadBytes: 50 * 1024 * 1024,
    );
    return decision as UploadPlan;
  }

  final fileBytes = Uint8List.fromList([1, 2, 3]);
  final frame = Uint8List.fromList([9, 9, 9]);

  test('a video is previewed from a frame, not from its own bytes', () async {
    final video = plan('clip.mp4', mp4Header(), 5 * 1024 * 1024);
    expect(video.kind, MessageKind.video);

    AttachmentSource? asked;
    final preview = await previewSourceFor(
      video,
      fileBytes: fileBytes,
      poster: (source) async {
        asked = source;
        return frame;
      },
    );

    expect(preview, frame);
    expect(asked?.filename, 'clip.mp4');
  });

  test('a video with no frame to be had gets no preview', () async {
    final video = plan('clip.mp4', mp4Header(), 5 * 1024 * 1024);
    final preview = await previewSourceFor(
      video,
      fileBytes: fileBytes,
      poster: (_) async => null,
    );
    expect(preview, isNull);
  });

  test('a clip too small for a preview never starts a decoder', () async {
    final tiny = plan('clip.mp4', mp4Header(), kThumbnailMinSourceBytes - 1);
    var asked = false;
    final preview = await previewSourceFor(
      tiny,
      fileBytes: fileBytes,
      poster: (_) async {
        asked = true;
        return frame;
      },
    );
    expect(preview, isNull);
    expect(asked, isFalse);
  });

  test('a photo is still its own preview', () async {
    final photo = plan('photo.jpg', jpegHeader(), 5 * 1024 * 1024);
    expect(photo.kind, MessageKind.image);
    final preview = await previewSourceFor(
      photo,
      fileBytes: fileBytes,
      poster: (_) async => fail('a photo needs no poster'),
    );
    expect(preview, fileBytes);
  });
}
