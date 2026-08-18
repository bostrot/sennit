import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:weft_design/weft_design.dart';

/// A QR code on a white card, whatever the theme is doing.
///
/// Extracted from the bridge login screen, which is where the constraint was
/// discovered: scanner apps assume dark modules on a light ground, and a code
/// drawn in a dark theme's colours is routinely unscannable. Device
/// verification needs exactly the same card, and a second copy of it would have
/// been a second place for that rule to be forgotten.
///
/// Two constructors because the two callers carry different things. A bridge
/// login code is text the network gave us; a Matrix verification code is binary
/// — two ed25519 keys and a shared secret — and putting those bytes through a
/// string re-encodes everything above 0x7F as two UTF-8 bytes, which produces a
/// code that scans perfectly and verifies against nothing.
class QrCard extends StatelessWidget {
  const QrCard.data(String this.data, {super.key, this.size = 220})
    : bytes = null;

  const QrCard.bytes(Uint8List this.bytes, {super.key, this.size = 220})
    : data = null;

  final String? data;
  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bytes = this.bytes;

    return Container(
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: WeftRadius.allMd,
      ),
      child: bytes == null
          ? QrImageView(data: data!, size: size, version: QrVersions.auto)
          : QrImageView.withQr(
              qr: QrCode.fromUint8List(
                data: bytes,
                errorCorrectLevel: QrErrorCorrectLevel.L,
              ),
              size: size,
            ),
    );
  }
}
