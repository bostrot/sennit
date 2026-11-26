import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Sennit Web copies through `navigator.clipboard`, which a browser leaves out
/// of a page served over plain http — and the phone serves it so on the local
/// network. `web/clipboard_fallback.js` stands in for it; these keep it there.
void main() {
  final page = File('web/index.html').readAsStringSync();

  test('the fallback is loaded, and before the engine', () {
    final fallback = page.indexOf('<script src="clipboard_fallback.js">');
    final engine = page.indexOf('<script src="flutter_bootstrap.js"');
    expect(fallback, isNonNegative);
    expect(engine, isNonNegative);
    expect(
      fallback,
      lessThan(engine),
      reason:
          'the engine reads navigator.clipboard when it copies; the '
          'stand-in has to be there first, and loaded synchronously',
    );
    expect(page, isNot(contains('clipboard_fallback.js" async')));
  });

  test('the fallback steps aside where the real clipboard exists', () {
    final script = File('web/clipboard_fallback.js').readAsStringSync();
    expect(script, contains('if (navigator.clipboard) return;'));
    expect(script, contains("execCommand('copy')"));
  });
}
