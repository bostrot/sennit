import 'dart:typed_data';

import 'package:matrix/encryption.dart' as enc;
import 'package:matrix/matrix.dart' as sdk;

/// How the user can prove two devices are the same person's.
///
/// Named for what the user does rather than for the Matrix method string,
/// because the mapping is not one to one: showing a code and scanning one are a
/// single spec method seen from two ends, and which end this device is on is
/// decided by what the *other* side offered.
enum VerificationChoice {
  /// Compare a row of emoji. Always available, and the only option when either
  /// side has no camera.
  emoji,

  /// Render our code for the other device to scan. Nothing is sent until they
  /// scan it.
  showQr,

  /// Read the other device's code with a camera.
  scanQr,
}

/// Which choices to offer, given the methods the two sides agreed on.
///
/// [possibleMethods] is the SDK's intersection of what both ends support, so
/// this is a rendering decision rather than a negotiation — but it is the one
/// place a missing entry turns into a button that cancels the verification, so
/// it is pure and tested rather than inlined into a widget.
///
/// [VerificationChoice.scanQr] additionally requires reciprocate: scanning is
/// how we *learn* the other side's keys, and telling them so is a separate
/// method. The SDK drops reciprocate from the list when no QR pairing is
/// possible, so a scan button without it would start a flow that immediately
/// cancels.
List<VerificationChoice> verificationChoices(Iterable<String> possibleMethods) {
  final methods = possibleMethods.toSet();
  return [
    if (methods.contains(sdk.EventTypes.Sas)) VerificationChoice.emoji,
    if (methods.contains(sdk.EventTypes.QRShow)) VerificationChoice.showQr,
    if (methods.contains(sdk.EventTypes.QRScan) &&
        methods.contains(sdk.EventTypes.Reciprocate))
      VerificationChoice.scanQr,
  ];
}

/// The payload to render as a QR code, or null before the other side is ready.
///
/// Raw bytes, not text. The Matrix QR payload is binary — two ed25519 keys and
/// a shared secret behind a six-byte header — and putting it through a string
/// would re-encode every byte above 0x7F as two UTF-8 ones, producing a code
/// that scans cleanly and verifies against nothing.
Uint8List? verificationQrBytes(enc.KeyVerification verification) {
  final code = verification.qrCode;
  return code == null ? null : Uint8List.fromList(code.qrDataRawBytes);
}

/// Acts on the user's pick at [enc.KeyVerificationState.askChoice].
///
/// [VerificationChoice.showQr] is absent on purpose: showing our code sends
/// nothing. The other device scans it and starts the exchange, which arrives as
/// [enc.KeyVerificationState.confirmQRScan] — so a "show" that called into the
/// SDK would be starting a second, competing verification.
Future<void> chooseVerification(
  enc.KeyVerification verification,
  VerificationChoice choice, {
  Uint8List? qrBytes,
}) {
  switch (choice) {
    case VerificationChoice.emoji:
      return verification.continueVerification(sdk.EventTypes.Sas);
    case VerificationChoice.scanQr:
      if (qrBytes == null) {
        throw ArgumentError.notNull('qrBytes');
      }
      return verification.continueVerification(
        sdk.EventTypes.Reciprocate,
        qrDataRawBytes: qrBytes,
      );
    case VerificationChoice.showQr:
      throw ArgumentError.value(
        choice,
        'choice',
        'showing a QR code sends nothing; render it and wait',
      );
  }
}
