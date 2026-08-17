import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';

void main() {
  final now = DateTime.utc(2026, 8, 17, 12);

  group('planPushRuleSync', () {
    test('a bypassable mute is never pushed to the homeserver', () {
      // The default. A mention is supposed to break through a muted chat, and
      // it cannot do that if the homeserver was told not to send the push.
      final changes = planPushRuleSync(
        policy: NotificationPolicy().muteChat('!wa:example.org'),
        chats: [_chat()],
        now: now,
        isServerMuted: (_) => false,
      );

      expect(changes, isEmpty);
    });

    test('an unbypassable mute is pushed down', () {
      final changes = planPushRuleSync(
        policy: NotificationPolicy(
          mentionsBypassMute: false,
        ).muteChat('!wa:example.org'),
        chats: [_chat()],
        now: now,
        isServerMuted: (_) => false,
      );

      expect(changes, [
        const PushRuleChange(roomId: '!wa:example.org', muted: true),
      ]);
    });

    test('muting a merged chat mutes every leg', () {
      final changes = planPushRuleSync(
        policy: NotificationPolicy(
          mentionsBypassMute: false,
        ).muteChat('merged:contact_1'),
        chats: [_mergedChat()],
        now: now,
        isServerMuted: (_) => false,
      );

      expect(changes.map((c) => c.roomId), [
        '!wa:example.org',
        '!sig:example.org',
      ]);
      expect(changes.every((c) => c.muted), isTrue);
    });

    test('a disabled network is pushed down even though mentions bypass', () {
      // `disabledNetworks` is the one suppression nothing breaks through, which
      // is the whole reason it is a separate field from `mutedNetworks`.
      final changes = planPushRuleSync(
        policy: NotificationPolicy(disabledNetworks: {ChatNetwork.whatsapp}),
        chats: [_mergedChat()],
        now: now,
        isServerMuted: (_) => false,
      );

      expect(changes, [
        const PushRuleChange(roomId: '!wa:example.org', muted: true),
      ]);
    });

    test('a muted network is only pushed down when it cannot be bypassed', () {
      Iterable<PushRuleChange> plan({required bool bypass}) => planPushRuleSync(
        policy: NotificationPolicy(
          mentionsBypassMute: bypass,
          mutedNetworks: {ChatNetwork.signal},
        ),
        chats: [_mergedChat()],
        now: now,
        isServerMuted: (_) => false,
      );

      expect(plan(bypass: true), isEmpty);
      expect(plan(bypass: false).map((c) => c.roomId), ['!sig:example.org']);
    });

    test('the global switch is never pushed to the homeserver', () {
      // Push rules are account data: every client the user runs obeys them.
      // Weft's master toggle is this app's preference, not the account's.
      final changes = planPushRuleSync(
        policy: NotificationPolicy(enabled: false, mentionsBypassMute: false),
        chats: [_mergedChat()],
        now: now,
        isServerMuted: (_) => false,
      );

      expect(changes, isEmpty);
    });

    test('quiet hours are never pushed to the homeserver', () {
      final changes = planPushRuleSync(
        policy: NotificationPolicy(
          mentionsBypassMute: false,
          quietHours: const QuietHours(startMinute: 0, endMinute: 1439),
        ),
        chats: [_mergedChat()],
        now: now,
        isServerMuted: (_) => false,
      );

      expect(changes, isEmpty);
    });

    test('a rule already in place is not written again', () {
      final changes = planPushRuleSync(
        policy: NotificationPolicy(
          mentionsBypassMute: false,
        ).muteChat('!wa:example.org'),
        chats: [_chat()],
        now: now,
        isServerMuted: (_) => true,
      );

      expect(changes, isEmpty);
    });

    test('an expired timed mute lifts the server rule', () {
      // The case that only Weft can fix: Matrix push rules have no expiry, so
      // "mute for an hour" leaves a rule behind that nothing else will clear.
      final policy = NotificationPolicy(mentionsBypassMute: false).muteChat(
        '!wa:example.org',
        until: now.subtract(const Duration(minutes: 1)),
      );

      final changes = planPushRuleSync(
        policy: policy,
        chats: [_chat()],
        now: now,
        isServerMuted: (_) => true,
      );

      expect(changes, [
        const PushRuleChange(roomId: '!wa:example.org', muted: false),
      ]);
    });

    test('a timed mute still running leaves the rule alone', () {
      final policy = NotificationPolicy(
        mentionsBypassMute: false,
      ).muteChat('!wa:example.org', until: now.add(const Duration(hours: 1)));

      expect(
        planPushRuleSync(
          policy: policy,
          chats: [_chat()],
          now: now,
          isServerMuted: (_) => true,
        ),
        isEmpty,
      );
    });

    test('an expiry exactly at now has passed', () {
      final policy = NotificationPolicy(
        mentionsBypassMute: false,
      ).muteChat('!wa:example.org', until: now);

      expect(
        planPushRuleSync(
          policy: policy,
          chats: [_chat()],
          now: now,
          isServerMuted: (_) => true,
        ),
        [const PushRuleChange(roomId: '!wa:example.org', muted: false)],
      );
    });

    test('an indefinite mute beside a lapsed one keeps the rule', () {
      final policy = NotificationPolicy(mentionsBypassMute: false)
          .withChatOverride(
            '!wa:example.org',
            ChatNotificationOverride(
              muted: true,
              mutedUntil: now.subtract(const Duration(days: 1)),
            ),
          );

      expect(
        planPushRuleSync(
          policy: policy,
          chats: [_chat()],
          now: now,
          isServerMuted: (_) => true,
        ),
        isEmpty,
      );
    });

    test('a server mute Weft never asked for is left alone', () {
      // It may be the user's Element mute. The same rule id serves both, so
      // there is no way to tell — and clearing theirs is the worse mistake.
      expect(
        planPushRuleSync(
          policy: NotificationPolicy(),
          chats: [_mergedChat()],
          now: now,
          isServerMuted: (_) => true,
        ),
        isEmpty,
      );
    });

    test('an unsynced room is skipped rather than guessed at', () {
      expect(
        planPushRuleSync(
          policy: NotificationPolicy(
            mentionsBypassMute: false,
          ).muteChat('!wa:example.org'),
          chats: [_chat()],
          now: now,
          isServerMuted: (_) => null,
        ),
        isEmpty,
      );
    });
  });

  group('MatrixPushRuleSync', () {
    test('applies the plan and reports what it changed', () async {
      final target = _FakeTarget({'!wa:example.org': false});
      final sync = MatrixPushRuleSync(target);

      final applied = await sync.reconcile(
        policy: NotificationPolicy(
          mentionsBypassMute: false,
        ).muteChat('!wa:example.org'),
        chats: [_chat()],
        now: now,
      );

      expect(applied, [
        const PushRuleChange(roomId: '!wa:example.org', muted: true),
      ]);
      expect(target.muted['!wa:example.org'], isTrue);
    });

    test('is a no-op when the homeserver already agrees', () async {
      final target = _FakeTarget({'!wa:example.org': true});
      final sync = MatrixPushRuleSync(target);

      final applied = await sync.reconcile(
        policy: NotificationPolicy(
          mentionsBypassMute: false,
        ).muteChat('!wa:example.org'),
        chats: [_chat()],
        now: now,
      );

      expect(applied, isEmpty);
      expect(target.writes, 0);
    });

    test('one refused room does not stop the others', () async {
      final target = _FakeTarget(
        {'!wa:example.org': false, '!sig:example.org': false},
        refuse: {'!wa:example.org'},
      );

      final applied = await MatrixPushRuleSync(target).reconcile(
        policy: NotificationPolicy(
          mentionsBypassMute: false,
        ).muteChat('merged:contact_1'),
        chats: [_mergedChat()],
        now: now,
      );

      expect(applied.map((c) => c.roomId), ['!sig:example.org']);
      expect(target.muted['!sig:example.org'], isTrue);
    });
  });
}

Chat _chat() => const Chat(
  id: '!wa:example.org',
  title: 'Sam',
  sources: [
    ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
  ],
);

/// One contact, two legs — the shape every grouping decision has to survive.
Chat _mergedChat() => const Chat(
  id: 'merged:contact_1',
  title: 'Sam',
  contactId: 'contact_1',
  sources: [
    ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
    ChatSource(roomId: '!sig:example.org', network: ChatNetwork.signal),
  ],
);

class _FakeTarget implements MatrixPushRuleTarget {
  _FakeTarget(this.muted, {this.refuse = const {}});

  final Map<String, bool> muted;
  final Set<String> refuse;
  int writes = 0;

  @override
  bool? isMuted(String roomId) => muted[roomId];

  @override
  Future<void> setMuted(String roomId, {required bool muted}) async {
    writes++;
    if (refuse.contains(roomId)) {
      throw Exception('the server refused $roomId');
    }
    this.muted[roomId] = muted;
  }
}
