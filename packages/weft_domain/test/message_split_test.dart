import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';

void main() {
  group('textLimitFor', () {
    test('caps the networks that cap a message', () {
      expect(textLimitFor(ChatNetwork.telegram), 4096);
      expect(textLimitFor(ChatNetwork.discord), 2000);
    });

    test('leaves the rest alone', () {
      expect(textLimitFor(ChatNetwork.matrix), isNull);
      expect(textLimitFor(ChatNetwork.whatsapp), isNull);
      expect(textLimitFor(ChatNetwork.sms), isNull);
    });
  });

  group('splitForLimit', () {
    test('a body that fits is one piece, untouched', () {
      expect(splitForLimit('  hello  ', 20), ['  hello  ']);
    });

    test('prefers a paragraph break', () {
      final first = 'a' * 30;
      final second = 'b ' * 10;
      expect(splitForLimit('$first\n\n${second.trim()}', 40), [
        first,
        second.trim(),
      ]);
    });

    test('then a line break', () {
      expect(splitForLimit('one two three\nfour five six', 20), [
        'one two three',
        'four five six',
      ]);
    });

    test('then the end of a sentence', () {
      expect(splitForLimit('First one here. Second one is long', 24), [
        'First one here.',
        'Second one is long',
      ]);
    });

    test('a sentence in Chinese ends without a space', () {
      expect(splitForLimit('今天天气很好。我们去公园散步吧', 10), ['今天天气很好。', '我们去公园散步吧']);
    });

    test('then a space', () {
      expect(splitForLimit('alpha beta gamma delta', 12), [
        'alpha beta',
        'gamma delta',
      ]);
    });

    test('a break too early is passed over for a fuller piece', () {
      final pieces = splitForLimit('a\n${'word ' * 10}', 20);
      expect(pieces.first.length, greaterThan(10));
      expect(pieces.every((p) => p.length <= 20), isTrue);
    });

    test('a run with no space is cut hard', () {
      expect(splitForLimit('x' * 25, 10), ['x' * 10, 'x' * 10, 'x' * 5]);
    });

    test('never cuts through a surrogate pair', () {
      final body = '${'x' * 9}😀${'y' * 5}';
      final pieces = splitForLimit(body, 10);
      expect(pieces, ['x' * 9, '😀${'y' * 5}']);
    });

    test('every piece fits and no word is lost', () {
      final body = List.generate(400, (i) => 'word$i').join(' ');
      final pieces = splitForLimit(body, 100);
      expect(pieces.every((p) => p.length <= 100), isTrue);
      expect(pieces.join(' '), body);
    });

    test('a limit too small to make progress is refused', () {
      expect(() => splitForLimit('abc', 1), throwsArgumentError);
    });
  });
}
