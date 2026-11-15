import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reads a QR code off another device's screen.
///
/// An interface with no camera behind it yet, and that is a deliberate,
/// visible gap rather than an oversight. Matrix QR verification is asymmetric:
/// one device shows a code and the other reads it, and *either* end may be the
/// reader. Sennit implements the shower end completely, which is enough to
/// verify a new Sennit device from an existing Element — and two Sennit devices
/// still have emoji comparison, which needs no camera at all.
///
/// What the reader end needs is a decoder that hands back **raw bytes**. The
/// Matrix payload is binary, so a scanner that only exposes a decoded string
/// (which is most of them, on most platforms) cannot be used: the bytes above
/// 0x7F come back re-encoded and the signature check fails. Picking one is a
/// dependency and a five-platform permissions decision that needs a device to
/// validate, so the seam is here and the implementation is not.
abstract class QrScanner {
  /// Whether this build can actually read a code. The verification screen
  /// offers the scan option only when it can — a button that opens a camera
  /// that never returns is worse than no button.
  bool get available;

  /// The scanned payload's raw bytes, or null if the user backed out.
  Future<Uint8List?> scan(BuildContext context);
}

/// The scanner every build currently gets: none.
class UnavailableQrScanner implements QrScanner {
  const UnavailableQrScanner();

  @override
  bool get available => false;

  @override
  Future<Uint8List?> scan(BuildContext context) async => null;
}

/// Overridden in tests, and by whichever build eventually bundles a decoder.
final qrScannerProvider = Provider<QrScanner>(
  (ref) => const UnavailableQrScanner(),
);
