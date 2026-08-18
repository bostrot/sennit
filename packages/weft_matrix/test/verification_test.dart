import 'package:flutter_test/flutter_test.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// Which verification options a screen may offer.
///
/// The negotiated method list is the one place a rendering mistake becomes a
/// protocol one: a button for a method the other side did not agree to sends a
/// start that is immediately cancelled, and the user sees a verification that
/// failed for no reason they can act on.
void main() {
  const sas = 'm.sas.v1';
  const qrShow = 'm.qr_code.show.v1';
  const qrScan = 'm.qr_code.scan.v1';
  const reciprocate = 'm.reciprocate.v1';

  group('verificationChoices', () {
    test('emoji alone when the other side offers nothing else', () {
      expect(verificationChoices([sas]), [VerificationChoice.emoji]);
    });

    test('show and scan are separate ends of one method', () {
      // The SDK puts *our* end in the list: it is `show` when they can scan and
      // `scan` when they can show, never both.
      expect(verificationChoices([sas, qrShow, reciprocate]), [
        VerificationChoice.emoji,
        VerificationChoice.showQr,
      ]);
      expect(verificationChoices([sas, qrScan, reciprocate]), [
        VerificationChoice.emoji,
        VerificationChoice.scanQr,
      ]);
    });

    test('scanning without reciprocate is not offered', () {
      // Scanning is how we learn their keys; reciprocate is how we tell them we
      // did. The SDK drops reciprocate when no QR pairing is possible, so a
      // scan button without it starts a flow that cancels itself.
      expect(verificationChoices([sas, qrScan]), [VerificationChoice.emoji]);
    });

    test('showing needs no reciprocate of ours — they send the start', () {
      expect(verificationChoices([qrShow]), [VerificationChoice.showQr]);
    });

    test('an empty negotiation offers nothing rather than a default', () {
      expect(verificationChoices(const []), isEmpty);
      expect(verificationChoices([reciprocate]), isEmpty);
    });

    test('the order is fixed, so the buttons do not move between runs', () {
      expect(verificationChoices([reciprocate, qrScan, sas]), [
        VerificationChoice.emoji,
        VerificationChoice.scanQr,
      ]);
    });
  });
}
