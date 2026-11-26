import 'package:test/test.dart';
import 'package:weft_attachments/weft_attachments.dart';

void main() {
  group('formatAttachmentSize', () {
    test('writes a point by default', () {
      expect(formatAttachmentSize(1536), '1.5 kB');
      expect(formatAttachmentSize((2.4 * 1024 * 1024).round()), '2.4 MB');
    });

    test('writes the decimal mark it is given', () {
      expect(
        formatAttachmentSize(
          (2.4 * 1024 * 1024).round(),
          decimalSeparator: ',',
        ),
        '2,4 MB',
      );
      expect(formatAttachmentSize(1024, decimalSeparator: ','), '1,0 kB');
    });

    test('leaves whole numbers and bytes alone', () {
      expect(formatAttachmentSize(999, decimalSeparator: ','), '999 B');
      expect(
        formatAttachmentSize(12 * 1024 * 1024, decimalSeparator: ','),
        '12 MB',
      );
    });
  });
}
