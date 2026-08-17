import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/fixtures.dart';

void main() {
  AttachmentSource source(
    List<int> header, {
    String filename = 'file.bin',
    String? declaredMimeType,
    int? sizeBytes,
  }) {
    return AttachmentSource(
      filename: filename,
      declaredMimeType: declaredMimeType,
      sizeBytes: sizeBytes ?? header.length,
      header: Uint8List.fromList(header),
    );
  }

  group('sniffMimeType — magic bytes', () {
    final cases = <String, List<int>>{
      'image/png': png(width: 2, height: 2),
      'image/jpeg': jpeg(width: 2, height: 2),
      'image/gif': gif(width: 2, height: 2),
      'image/webp': webpLossy(width: 2, height: 2),
      'image/heic': isoBaseMedia(brand: 'heic'),
      'video/mp4': isoBaseMedia(brand: 'isom'),
      'video/quicktime': isoBaseMedia(brand: 'qt  '),
      'video/webm': webm(),
      'audio/ogg': ogg(),
      'audio/mpeg': mp3(),
      'audio/wav': wav(),
      'application/pdf': pdf(),
      'application/zip': zip(),
    };

    cases.forEach((expected, bytes) {
      test('detects $expected', () {
        expect(sniffMimeType(source(bytes)), expected);
      });
    });

    test('an ftyp brand nobody knows is still an MP4', () {
      expect(sniffMimeType(source(isoBaseMedia(brand: 'zzzz'))), 'video/mp4');
    });

    test('M4A is audio, not video, despite the shared container', () {
      expect(sniffMimeType(source(isoBaseMedia(brand: 'M4A '))), 'audio/mp4');
    });

    test('a bare MPEG frame sync counts as MP3', () {
      // 0xFFFB: MPEG-1 layer III, no ID3 tag in front of it.
      expect(sniffMimeType(source([0xFF, 0xFB, 0x90, 0x00])), 'audio/mpeg');
    });

    test('a reserved MPEG version is not believed', () {
      // Eleven set bits, but version bits 01 is reserved — this is not audio.
      final bytes = [0xFF, 0xEB, 0x00, 0x00];
      expect(sniffMimeType(source(bytes)), kFallbackMimeType);
    });

    test('an Ogg carrying Theora is video, not audio', () {
      expect(sniffMimeType(source(ogg(codec: 'theora'))), 'video/ogg');
    });

    test('a Matroska doctype is distinguished from WebM', () {
      expect(
        sniffMimeType(source(webm(docType: 'matroska'))),
        'video/x-matroska',
      );
    });
  });

  group('sniffMimeType — conflict resolution', () {
    test('the bytes win over a declared type that disagrees', () {
      final s = source(
        png(width: 1, height: 1),
        filename: 'photo.jpg',
        declaredMimeType: 'image/jpeg',
      );
      expect(sniffMimeType(s), 'image/png');
    });

    test('a wildcard share intent is ignored in favour of the bytes', () {
      final s = source(
        jpeg(width: 1, height: 1),
        filename: 'IMG_0001',
        declaredMimeType: '*/*',
      );
      expect(sniffMimeType(s), 'image/jpeg');
    });

    test('octet-stream is treated as no claim at all', () {
      final s = source(
        [],
        filename: 'notes.pdf',
        declaredMimeType: 'application/octet-stream',
      );
      expect(sniffMimeType(s), 'application/pdf');
    });

    test('parameters on the declared type are stripped', () {
      final s = source(
        [],
        filename: 'x',
        declaredMimeType: 'text/plain; charset=utf-8',
      );
      expect(sniffMimeType(s), 'text/plain');
    });

    test(
      'the declared type wins over the extension when bytes say nothing',
      () {
        final s = source(
          [0x00, 0x01, 0x02],
          filename: 'mislabelled.txt',
          declaredMimeType: 'application/json',
        );
        expect(sniffMimeType(s), 'application/json');
      },
    );

    test('the extension is the last resort before octet-stream', () {
      expect(sniffMimeType(source([], filename: 'a.MP3')), 'audio/mpeg');
      expect(
        sniffMimeType(source([], filename: 'a.unknown')),
        kFallbackMimeType,
      );
      expect(
        sniffMimeType(source([], filename: 'noextension')),
        kFallbackMimeType,
      );
      expect(
        sniffMimeType(source([], filename: '.gitignore')),
        kFallbackMimeType,
      );
    });

    test('a path-shaped filename still yields its extension', () {
      expect(
        sniffMimeType(source([], filename: '/tmp/downloads/report.pdf')),
        'application/pdf',
      );
    });

    test('a ZIP is refined by the declared type when there is one', () {
      const docx =
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      expect(
        sniffMimeType(source(zip(), filename: 'a.bin', declaredMimeType: docx)),
        docx,
      );
    });

    test(
      'a ZIP is refined by the extension when the declaration is useless',
      () {
        expect(
          sniffMimeType(
            source(zip(), filename: 'book.epub', declaredMimeType: '*/*'),
          ),
          'application/epub+zip',
        );
      },
    );

    test('a plain ZIP stays a plain ZIP', () {
      expect(
        sniffMimeType(source(zip(), filename: 'a.zip')),
        'application/zip',
      );
    });

    test(
      'a declared type that is not zip-based does not override the sniff',
      () {
        final s = source(
          zip(),
          filename: 'a.bin',
          declaredMimeType: 'image/png',
        );
        expect(sniffMimeType(s), 'application/zip');
      },
    );
  });

  group('sniffMimeType — malformed input', () {
    test('zero bytes falls all the way through', () {
      expect(sniffMimeType(source([])), kFallbackMimeType);
    });

    test('a truncated PNG signature is not a PNG', () {
      expect(sniffMimeType(source([0x89, 0x50, 0x4E])), kFallbackMimeType);
    });

    test('a truncated RIFF header commits to nothing', () {
      expect(
        sniffMimeType(source([0x52, 0x49, 0x46, 0x46, 0x10])),
        kFallbackMimeType,
      );
    });

    test('a RIFF form nobody handles is not guessed at', () {
      final bytes = [...'RIFF'.codeUnits, 0, 0, 0, 0, ...'AVI '.codeUnits];
      expect(sniffMimeType(source(bytes)), kFallbackMimeType);
    });

    test('a header of pure zeroes is octet-stream, not a crash', () {
      expect(sniffMimeType(source(List.filled(64, 0))), kFallbackMimeType);
    });

    test('every fixture sniffs at every truncation length', () {
      // The probes already have this sweep; the sniffer needs it just as much,
      // because a share intent can hand over a file that is still being
      // written. Any length must yield a type rather than an index error.
      final fixtures = <List<int>>[
        png(width: 8, height: 8),
        jpeg(width: 8, height: 8),
        gif(width: 8, height: 8),
        webpLossy(width: 8, height: 8),
        webpLossless(width: 8, height: 8),
        webpExtended(width: 8, height: 8),
        isoBaseMedia(brand: 'heic'),
        mp4WithTracks(const [MediaDimensions(64, 64)]),
        webm(),
        ogg(),
        mp3(),
        wav(),
        pdf(),
        zip(),
      ];

      for (final full in fixtures) {
        for (var take = 0; take <= full.length; take++) {
          final head = full.take(take).toList();
          expect(
            () => sniffMimeType(source(head, filename: 'partial')),
            returnsNormally,
            reason: '$take of ${full.length} bytes',
          );
          expect(sniffMimeType(source(head, filename: 'partial')), isNotEmpty);
        }
      }
    });
  });

  group('messageKindFor', () {
    test('maps each family to its kind', () {
      expect(messageKindFor('image/png'), MessageKind.image);
      expect(messageKindFor('video/mp4'), MessageKind.video);
      expect(messageKindFor('audio/ogg'), MessageKind.audio);
      expect(messageKindFor('application/pdf'), MessageKind.file);
      expect(messageKindFor('text/plain'), MessageKind.file);
      expect(messageKindFor(kFallbackMimeType), MessageKind.file);
    });

    test('voice is only reachable by the caller asserting it', () {
      expect(messageKindFor('audio/ogg', isVoiceNote: true), MessageKind.voice);
      expect(messageKindFor('audio/ogg'), MessageKind.audio);
    });

    test('the voice flag cannot turn a non-audio file into a voice note', () {
      expect(
        messageKindFor('application/pdf', isVoiceNote: true),
        MessageKind.file,
      );
      expect(messageKindFor('image/png', isVoiceNote: true), MessageKind.image);
    });

    test('junk maps to file rather than throwing', () {
      expect(messageKindFor(''), MessageKind.file);
      expect(messageKindFor('nonsense'), MessageKind.file);
      expect(messageKindFor('IMAGE/PNG'), MessageKind.image);
    });
  });

  group('probeImageDimensions', () {
    test('reads a PNG IHDR', () {
      expect(
        probeImageDimensions(
          Uint8List.fromList(png(width: 1920, height: 1080)),
        ),
        const MediaDimensions(1920, 1080),
      );
    });

    test('reads a JPEG SOF0 past an APP1 segment', () {
      expect(
        probeImageDimensions(Uint8List.fromList(jpeg(width: 640, height: 480))),
        const MediaDimensions(640, 480),
      );
    });

    test('reads a progressive JPEG SOF2', () {
      expect(
        probeImageDimensions(
          Uint8List.fromList(jpeg(width: 300, height: 200, sofMarker: 0xC2)),
        ),
        const MediaDimensions(300, 200),
      );
    });

    test('does not mistake a Huffman table for a frame header', () {
      // 0xC4 sits inside the SOFn marker range but is a DHT segment.
      final bytes = jpeg(width: 64, height: 32, extraSegmentMarker: 0xC4);
      expect(
        probeImageDimensions(Uint8List.fromList(bytes)),
        const MediaDimensions(64, 32),
      );
    });

    test('reads a GIF logical screen descriptor', () {
      expect(
        probeImageDimensions(Uint8List.fromList(gif(width: 500, height: 250))),
        const MediaDimensions(500, 250),
      );
    });

    test('reads all three WebP chunk flavours', () {
      expect(
        probeImageDimensions(
          Uint8List.fromList(webpLossy(width: 800, height: 600)),
        ),
        const MediaDimensions(800, 600),
      );
      expect(
        probeImageDimensions(
          Uint8List.fromList(webpLossless(width: 123, height: 456)),
        ),
        const MediaDimensions(123, 456),
      );
      expect(
        probeImageDimensions(
          Uint8List.fromList(webpExtended(width: 4000, height: 3000)),
        ),
        const MediaDimensions(4000, 3000),
      );
    });

    test('returns null for a format it does not parse', () {
      expect(probeImageDimensions(Uint8List.fromList(pdf())), isNull);
      expect(
        probeImageDimensions(Uint8List.fromList(isoBaseMedia(brand: 'heic'))),
        isNull,
      );
    });

    test('returns null rather than throwing on truncation', () {
      for (final full in [
        png(width: 8, height: 8),
        jpeg(width: 8, height: 8),
        gif(width: 8, height: 8),
        webpLossy(width: 8, height: 8),
        webpLossless(width: 8, height: 8),
        webpExtended(width: 8, height: 8),
      ]) {
        for (var take = 0; take < full.length; take++) {
          expect(
            () => probeImageDimensions(
              Uint8List.fromList(full.take(take).toList()),
            ),
            returnsNormally,
          );
        }
      }
    });

    test('returns null on zero bytes', () {
      expect(probeImageDimensions(Uint8List(0)), isNull);
    });

    test('a zero-dimension header is rejected, not reported as 0x0', () {
      expect(
        probeImageDimensions(Uint8List.fromList(png(width: 0, height: 0))),
        isNull,
      );
      expect(
        probeImageDimensions(Uint8List.fromList(gif(width: 10, height: 0))),
        isNull,
      );
    });
  });

  group('probeVideoDimensions', () {
    test('reads a tkhd from a faststart MP4', () {
      final bytes = mp4WithTracks(const [MediaDimensions(1280, 720)]);
      expect(
        probeVideoDimensions(Uint8List.fromList(bytes)),
        const MediaDimensions(1280, 720),
      );
    });

    test('skips the audio track and takes the visual one', () {
      final bytes = mp4WithTracks(const [
        MediaDimensions(0, 0),
        MediaDimensions(1920, 1080),
      ]);
      expect(
        probeVideoDimensions(Uint8List.fromList(bytes)),
        const MediaDimensions(1920, 1080),
      );
    });

    test('handles a version 1 tkhd with 64-bit timings', () {
      final bytes = mp4WithTracks(const [
        MediaDimensions(640, 360),
      ], tkhdVersion: 1);
      expect(
        probeVideoDimensions(Uint8List.fromList(bytes)),
        const MediaDimensions(640, 360),
      );
    });

    test('handles a 64-bit box size', () {
      final bytes = mp4WithTracks(const [
        MediaDimensions(320, 240),
      ], largeMoovSize: true);
      expect(
        probeVideoDimensions(Uint8List.fromList(bytes)),
        const MediaDimensions(320, 240),
      );
    });

    test('returns null when moov is not in the header slice', () {
      // The normal layout for anything not written for streaming: ftyp, then
      // mdat, with moov only at the very end of the file.
      final bytes = [
        ...isoBaseMedia(brand: 'isom'),
        ...box('mdat', List.filled(32, 0)),
      ];
      expect(probeVideoDimensions(Uint8List.fromList(bytes)), isNull);
    });

    test('returns null for a non-ISO-BMFF file', () {
      expect(probeVideoDimensions(Uint8List.fromList(webm())), isNull);
      expect(
        probeVideoDimensions(Uint8List.fromList(png(width: 4, height: 4))),
        isNull,
      );
      expect(probeVideoDimensions(Uint8List(0)), isNull);
    });

    test('returns null rather than throwing on truncation', () {
      final full = mp4WithTracks(const [MediaDimensions(100, 50)]);
      for (var take = 0; take < full.length; take++) {
        expect(
          () => probeVideoDimensions(
            Uint8List.fromList(full.take(take).toList()),
          ),
          returnsNormally,
        );
      }
    });

    test('a lying box size terminates the walk instead of looping', () {
      // moov claims a size smaller than its own header.
      final bogus = [
        ...isoBaseMedia(brand: 'isom'),
        0,
        0,
        0,
        2,
        ...'moov'.codeUnits,
        ...List.filled(16, 0),
      ];
      expect(probeVideoDimensions(Uint8List.fromList(bogus)), isNull);
    });
  });

  group('AttachmentSource', () {
    test('reports emptiness from the real size, not the header slice', () {
      final s = AttachmentSource(
        filename: 'big.mp4',
        sizeBytes: 400 * 1024 * 1024,
        header: Uint8List.fromList(isoBaseMedia(brand: 'isom')),
      );
      expect(s.isEmpty, isFalse);
      expect(s.header.length, lessThan(s.sizeBytes));
    });

    test('an empty file is empty even with a declared type', () {
      final s = AttachmentSource(
        filename: 'empty.png',
        sizeBytes: 0,
        declaredMimeType: 'image/png',
        header: Uint8List(0),
      );
      expect(s.isEmpty, isTrue);
    });

    test('extension is lower-cased and dot-free', () {
      expect(source([], filename: 'Photo.JPEG').extension, 'jpeg');
      expect(source([], filename: 'archive.tar.gz').extension, 'gz');
      expect(source([], filename: 'trailing.').extension, isNull);
    });
  });
}
