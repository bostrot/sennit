import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';

/// What a self-deleting message is due, and when.
///
/// Pure arithmetic over two anchors, and worth its own suite because every
/// mistake available here is silent and irreversible: a message that expires
/// before it is read, one that never expires because a stamp was missing, a
/// policy that survives a round trip as a *different* policy. None of those
/// looks wrong on screen — the message is simply gone, or simply still there.
void main() {
  final sentAt = DateTime.utc(2026, 1, 1, 12);

  group('RetentionPolicy.off', () {
    test('is inactive and never falls due', () {
      expect(RetentionPolicy.off.isActive, isFalse);
      expect(
        RetentionPolicy.off.expiryFor(sentAt: sentAt, readAt: sentAt),
        isNull,
      );
      expect(
        RetentionPolicy.off.hasExpired(
          now: sentAt.add(const Duration(days: 3650)),
          sentAt: sentAt,
          readAt: sentAt,
        ),
        isFalse,
      );
    });

    test('a zero duration is off however it was built', () {
      const explicit = RetentionPolicy(
        after: Duration.zero,
        anchor: RetentionAnchor.read,
      );
      expect(explicit.isActive, isFalse);
      // The anchor is not a difference the user can see when nothing is
      // deleted, so two dormant policies must compare equal — a settings write
      // that "changed" only this would be a change nobody made.
      expect(explicit, RetentionPolicy.off);
      expect(explicit.hashCode, RetentionPolicy.off.hashCode);
    });
  });

  group('the arrival anchor', () {
    const policy = RetentionPolicy(after: Duration(hours: 24));

    test('counts from the message, read or not', () {
      expect(
        policy.expiryFor(sentAt: sentAt),
        sentAt.add(const Duration(hours: 24)),
      );
      expect(
        policy.expiryFor(
          sentAt: sentAt,
          readAt: sentAt.add(const Duration(days: 5)),
        ),
        sentAt.add(const Duration(hours: 24)),
      );
    });

    test('falls due at the instant itself, not a tick later', () {
      expect(
        policy.hasExpired(
          now: sentAt.add(const Duration(hours: 24)),
          sentAt: sentAt,
        ),
        isTrue,
      );
      expect(
        policy.hasExpired(
          now: sentAt.add(const Duration(hours: 23, minutes: 59)),
          sentAt: sentAt,
        ),
        isFalse,
      );
    });
  });

  group('the read anchor', () {
    const policy = RetentionPolicy(
      after: Duration(hours: 1),
      anchor: RetentionAnchor.read,
    );

    test('an unread message never falls due', () {
      expect(policy.expiryFor(sentAt: sentAt), isNull);
      // However long it waits. A messenger that deleted mail nobody had read
      // would be losing it, not expiring it.
      expect(
        policy.hasExpired(
          now: sentAt.add(const Duration(days: 365)),
          sentAt: sentAt,
        ),
        isFalse,
      );
    });

    test('counts from the read stamp', () {
      final readAt = sentAt.add(const Duration(days: 2));
      expect(
        policy.expiryFor(sentAt: sentAt, readAt: readAt),
        readAt.add(const Duration(hours: 1)),
      );
    });

    test('a read stamp older than the message counts from the message', () {
      // A backfilled message can land behind a read marker recorded before it
      // arrived. Anchoring on the stamp would make it expire the moment it was
      // first seen — deleted in the same sweep that discovered it.
      final readAt = sentAt.subtract(const Duration(hours: 6));
      expect(
        policy.expiryFor(sentAt: sentAt, readAt: readAt),
        sentAt.add(const Duration(hours: 1)),
      );
      expect(
        policy.hasExpired(now: sentAt, sentAt: sentAt, readAt: readAt),
        isFalse,
      );
    });
  });

  group('serialisation', () {
    test('a policy survives a round trip', () {
      const policy = RetentionPolicy(
        after: Duration(days: 7),
        anchor: RetentionAnchor.read,
      );
      expect(RetentionPolicy.fromJson(policy.toJson()), policy);
    });

    test('an unreadable blob degrades to nothing rather than to a guess', () {
      // Not to a default duration: the failure mode of guessing wrong here is
      // deleted messages, and there is no undo for those.
      expect(RetentionPolicy.fromJson(null), isNull);
      expect(RetentionPolicy.fromJson('7 days'), isNull);
      expect(RetentionPolicy.fromJson(<String, Object?>{}), isNull);
      expect(RetentionPolicy.fromJson({'seconds': '600'}), isNull);
      expect(RetentionPolicy.fromJson({'seconds': -1}), isNull);
    });

    test('an unknown anchor reads as the arrival one', () {
      final policy = RetentionPolicy.fromJson({
        'seconds': 3600,
        'anchor': 'when-the-moon-is-full',
      });
      expect(policy?.anchor, RetentionAnchor.arrival);
      expect(policy?.after, const Duration(hours: 1));
    });
  });

  group('RetentionSettings', () {
    const policy = RetentionPolicy(after: Duration(hours: 12));

    test('an empty map is dormant and answers off for every chat', () {
      expect(RetentionSettings.empty.isDormant, isTrue);
      expect(RetentionSettings.empty.forChat('!room:x'), RetentionPolicy.off);
    });

    test('setting a policy makes exactly that chat self-delete', () {
      final settings = RetentionSettings.empty.withChat('!a:x', policy);
      expect(settings.isDormant, isFalse);
      expect(settings.forChat('!a:x'), policy);
      expect(settings.forChat('!b:x'), RetentionPolicy.off);
    });

    test('turning it off leaves no entry behind', () {
      final settings = RetentionSettings.empty
          .withChat('!a:x', policy)
          .withChat('!a:x', RetentionPolicy.off);
      expect(settings.byChat, isEmpty);
      expect(settings.isDormant, isTrue);
    });

    test('the map survives a round trip', () {
      final settings = RetentionSettings.empty
          .withChat('!a:x', policy)
          .withChat(
            '!b:x',
            const RetentionPolicy(
              after: Duration(minutes: 30),
              anchor: RetentionAnchor.read,
            ),
          );
      expect(RetentionSettings.fromJson(settings.toJson()), settings);
    });

    test('a chat whose policy is unreadable is dropped, the rest survive', () {
      final settings = RetentionSettings.fromJson({
        'chats': {
          '!good:x': {'seconds': 3600, 'anchor': 'read'},
          '!bad:x': 'every tuesday',
          42: {'seconds': 3600},
        },
      });
      expect(settings.byChat.keys, ['!good:x']);
      expect(settings.forChat('!bad:x'), RetentionPolicy.off);
    });

    test('a blob that is not a policy map at all reads as empty', () {
      expect(RetentionSettings.fromJson(null), RetentionSettings.empty);
      expect(RetentionSettings.fromJson({'chats': 7}), RetentionSettings.empty);
    });
  });
}
