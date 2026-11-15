import 'package:flutter/material.dart';

/// Sennit's mark: two strands plaited down the middle of a gradient tile.
///
/// Drawn in code rather than shipped as an asset so the launcher icon, the
/// splash, the login screen and every empty state render the same mark from
/// the same source — and so the icon PNGs can be *generated* from it (see
/// `test/tools/brand_assets_test.dart` in the app) instead of drifting in an
/// image editor nobody can re-run.
class BrandMarkPainter extends CustomPainter {
  const BrandMarkPainter({this.background = true});

  /// False renders the strands alone on transparency — the adaptive-icon
  /// foreground layer, and the form used on top of in-app gradients.
  final bool background;

  static const Color gradientStart = Color(0xFF5B4FE9);
  static const Color gradientEnd = Color(0xFF12B5A0);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;

    if (background) {
      final tile = RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(s * 0.22),
      );
      canvas.drawRRect(
        tile,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [gradientStart, gradientEnd],
          ).createShader(Offset.zero & size),
      );
    }

    // The plait: two strands swapping sides three times. The weave reads
    // through the *gap*: at every crossing the lower strand is erased along
    // the upper one's path, so the tile (or transparency, for the adaptive
    // foreground) shows through a clean channel — no shadows, no halos.
    final w = s * 0.125;
    final x1 = s * 0.355;
    final x2 = s * 0.645;
    final top = s * 0.17;
    final bottom = s * 0.83;
    const rows = 3;
    final rowH = (bottom - top) / rows;

    Path segment(double fromX, double toX, double y0) {
      final y1 = y0 + rowH;
      final my = (y0 + y1) / 2;
      return Path()
        ..moveTo(fromX, y0)
        ..cubicTo(fromX, my, toX, my, toX, y1);
    }

    Paint stroke(Color color, double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..color = color;

    final gap = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 1.85
      ..strokeCap = StrokeCap.round
      ..blendMode = BlendMode.clear;
    final strandA = stroke(Colors.white, w);
    final strandB = stroke(const Color(0xFFBFF3E8), w);

    // Each strand is one continuous path, so its tips and row junctions stay
    // whole; only the crossings are re-woven afterwards.
    final pathA = Path()..moveTo(x1, top);
    final pathB = Path()..moveTo(x2, top);
    final crossingsBOver = <Path>[];
    for (var row = 0; row < rows; row++) {
      final y = top + row * rowH;
      final aStartsLeft = row.isEven;
      final a = segment(aStartsLeft ? x1 : x2, aStartsLeft ? x2 : x1, y);
      final b = segment(aStartsLeft ? x2 : x1, aStartsLeft ? x1 : x2, y);
      pathA.addPath(a, Offset.zero);
      pathB.addPath(b, Offset.zero);
      if (row.isOdd) {
        // The middle stretch of B's row — the part that must cross *over*.
        final metric = b.computeMetrics().first;
        crossingsBOver.add(
          metric.extractPath(metric.length * 0.14, metric.length * 0.86),
        );
      }
    }

    // The strands live in their own layer so the clear-stroke erases only
    // strand paint, never the tile beneath. A is drawn last, so A crosses
    // over everywhere — then each odd row's crossing is patched: a channel
    // erased along B's middle stretch, and B repainted through it.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawPath(pathB, strandB);
    canvas.drawPath(pathA, strandA);
    for (final crossing in crossingsBOver) {
      canvas.drawPath(crossing, gap);
      canvas.drawPath(crossing, strandB);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BrandMarkPainter oldDelegate) =>
      oldDelegate.background != background;
}

/// The mark as a widget, at [size] points square.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 64, this.background = true});

  final double size;
  final bool background;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Sennit',
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: BrandMarkPainter(background: background),
      ),
    );
  }
}
