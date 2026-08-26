import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/matrix_chat_repository.dart';

/// When a conversation counts as caught up.
///
/// The badge is read off this. Getting it wrong in the permissive direction
/// hides a message; getting it wrong the other way puts a count on a chat the
/// user is looking at, which is what sending a message used to do — the reply
/// moved the newest event past every receipt in the room, so the chat went
/// unread again and reported whatever count the server still held as unseen
/// messages of the user's own.
void main() {
  const me = '@me:example.org';
  const them = '@them:example.org';

  bool read({
    String sender = them,
    String lastEventId = r'$last',
    int lastEventTs = 2000,
    String? ownUserId = me,
    String? readUpToEventId,
    String? receiptEventId,
    int? receiptTs,
  }) => isReadLocally(
    lastEventId: lastEventId,
    lastEventSenderId: sender,
    lastEventTs: lastEventTs,
    ownUserId: ownUserId,
    readUpToEventId: readUpToEventId,
    receiptEventId: receiptEventId,
    receiptTs: receiptTs,
  );

  test('a message the user just sent leaves the chat read', () {
    expect(read(sender: me), isTrue);
  });

  test('sending is enough on its own, with no receipt anywhere', () {
    expect(
      read(sender: me, receiptEventId: r'$older', receiptTs: 1),
      isTrue,
      reason: 'the stale receipt is exactly the case sending has to survive',
    );
  });

  test('an incoming message with no receipt is unread', () {
    expect(read(), isFalse);
  });

  test("this session's own receipt settles it before sync confirms", () {
    expect(read(readUpToEventId: r'$last'), isTrue);
    expect(read(readUpToEventId: r'$other'), isFalse);
  });

  test('a receipt naming the event reads it', () {
    expect(read(receiptEventId: r'$last', receiptTs: 1), isTrue);
  });

  test('a receipt younger than the event reads it', () {
    expect(read(receiptEventId: r'$other', receiptTs: 2000), isTrue);
    expect(read(receiptEventId: r'$other', receiptTs: 1999), isFalse);
  });

  test('an unknown own user id does not read a stranger\'s message', () {
    expect(read(sender: them, ownUserId: null), isFalse);
  });
}
