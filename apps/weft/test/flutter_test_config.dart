import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final base = goldenFileComparator;
  if (base is LocalFileComparator) {
    goldenFileComparator = _TolerantGoldenComparator(
      // LocalFileComparator wants the test file's uri and only keeps its
      // directory; the name after basedir is never read.
      Uri.parse('${base.basedir}config_test.dart'),
    );
  }
  await testMain();
}

/// The stock comparator with a hair of tolerance.
///
/// The golden files are rendered on this project's development Mac, and every
/// macOS release rasterizes anti-aliased edges a hair differently: the hosted
/// runners drift by 0.01–0.02% of pixels against the checked-in images, spread
/// one pixel wide along glyph and curve boundaries. A real regression moves
/// whole widgets — orders of magnitude past the threshold — so 0.1% keeps the
/// suite meaningful everywhere without chaining the goldens to one OS build.
class _TolerantGoldenComparator extends LocalFileComparator {
  _TolerantGoldenComparator(super.testFile);

  static const double _tolerance = 0.001;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed) return true;
    if (result.diffPercent <= _tolerance) {
      debugPrint(
        'golden $golden: accepting '
        '${(result.diffPercent * 100).toStringAsFixed(3)}% pixel drift',
      );
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    throw FlutterError(error);
  }
}
