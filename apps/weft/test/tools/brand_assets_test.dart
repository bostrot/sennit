import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

/// Renders the launcher-icon PNGs from [BrandMarkPainter].
///
/// A test rather than a script because dart:ui only rasterises inside a
/// Flutter binding. Running the suite regenerates the assets in place —
/// deterministically, so an unchanged painter writes identical bytes —
/// and `dart run flutter_launcher_icons` fans them out to every density.
void main() {
  testWidgets('the brand assets render from the painter', (tester) async {
    await tester.runAsync(() async {
      Future<void> render(
        String path, {
        required bool background,
        double inset = 0,
      }) async {
        const s = 1024.0;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        if (inset > 0) {
          canvas.translate(inset, inset);
          canvas.scale((s - 2 * inset) / s);
        }
        BrandMarkPainter(
          background: background,
        ).paint(canvas, const Size(s, s));
        final image = await recorder.endRecording().toImage(1024, 1024);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        expect(bytes, isNotNull, reason: path);
        File(path)
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      }

      await render('assets/brand/icon.png', background: true);
      // The adaptive foreground keeps the strands inside the safe zone: the
      // launcher masks up to a third of each edge away.
      await render(
        'assets/brand/icon_foreground.png',
        background: false,
        inset: 220,
      );
    });
  });
}
