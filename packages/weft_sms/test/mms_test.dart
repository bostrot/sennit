import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_sms/weft_sms.dart';

void main() {
  /// A source whose real size is decoupled from its header slice: a 4 MB video
  /// is planned from eight bytes, which is how every caller uses it.
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

  const jpegHeader = [0xFF, 0xD8, 0xFF, 0xE0];
  const pngHeader = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  const mp4Header = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70];
  const pdfHeader = [0x25, 0x50, 0x44, 0x46];

  group('planMmsPart', () {
    test('plans a small photo with its sniffed type and content id', () {
      final decision = planMmsPart(
        source(jpegHeader, filename: 'holiday.jpg', sizeBytes: 120 * 1024),
      );

      expect(decision, isA<MmsPart>());
      final part = decision as MmsPart;
      expect(part.mimeType, 'image/jpeg');
      expect(part.kind, MessageKind.image);
      expect(part.contentLocation, 'holiday.jpg');
      expect(part.contentId, '<holiday.jpg>');
      expect(part.sizeBytes, 120 * 1024);
    });

    test('announces the sniffed type, not the declared one', () {
      // A picker that labels everything `*/*`, or a PNG saved as `.jpg`, is
      // routine. Carriers transcode on the announced type, so believing the
      // sender produces a part every receiving handset renders as broken.
      final part =
          planMmsPart(
                source(
                  pngHeader,
                  filename: 'photo.jpg',
                  declaredMimeType: 'image/jpeg',
                  sizeBytes: 40 * 1024,
                ),
              )
              as MmsPart;

      expect(part.mimeType, 'image/png');
    });

    test('strips a picker path off the content location', () {
      final part =
          planMmsPart(
                source(
                  jpegHeader,
                  filename: '/storage/emulated/0/DCIM/photo.jpg',
                  sizeBytes: 1024,
                ),
              )
              as MmsPart;

      expect(part.contentLocation, 'photo.jpg');
    });

    test('rejects an empty file', () {
      final decision = planMmsPart(source(const [], filename: 'empty.jpg'));

      expect(decision, isA<MmsRejection>());
      expect((decision as MmsRejection).reason, MmsRejectionReason.empty);
      expect(decision.message, isNot(contains('null')));
    });

    test('rejects a file over the carrier budget, in kilobytes', () {
      final decision = planMmsPart(
        source(mp4Header, filename: 'clip.mp4', sizeBytes: 4 * 1024 * 1024),
      );

      expect(decision, isA<MmsRejection>());
      final rejection = decision as MmsRejection;
      expect(rejection.reason, MmsRejectionReason.tooLarge);
      // The reader is deciding whether to re-record something smaller, so the
      // sentence has to carry both numbers in a unit MMS budgets are measured in.
      expect(rejection.message, contains('4096 KB'));
      expect(rejection.message, contains('298 KB'));
    });

    test('counts sibling parts against the same message budget', () {
      final photo = source(
        jpegHeader,
        filename: 'a.jpg',
        sizeBytes: 120 * 1024,
      );

      // Alone it fits; behind 250 KB of siblings the message no longer does —
      // the ceiling belongs to the message, not to any one attachment.
      expect(planMmsPart(photo), isA<MmsPart>());
      expect(
        planMmsPart(photo, reservedBytes: 250 * 1024),
        isA<MmsRejection>(),
      );
    });

    test('reserves header and SMIL overhead out of the budget', () {
      // Exactly the ceiling still does not fit: the PDU, the part headers and
      // the presentation part are payload too, and a plan that fits by nothing
      // is a message the MMSC drops in silence.
      final atCeiling = source(
        jpegHeader,
        filename: 'a.jpg',
        sizeBytes: kMmsDefaultMaxBytes,
      );
      expect(planMmsPart(atCeiling), isA<MmsRejection>());

      final justUnder = source(
        jpegHeader,
        filename: 'a.jpg',
        sizeBytes: kMmsDefaultMaxBytes - kMmsOverheadBytes,
      );
      expect(planMmsPart(justUnder), isA<MmsPart>());
    });

    test('honours a carrier ceiling above the conservative default', () {
      final big = source(jpegHeader, filename: 'a.jpg', sizeBytes: 800 * 1024);

      expect(planMmsPart(big), isA<MmsRejection>());
      expect(planMmsPart(big, maxMessageBytes: 1024 * 1024), isA<MmsPart>());
    });

    test('rejects a type MMS does not carry, whatever its size', () {
      final decision = planMmsPart(
        source(pdfHeader, filename: 'report.pdf', sizeBytes: 8 * 1024),
      );

      expect(decision, isA<MmsRejection>());
      final rejection = decision as MmsRejection;
      expect(rejection.reason, MmsRejectionReason.unsupportedType);
      // Plain language, and specific about which network is the constraint —
      // the same file sent fine on WhatsApp an hour ago.
      expect(rejection.message, contains('application/pdf'));
      expect(rejection.message, contains('another network'));
    });

    test('rejects a file with no name', () {
      final decision = planMmsPart(
        source(jpegHeader, filename: '   ', sizeBytes: 1024),
      );

      expect(decision, isA<MmsRejection>());
      expect(
        (decision as MmsRejection).reason,
        MmsRejectionReason.unsupportedType,
      );
    });

    test('every input produces a decision rather than an exception', () {
      final awkward = [
        source(const [], filename: ''),
        source(jpegHeader, filename: '.', sizeBytes: -1),
        source(const [0], filename: 'x', sizeBytes: 1 << 40),
        source(pdfHeader, filename: 'a.pdf', sizeBytes: 0),
      ];

      for (final s in awkward) {
        expect(planMmsPart(s), isA<MmsDecision>());
      }
    });
  });
}
