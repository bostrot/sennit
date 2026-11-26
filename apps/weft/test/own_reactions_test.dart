import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/own_reactions.dart';

/// The user's own reactions, as the repository records them for
/// `Chat.reactedUpTo`: which events count, and what a redaction undoes.
void main() {
  final t0 = DateTime.utc(2026, 11, 25, 12);

  group('ownReactionTarget', () {
    String? target({
      String type = 'm.reaction',
      String eventId = r'$reaction',
      String senderId = '@me:example.org',
      String relType = 'm.annotation',
    }) => ownReactionTarget(
      type: type,
      eventId: eventId,
      senderId: senderId,
      content: {
        'm.relates_to': {
          'rel_type': relType,
          'event_id': r'$message',
          'key': '👍',
        },
      },
      isOwn: (sender) =>
          sender == '@me:example.org' || sender == '@whatsapp_me:example.org',
    );

    test('my reaction names the message it is on', () {
      expect(target(), r'$message');
    });

    test('a bridged reaction of mine counts', () {
      expect(target(senderId: '@whatsapp_me:example.org'), r'$message');
    });

    test('an encrypted reaction counts by its clear relation', () {
      expect(target(type: 'm.room.encrypted'), r'$message');
    });

    test("others' reactions do not count", () {
      expect(target(senderId: '@them:example.org'), isNull);
    });

    test('a local echo, an edit or a message is not a reaction', () {
      expect(target(eventId: 'txn-1'), isNull);
      expect(target(relType: 'm.replace'), isNull);
      expect(target(type: 'm.room.message'), isNull);
    });
  });

  group('OwnReactionLog', () {
    test('the newest message reacted to wins', () {
      final log = OwnReactionLog()
        ..record('!a', r'$r1', t0)
        ..record('!a', r'$r2', t0.add(const Duration(minutes: 5)));
      expect(log.reactedUpTo('!a'), t0.add(const Duration(minutes: 5)));
      expect(log.reactedUpTo('!b'), isNull);
    });

    test('a redaction takes back exactly that reaction', () {
      final log = OwnReactionLog()
        ..record('!a', r'$old', t0)
        ..record('!a', r'$new', t0.add(const Duration(minutes: 5)));
      expect(log.redact('!a', r'$new'), isTrue);
      expect(log.reactedUpTo('!a'), t0);
      expect(log.redact('!a', r'$someone_elses'), isFalse);
      expect(log.redact('!a', r'$old'), isTrue);
      expect(log.reactedUpTo('!a'), isNull);
    });

    test('recording the same reaction twice is no change', () {
      final log = OwnReactionLog();
      expect(log.record('!a', r'$r', t0), isTrue);
      expect(log.record('!a', r'$r', t0), isFalse);
    });

    test('keeps only the newest few per room', () {
      final log = OwnReactionLog();
      for (var i = 0; i <= OwnReactionLog.perRoom; i++) {
        log.record('!a', '\$r$i', t0.add(Duration(minutes: i)));
      }
      // The oldest was dropped, so redacting it changes nothing.
      expect(log.redact('!a', r'$r0'), isFalse);
      expect(
        log.record('!a', r'$ancient', t0.subtract(const Duration(days: 1))),
        isFalse,
      );
    });

    test('round-trips and skips malformed rows', () {
      final log = OwnReactionLog()..record('!a', r'$r', t0);
      final back = OwnReactionLog.fromJson(log.toJson());
      expect(back.reactedUpTo('!a'), t0);
      final bad = OwnReactionLog.fromJson({
        '!a': {r'$r': 'soon'},
        '!b': 3,
      });
      expect(bad.reactedUpTo('!a'), isNull);
      expect(OwnReactionLog.fromJson(null).reactedUpTo('!a'), isNull);
    });
  });
}
