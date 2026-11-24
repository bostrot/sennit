import 'package:test/test.dart';
import 'package:weft_sync/weft_sync.dart';

void main() {
  test('stamps round-trip and sort as strings', () {
    const a = Hlc(1700000000000, 3, 'phone');
    const b = Hlc(1700000000000, 10, 'desk');
    expect(Hlc.parse(a.toString()), a);
    expect(b > a, isTrue);
    expect(b.toString().compareTo(a.toString()), greaterThan(0));
  });

  test('rejects malformed stamps', () {
    expect(() => Hlc.parse('nope'), throwsFormatException);
    expect(() => Hlc.parse('zz-1-'), throwsFormatException);
  });

  test('never goes backwards when the wall clock does', () {
    var now = 1000;
    final clock = HlcClock('a', now: () => now);
    final first = clock.tick();
    now = 500;
    final second = clock.tick();
    expect(second > first, isTrue);
  });

  test('moves past a stamp from a device whose clock runs ahead', () {
    final clock = HlcClock('a', now: () => 1000);
    clock.receive(const Hlc(9000, 4, 'b'));
    final next = clock.tick();
    expect(next > const Hlc(9000, 4, 'b'), isTrue);
  });
}
