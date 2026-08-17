import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

import 'support/fixtures.dart';

/// Calls [evaluateNotification] with the fixture user and a default policy, so
/// each test states only the rule it is about.
NotificationDecision decide({
  WeftMessage? message,
  Chat? forChat,
  NotificationPolicy? policy,
  DateTime? at,
  DateTime? lastReadAt,
  NotificationDedupe? dedupe,
}) {
  return evaluateNotification(
    message: message ?? msg(),
    chat: forChat ?? chat(),
    policy: policy ?? NotificationPolicy(),
    now: at ?? now,
    lastReadAt: lastReadAt,
    ownUserIds: ownUserIds,
    ownDisplayNames: ownDisplayNames,
    dedupe: dedupe,
  );
}

NotificationSuppression? reasonFor(NotificationDecision decision) =>
    decision.suppression;

void main() {
  group('the ordinary case', () {
    test('an incoming text message notifies', () {
      final decision = decide();
      expect(decision, const NotifyDecision());
      expect(decision.delivers, isTrue);
      expect(decision.mentioned, isFalse);
      expect(decision.suppression, isNull);
    });
  });

  group('suppression rules', () {
    test('own messages never notify', () {
      expect(
        reasonFor(decide(message: msg(isOwn: true))),
        NotificationSuppression.ownMessage,
      );
    });

    test('a message from one of the user own ids never notifies', () {
      // The bridge echo of a message sent from the phone arrives with isOwn
      // unset often enough that the sender id is checked too.
      expect(
        reasonFor(decide(message: msg(senderId: '@ada:example.org'))),
        NotificationSuppression.ownMessage,
      );
    });

    test('redacted events never notify', () {
      expect(
        reasonFor(decide(message: msg(redacted: true, body: ''))),
        NotificationSuppression.redacted,
      );
    });

    test('state events never notify', () {
      expect(
        reasonFor(decide(message: msg(kind: MessageKind.event))),
        NotificationSuppression.nonMessageEvent,
      );
    });

    test('the global switch stops everything', () {
      expect(
        reasonFor(decide(policy: NotificationPolicy(enabled: false))),
        NotificationSuppression.globallyDisabled,
      );
    });

    test('a message older than the read marker was read elsewhere', () {
      expect(
        reasonFor(
          decide(
            message: msg(timestamp: now.subtract(const Duration(minutes: 5))),
            lastReadAt: now,
          ),
        ),
        NotificationSuppression.alreadyRead,
      );
    });

    test('a message stamped exactly at the read marker is read', () {
      expect(
        reasonFor(
          decide(
            message: msg(timestamp: now),
            lastReadAt: now,
          ),
        ),
        NotificationSuppression.alreadyRead,
      );
    });

    test('a message newer than the read marker still notifies', () {
      expect(
        decide(
          message: msg(timestamp: now.add(const Duration(seconds: 1))),
          lastReadAt: now,
        ).delivers,
        isTrue,
      );
    });

    test('a disabled network is off', () {
      expect(
        reasonFor(
          decide(
            policy: NotificationPolicy(
              disabledNetworks: const {ChatNetwork.whatsapp},
            ),
          ),
        ),
        NotificationSuppression.networkDisabled,
      );
    });

    test('a muted network is quiet', () {
      expect(
        reasonFor(
          decide(
            policy: NotificationPolicy(
              mutedNetworks: const {ChatNetwork.whatsapp},
            ),
          ),
        ),
        NotificationSuppression.networkMuted,
      );
    });

    test('another network is unaffected by the mute', () {
      expect(
        decide(
          message: msg(network: ChatNetwork.signal),
          forChat: chat(network: ChatNetwork.signal),
          policy: NotificationPolicy(
            mutedNetworks: const {ChatNetwork.whatsapp},
          ),
        ).delivers,
        isTrue,
      );
    });

    test('a chat muted in the domain object is quiet', () {
      expect(
        reasonFor(decide(forChat: chat(muted: true))),
        NotificationSuppression.chatMuted,
      );
    });

    test('a chat muted by policy override is quiet', () {
      expect(
        reasonFor(
          decide(policy: NotificationPolicy().muteChat('!room:example.org')),
        ),
        NotificationSuppression.chatMuted,
      );
    });

    test('a merged chat muted on one leg only suppresses that leg', () {
      final merged = mergedChat(whatsappMuted: true);
      expect(
        reasonFor(
          decide(
            message: msg(roomId: '!wa:example.org'),
            forChat: merged,
          ),
        ),
        NotificationSuppression.sourceMuted,
      );
      expect(
        decide(
          message: msg(roomId: '!sg:example.org', network: ChatNetwork.signal),
          forChat: merged,
        ).delivers,
        isTrue,
        reason: 'the Signal leg of the same contact is not muted',
      );
    });

    test('mentions-only mode drops a message that does not mention', () {
      expect(
        reasonFor(decide(policy: NotificationPolicy(mentionsOnly: true))),
        NotificationSuppression.mentionsOnly,
      );
    });

    test('quiet hours suppress by default', () {
      expect(
        reasonFor(
          decide(
            policy: NotificationPolicy(quietHours: _nightly()),
            at: DateTime.utc(2026, 1, 15, 23, 30),
          ),
        ),
        NotificationSuppression.quietHours,
      );
    });

    test('a duplicate event id decides once', () {
      final dedupe = NotificationDedupe();
      expect(decide(dedupe: dedupe).delivers, isTrue);
      expect(
        reasonFor(decide(dedupe: dedupe)),
        NotificationSuppression.duplicate,
      );
    });
  });

  group('mention detection', () {
    NotificationDecision withBody(String body) => decide(
      policy: NotificationPolicy(mentionsOnly: true),
      message: msg(body: body),
    );

    test('matches a Matrix user id', () {
      expect(withBody('ping @ada:example.org please').mentioned, isTrue);
    });

    test('matches a display name', () {
      expect(withBody('thanks Ada Lovelace!').mentioned, isTrue);
    });

    test('matches the bridged display name', () {
      expect(withBody('hey Ada, are you there?').mentioned, isTrue);
    });

    test('matches @room', () {
      expect(withBody('@room standup in five').mentioned, isTrue);
    });

    test('does not match inside a longer word', () {
      expect(withBody('adamant about the schedule').delivers, isFalse);
    });

    test('matches in a voice-note transcript', () {
      final decision = decide(
        policy: NotificationPolicy(mentionsOnly: true),
        message: msg(
          kind: MessageKind.voice,
          body: '',
          transcript: 'hey Ada call me back',
        ),
      );
      expect(decision.mentioned, isTrue);
    });
  });

  group('combinations', () {
    test('an explicit mention breaks through a muted network', () {
      final decision = decide(
        message: msg(body: 'Ada can you look at this'),
        policy: NotificationPolicy(mutedNetworks: const {ChatNetwork.whatsapp}),
      );
      expect(decision.delivers, isTrue);
      expect(decision.mentioned, isTrue);
    });

    test('a mention does not break through a disabled network', () {
      expect(
        reasonFor(
          decide(
            message: msg(body: 'Ada can you look at this'),
            policy: NotificationPolicy(
              disabledNetworks: const {ChatNetwork.whatsapp},
            ),
          ),
        ),
        NotificationSuppression.networkDisabled,
      );
    });

    test('mentionsBypassMute off keeps a muted chat silent', () {
      expect(
        reasonFor(
          decide(
            message: msg(body: 'Ada can you look at this'),
            forChat: chat(muted: true),
            policy: NotificationPolicy(mentionsBypassMute: false),
          ),
        ),
        NotificationSuppression.chatMuted,
      );
    });

    test('a chat override notifies through quiet hours', () {
      final decision = decide(
        policy: NotificationPolicy(
          quietHours: _nightly(),
          chats: const {
            '!room:example.org': ChatNotificationOverride(
              bypassQuietHours: true,
            ),
          },
        ),
        at: DateTime.utc(2026, 1, 15, 23, 30),
      );
      expect(decision, const NotifyDecision());
    });

    test('a mention pages through quiet hours', () {
      expect(
        decide(
          message: msg(body: 'Ada the build is red'),
          policy: NotificationPolicy(quietHours: _nightly()),
          at: DateTime.utc(2026, 1, 15, 23, 30),
        ).delivers,
        isTrue,
      );
    });

    test('quiet hours in silent mode post without sound', () {
      expect(
        decide(
          policy: NotificationPolicy(
            quietHours: _nightly(deliverSilently: true),
          ),
          at: DateTime.utc(2026, 1, 15, 23, 30),
        ),
        const SilentDecision(),
      );
    });

    test('a per-chat mentionsOnly override beats the global setting', () {
      expect(
        decide(
          policy: NotificationPolicy(
            mentionsOnly: true,
            chats: const {
              '!room:example.org': ChatNotificationOverride(
                mentionsOnly: false,
              ),
            },
          ),
        ).delivers,
        isTrue,
      );
    });

    test('a muted chat is reported as muted, not as quiet hours', () {
      expect(
        reasonFor(
          decide(
            forChat: chat(muted: true),
            policy: NotificationPolicy(quietHours: _nightly()),
            at: DateTime.utc(2026, 1, 15, 23, 30),
          ),
        ),
        NotificationSuppression.chatMuted,
      );
    });
  });

  group('timed mute expiry', () {
    final until = DateTime.utc(2026, 1, 15, 22);
    final policy = NotificationPolicy().muteChat(
      '!room:example.org',
      until: until,
    );

    test('is muted a minute before expiry', () {
      expect(
        reasonFor(
          decide(
            policy: policy,
            at: until.subtract(const Duration(minutes: 1)),
          ),
        ),
        NotificationSuppression.chatMuted,
      );
    });

    test('is not muted exactly at expiry', () {
      expect(decide(policy: policy, at: until).delivers, isTrue);
    });

    test('unmuteChat lifts a timed mute and leaves no entry behind', () {
      final lifted = policy.unmuteChat('!room:example.org');
      expect(lifted.chats, isEmpty);
      expect(
        decide(
          policy: lifted,
          at: until.subtract(const Duration(minutes: 1)),
        ).delivers,
        isTrue,
      );
    });
  });

  group('quiet hours window', () {
    final window = _nightly(); // 22:00 → 07:00, UTC.

    test('is active after the start', () {
      expect(window.isActiveAt(DateTime.utc(2026, 1, 15, 22, 1)), isTrue);
    });

    test('is active across midnight', () {
      expect(window.isActiveAt(DateTime.utc(2026, 1, 16, 3)), isTrue);
    });

    test('ends exclusive of the end minute', () {
      expect(window.isActiveAt(DateTime.utc(2026, 1, 16, 7)), isFalse);
    });

    test('respects the timezone offset', () {
      // 21:00 UTC is 23:00 in UTC+2, which is inside the window.
      final berlin = _nightly(offsetMinutes: 120);
      expect(berlin.isActiveAt(DateTime.utc(2026, 1, 15, 21)), isTrue);
      expect(window.isActiveAt(DateTime.utc(2026, 1, 15, 21)), isFalse);
    });

    test('a zero-length window is no window at all', () {
      const none = QuietHours(startMinute: 60, endMinute: 60);
      expect(none.isActiveAt(DateTime.utc(2026, 1, 15, 1)), isFalse);
    });
  });

  group('dedupe', () {
    test('remembers the first sighting only', () {
      final dedupe = NotificationDedupe();
      expect(dedupe.remember(r'$a'), isTrue);
      expect(dedupe.remember(r'$a'), isFalse);
      expect(dedupe.contains(r'$a'), isTrue);
    });

    test('evicts oldest first at capacity', () {
      final dedupe = NotificationDedupe(capacity: 2);
      dedupe
        ..remember(r'$a')
        ..remember(r'$b')
        ..remember(r'$c');
      expect(dedupe.length, 2);
      expect(dedupe.contains(r'$a'), isFalse);
      expect(dedupe.contains(r'$c'), isTrue);
    });

    test('forget lets an event decide again', () {
      final dedupe = NotificationDedupe();
      expect(decide(dedupe: dedupe).delivers, isTrue);
      dedupe.forget(r'$event_1');
      expect(decide(dedupe: dedupe).delivers, isTrue);
    });

    test('a suppressed decision is still remembered', () {
      final dedupe = NotificationDedupe();
      expect(
        reasonFor(decide(message: msg(isOwn: true), dedupe: dedupe)),
        NotificationSuppression.ownMessage,
      );
      expect(
        reasonFor(decide(dedupe: dedupe)),
        NotificationSuppression.duplicate,
      );
    });
  });

  group('policy json', () {
    test('round-trips every field', () {
      final policy = NotificationPolicy(
        enabled: false,
        mentionsOnly: true,
        showPreviews: false,
        mentionsBypassMute: false,
        quietHours: _nightly(offsetMinutes: -330, deliverSilently: true),
        disabledNetworks: const {ChatNetwork.slack},
        mutedNetworks: const {ChatNetwork.whatsapp, ChatNetwork.signal},
        chats: {
          'merged:contact_1': ChatNotificationOverride(
            mutedUntil: DateTime.utc(2026, 1, 15, 22),
            mentionsOnly: true,
            bypassQuietHours: true,
          ),
        },
      );
      expect(NotificationPolicy.fromJson(policy.toJson()), policy);
    });

    test('a defaulted policy round-trips to itself', () {
      final policy = NotificationPolicy();
      expect(NotificationPolicy.fromJson(policy.toJson()), policy);
    });

    test('a malformed blob degrades to defaults rather than throwing', () {
      final policy = NotificationPolicy.fromJson({
        'enabled': 'yes',
        'quietHours': 'nightly',
        'mutedNetworks': 'whatsapp',
        'chats': [1, 2, 3],
      });
      expect(policy, NotificationPolicy());
      expect(decide(policy: policy).delivers, isTrue);
    });

    test('an unknown network id degrades rather than being dropped', () {
      final policy = NotificationPolicy.fromJson({
        'mutedNetworks': ['myspace'],
      });
      expect(policy.mutedNetworks, {ChatNetwork.unknown});
    });

    test('empty chat overrides are not persisted', () {
      final policy = NotificationPolicy(
        chats: const {'!room:example.org': ChatNotificationOverride()},
      );
      expect((policy.toJson()['chats']! as Map<String, Object?>), isEmpty);
    });
  });
}

QuietHours _nightly({int offsetMinutes = 0, bool deliverSilently = false}) =>
    QuietHours(
      startMinute: 22 * 60,
      endMinute: 7 * 60,
      offsetMinutes: offsetMinutes,
      deliverSilently: deliverSilently,
    );
