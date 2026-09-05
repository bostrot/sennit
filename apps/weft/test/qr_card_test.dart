import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:weft/features/components/qr_card.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft/app/localisation.dart';

/// The one card two unrelated features render a code on.
///
/// The binary constructor is the reason this widget exists rather than a copied
/// `QrImageView`: a Matrix verification payload is bytes, and the obvious way to
/// draw it — turn the bytes into a string and hand that over — produces a code
/// that scans perfectly and verifies against nothing.
void main() {
  Future<void> pump(WidgetTester tester, Widget card) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: weftLocalizationsDelegates,
        theme: WeftTheme.build(),
        home: Scaffold(body: Center(child: card)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders a text payload', (tester) async {
    await pump(tester, const QrCard.data('https://example.org/link'));

    expect(find.byType(QrImageView), findsOneWidget);
  });

  testWidgets('renders a binary payload', (tester) async {
    // Shaped like the real thing: the six-byte MATRIX header, a version, a
    // mode, and then key material that is uniformly distributed over all 256
    // byte values.
    final bytes = Uint8List.fromList([
      ...ascii.encode('MATRIX'),
      0x02,
      0x00,
      ...List<int>.generate(96, (i) => (i * 7) % 256),
    ]);

    await pump(tester, QrCard.bytes(bytes));

    expect(find.byType(QrImageView), findsOneWidget);
  });

  test('a byte payload is not the same code as its string spelling', () {
    // The failure this widget exists to prevent. Every byte above 0x7F becomes
    // two under UTF-8, so the string route encodes a longer, different payload
    // — silently, and with no visible difference in the drawn code. A hundred
    // high bytes become two hundred, which is four QR versions apart.
    final bytes = Uint8List.fromList(List<int>.filled(100, 0xFF));

    final binary = QrCode.fromUint8List(
      data: bytes,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    final viaString = QrCode.fromData(
      data: String.fromCharCodes(bytes),
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );

    expect(binary.moduleCount, lessThan(viaString.moduleCount));
  });

  testWidgets('the card is white whatever the theme is doing', (tester) async {
    // Scanners assume dark modules on a light ground; an inverted code is
    // routinely unreadable, and a dark theme would invert it.
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: weftLocalizationsDelegates,
        theme: WeftTheme.build(brightness: Brightness.dark),
        home: const Scaffold(body: Center(child: QrCard.data('weft'))),
      ),
    );
    await tester.pumpAndSettle();

    final container = tester.widget<Container>(
      find.ancestor(
        of: find.byType(QrImageView),
        matching: find.byType(Container),
      ),
    );
    expect((container.decoration! as BoxDecoration).color, Colors.white);
  });
}
