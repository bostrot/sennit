import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import '../support/golden_harness.dart';

/// Renders the Play Store feature graphic (1024×500) from [BrandMarkPainter]
/// and the brand name, to `tooling/store/graphics/feature_graphic.png`.
void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('feature graphic', (tester) async {
    const size = Size(1024, 500);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  BrandMarkPainter.gradientStart,
                  BrandMarkPainter.gradientEnd,
                ],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.only(left: 150),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 220,
                    child: CustomPaint(
                      painter: BrandMarkPainter(background: false),
                    ),
                  ),
                  SizedBox(width: 36),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sennit',
                        style: TextStyle(
                          fontFamily: 'Roboto',
                          fontSize: 128,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1.05,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Every conversation, one thread.',
                        style: TextStyle(
                          fontFamily: 'Roboto',
                          fontSize: 38,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('../../tooling/store/graphics/feature_graphic.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      expect(image.width, 1024);
      expect(image.height, 500);
    });
  });
}
