import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

/// The persistence behind self-deleting chats: which chats erase themselves,
/// when each was read, and what has already gone.
///
/// The read-anchored cutoff is the part that earns a suite of its own. It turns
/// "when was the conversation first read past this message" into one comparable
/// instant, and every way of getting that wrong deletes something early or
/// never deletes it at all.
void main() {
  late WeftDatabase db;
  late RetentionStore store;
  late SearchStore search;

  final now = DateTime.utc(2026, 3, 1, 12);

  setUp(() {
    db = WeftDatabase.openAt(':memory:');
    store = RetentionStore(db, SettingsStore(db));
    search = SearchStore(db);
  });

  tearDown(() => db.dispose());

  WeftMessage msg(
    String eventId, {
    required DateTime at,
    String roomId = '!room:example.org',
    String sender = '@peer:example.org',
    MessageKind kind = MessageKind.text,
    String? attachmentUrl,
  }) {
    return WeftMessage(
      eventId: eventId,
      roomId: roomId,
      network: ChatNetwork.whatsapp,
      senderId: sender,
      senderName: 'Peer',
      timestamp: at,
      kind: kind,
      isOwn: false,
      body: 'body of $eventId',
      attachmentUrl: attachmentUrl,
    );
  }

  group('policies', () {
    const policy = RetentionPolicy(after: Duration(hours: 6));

    test('a chat with no policy keeps everything', () {
      expect(store.load(), RetentionSettings.empty);
      expect(store.load().forChat('c1'), RetentionPolicy.off);
    });

    test('a saved policy survives a re-open of the store', () {
      store.save(RetentionSettings.empty.withChat('c1', policy));

      final reopened = RetentionStore(db, SettingsStore(db));
      expect(reopened.load().forChat('c1'), policy);
    });

    test('turning every chat off removes the row rather than blanking it', () {
      final settings = SettingsStore(db);
      store.save(RetentionSettings.empty.withChat('c1', policy));
      expect(settings.getString(WeftSettings.retentionPolicies), isNotNull);

      store.save(RetentionSettings.empty.withChat('c1', RetentionPolicy.off));
      expect(
        settings.getString(WeftSettings.retentionPolicies),
        isNull,
        reason: 'an empty blob still reads as "this user configured retention"',
      );
      expect(store.load(), RetentionSettings.empty);
    });
  });

  group('read marks', () {
    test('a message read after it arrived carries the read instant', () {
      final sentAt = now.subtract(const Duration(hours: 3));
      store.recordRead(chatId: 'c1', at: now, upTo: sentAt);

      expect(store.readAtFor(chatId: 'c1', sentAt: sentAt), now);
    });

    test('a message nobody has read past has no stamp', () {
      store.recordRead(
        chatId: 'c1',
        at: now,
        upTo: now.subtract(const Duration(hours: 3)),
      );

      expect(
        store.readAtFor(
          chatId: 'c1',
          sentAt: now.subtract(const Duration(hours: 1)),
        ),
        isNull,
      );
    });

    test('re-opening the chat does not restart an older message clock', () {
      final sentAt = now.subtract(const Duration(days: 7));
      final firstRead = now.subtract(const Duration(days: 7));
      store.recordRead(chatId: 'c1', at: firstRead, upTo: sentAt);
      store.recordRead(chatId: 'c1', at: now, upTo: now);

      expect(
        store.readAtFor(chatId: 'c1', sentAt: sentAt),
        firstRead,
        reason: 'a message read a week ago was read a week ago',
      );
    });

    test('two reads in the same millisecond keep the further watermark', () {
      store.recordRead(
        chatId: 'c1',
        at: now,
        upTo: now.subtract(const Duration(hours: 2)),
      );
      store.recordRead(chatId: 'c1', at: now, upTo: now);

      expect(store.readMarks('c1'), hasLength(1));
      expect(store.readMarks('c1').single.upTo, now);
    });

    test('pruning keeps the newest ripened mark so nothing loses its stamp', () {
      final oldest = now.subtract(const Duration(days: 9));
      final middle = now.subtract(const Duration(days: 8));
      final recent = now.subtract(const Duration(hours: 1));
      store.recordRead(chatId: 'c1', at: oldest, upTo: oldest);
      store.recordRead(chatId: 'c1', at: middle, upTo: middle);
      store.recordRead(chatId: 'c1', at: recent, upTo: recent);

      store.pruneReadMarks(
        chatId: 'c1',
        before: now.subtract(const Duration(days: 7)),
      );

      final kept = store.readMarks('c1').map((m) => m.readAt).toList();
      expect(kept, [recent, middle]);
      // The survivor of a failed sweep still has a stamp, and so still expires.
      expect(store.readAtFor(chatId: 'c1', sentAt: oldest), middle);
    });

    test('a chat that is only ever read keeps a bounded number of marks', () {
      // `markRead` records unconditionally, so that a policy set next month can
      // count from reads that happened before it existed. Without a ceiling
      // that is a row per chat opening for the life of the install.
      for (var i = 0; i < RetentionStore.maxReadMarksPerChat + 20; i++) {
        final at = now.subtract(Duration(minutes: i));
        store.recordRead(chatId: 'c1', at: at, upTo: at);
      }

      final marks = store.readMarks('c1');
      expect(marks, hasLength(RetentionStore.maxReadMarksPerChat));
      expect(
        marks.first.readAt,
        now,
        reason: 'the newest is what a later policy counts from',
      );
    });

    test('pruning leaves another chat alone', () {
      final old = now.subtract(const Duration(days: 9));
      store.recordRead(chatId: 'c1', at: old, upTo: old);
      store.recordRead(chatId: 'c2', at: old, upTo: old);
      store.recordRead(chatId: 'c2', at: now, upTo: now);

      store.pruneReadMarks(chatId: 'c1', before: now);

      expect(store.readMarks('c2'), hasLength(2));
    });
  });

  group('candidates', () {
    void index(
      String eventId,
      DateTime at, {
      String sender = '@peer:example.org',
    }) {
      search.indexMessage(
        msg(eventId, at: at, sender: sender),
        chatId: 'c1',
      );
    }

    test('an inactive policy is due nothing, however old the chat', () {
      index(r'$old', now.subtract(const Duration(days: 400)));

      expect(
        store.candidates(chatId: 'c1', policy: RetentionPolicy.off, now: now),
        isEmpty,
      );
    });

    group('anchored on arrival', () {
      const policy = RetentionPolicy(after: Duration(hours: 24));

      test('picks up what is past its window and leaves the rest', () {
        index(r'$due', now.subtract(const Duration(hours: 25)));
        index(r'$fresh', now.subtract(const Duration(hours: 23)));

        final due = store.candidates(chatId: 'c1', policy: policy, now: now);
        expect(due.map((c) => c.eventId), [r'$due']);
      });

      test('carries what the deletion needs to know', () {
        search.indexMessage(
          msg(
            r'$photo',
            at: now.subtract(const Duration(days: 2)),
            sender: '@me:example.org',
            kind: MessageKind.image,
            attachmentUrl: 'mxc://example.org/photo',
          ),
          chatId: 'c1',
        );

        final due = store
            .candidates(chatId: 'c1', policy: policy, now: now)
            .single;
        expect(due.senderId, '@me:example.org');
        expect(
          due.hasMedia,
          isTrue,
          reason: 'staged bytes outlive a row delete',
        );
        expect(due.roomId, '!room:example.org');
      });

      test('another chat is not swept by this one policy', () {
        search.indexMessage(
          msg(r'$other', at: now.subtract(const Duration(days: 5))),
          chatId: 'c2',
        );

        expect(
          store.candidates(chatId: 'c1', policy: policy, now: now),
          isEmpty,
        );
      });

      test('one pass is bounded, and the oldest go first', () {
        for (var i = 0; i < 5; i++) {
          index('\$m$i', now.subtract(Duration(days: 10 - i)));
        }

        final due = store.candidates(
          chatId: 'c1',
          policy: policy,
          now: now,
          limit: 2,
        );
        expect(due.map((c) => c.eventId), [r'$m0', r'$m1']);
      });
    });

    group('anchored on read', () {
      const policy = RetentionPolicy(
        after: Duration(hours: 1),
        anchor: RetentionAnchor.read,
      );

      test('a chat nobody has read is due nothing, however old', () {
        index(r'$old', now.subtract(const Duration(days: 30)));

        expect(
          store.candidates(chatId: 'c1', policy: policy, now: now),
          isEmpty,
        );
      });

      test('a message read an hour ago is due, one read just now is not', () {
        final sentAt = now.subtract(const Duration(days: 2));
        final later = now.subtract(const Duration(minutes: 30));
        index(r'$read', sentAt);
        index(r'$justRead', later);

        store.recordRead(
          chatId: 'c1',
          at: now.subtract(const Duration(hours: 2)),
          upTo: sentAt,
        );
        store.recordRead(chatId: 'c1', at: now, upTo: later);

        final due = store.candidates(chatId: 'c1', policy: policy, now: now);
        expect(due.map((c) => c.eventId), [r'$read']);
      });

      test('a message that arrived after the last read is never due', () {
        final sentAt = now.subtract(const Duration(days: 2));
        index(r'$read', sentAt);
        // Arrived while the phone was locked: read marks stop before it.
        index(r'$unread', now.subtract(const Duration(hours: 6)));
        store.recordRead(
          chatId: 'c1',
          at: now.subtract(const Duration(days: 2)),
          upTo: sentAt,
        );

        final due = store.candidates(chatId: 'c1', policy: policy, now: now);
        expect(due.map((c) => c.eventId), [r'$read']);
      });

      test('the window still has to pass after the read', () {
        final sentAt = now.subtract(const Duration(days: 2));
        index(r'$read', sentAt);
        store.recordRead(
          chatId: 'c1',
          at: now.subtract(const Duration(minutes: 20)),
          upTo: sentAt,
        );

        expect(
          store.candidates(chatId: 'c1', policy: policy, now: now),
          isEmpty,
        );
      });
    });
  });

  group('tombstones', () {
    test('a purged event is remembered per room', () {
      store.markPurged(roomId: '!a:x', eventId: r'$1', at: now);

      expect(store.isPurged(roomId: '!a:x', eventId: r'$1'), isTrue);
      expect(
        store.isPurged(roomId: '!b:x', eventId: r'$1'),
        isFalse,
        reason: 'an event id is only unique within its room',
      );
      expect(store.purgedIn('!a:x'), {r'$1'});
      expect(store.purgedIn('!b:x'), isEmpty);
    });

    test('purging the same event twice is not an error', () {
      store.markPurged(roomId: '!a:x', eventId: r'$1', at: now);
      store.markPurged(
        roomId: '!a:x',
        eventId: r'$1',
        at: now.add(const Duration(days: 1)),
      );

      expect(store.purgedCount, 1);
    });
  });
}
