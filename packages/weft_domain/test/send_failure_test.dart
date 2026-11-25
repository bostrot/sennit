import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';

void main() {
  group('SendQueue', () {
    test('retries only what a lost connection stopped, oldest first', () {
      final queue = SendQueue()
        ..record('a', '!one', SendFailure.offline)
        ..record('b', '!one', SendFailure.tooLarge)
        ..record('c', '!two', SendFailure.offline)
        ..record('d', '!two', SendFailure.notAllowed)
        ..record('e', '!two', SendFailure.rejected);

      expect(queue.dueForRetry, [('a', '!one'), ('c', '!two')]);
    });

    test('a send that fails again moves to the back', () {
      final queue = SendQueue()
        ..record('a', '!one', SendFailure.offline)
        ..record('b', '!one', SendFailure.offline)
        ..record('a', '!one', SendFailure.rejected)
        ..record('a', '!one', SendFailure.offline);

      expect(queue.dueForRetry.map((e) => e.$1), ['b', 'a']);
    });

    test('says whether anything changed', () {
      final queue = SendQueue();
      expect(queue.record('a', '!one', SendFailure.offline), isTrue);
      expect(queue.record('a', '!one', SendFailure.offline), isFalse);
      expect(queue.record('a', '!one', SendFailure.rejected), isTrue);
      expect(queue.clear('a'), isTrue);
      expect(queue.clear('a'), isFalse);
      expect(queue.isEmpty, isTrue);
    });

    test('survives a round trip and skips rows it cannot read', () {
      final queue = SendQueue()
        ..record('a', '!one', SendFailure.offline)
        ..record('b', '!two', SendFailure.tooLarge);
      final json = {
        ...queue.toJson(),
        'broken': 'not a map',
        'unknown': {'room': '!x', 'why': 'gremlins'},
        'roomless': {'why': 'offline'},
      };

      final restored = SendQueue.fromJson(json);

      expect(restored.failures, {
        'a': SendFailure.offline,
        'b': SendFailure.tooLarge,
      });
      expect(restored.dueForRetry, [('a', '!one')]);
      expect(SendQueue.fromJson(null).isEmpty, isTrue);
    });
  });

  test('only a lost connection heals by itself', () {
    expect(SendFailure.values.where((f) => f.retriesAutomatically), [
      SendFailure.offline,
    ]);
  });
}
