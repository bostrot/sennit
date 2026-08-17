import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

import 'support/fixtures.dart';

/// One test per [NotificationSuppression] value, then the combinations where
/// two rules disagree and one has to win.
///
/// `decide`, `reasonFor` and `nightly` come from `support/fixtures.dart`; the
/// ledger behaviour behind [NotificationSuppression.duplicate] lives in
/// `dedupe_test.dart`, so only the rule itself is enumerated here.
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
            policy: NotificationPolicy(quietHours: nightly()),
            at: midnightish,
          ),
        ),
        NotificationSuppression.quietHours,
      );
    });

    test('a duplicate event id decides once', () {
      // Enumerated here for completeness — the push-and-sync scenarios this
      // stands for are in `dedupe_test.dart`.
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

    test('is case-insensitive', () {
      expect(withBody('ADA LOVELACE the build is red').mentioned, isTrue);
      expect(withBody('ada, one more thing').mentioned, isTrue);
    });

    test('@room does not match inside a longer word', () {
      expect(withBody('@rooms are booked until four').delivers, isFalse);
    });

    test('an accented neighbour is a word character', () {
      // "adaé" is one word in some language, and a name that fires inside it
      // costs a notification that broke through a mute.
      expect(withBody('adaé is not a name we know').delivers, isFalse);
    });

    test('a message with no text at all does not mention', () {
      expect(
        withBody('').delivers,
        isFalse,
        reason: 'an empty body cannot contain a name',
      );
    });
  });

  group('mentionsUser', () {
    // Called directly, because the sets are the argument under test and
    // `decide` fixes them to the fixture user.
    test('ignores a display name shorter than two characters', () {
      expect(
        mentionsUser(
          msg(body: 'a quick note'),
          ownUserIds: const {},
          ownDisplayNames: const {'A'},
        ),
        isFalse,
      );
    });

    test('trims a display name before matching', () {
      expect(
        mentionsUser(
          msg(body: 'thanks Grace Hopper'),
          ownUserIds: const {},
          ownDisplayNames: const {'  Grace Hopper  '},
        ),
        isTrue,
      );
    });

    test('a user known by no name and no id is never mentioned', () {
      expect(
        mentionsUser(msg(body: 'Ada @room everyone'), ownUserIds: const {}),
        isTrue,
        reason: '@room needs no identity to match',
      );
      expect(mentionsUser(msg(body: 'Ada?'), ownUserIds: const {}), isFalse);
    });

    test('matches a bridge ghost id as readily as the Matrix one', () {
      expect(
        mentionsUser(
          msg(body: 'cc @whatsapp_me:example.org'),
          ownUserIds: ownUserIds,
        ),
        isTrue,
      );
    });

    test('searches the body when a transcript is also present', () {
      expect(
        mentionsUser(
          msg(
            kind: MessageKind.audio,
            body: 'Ada — voice note',
            transcript: 'nothing to see here',
          ),
          ownUserIds: const {},
          ownDisplayNames: ownDisplayNames,
        ),
        isTrue,
      );
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
          quietHours: nightly(),
          chats: const {
            '!room:example.org': ChatNotificationOverride(
              bypassQuietHours: true,
            ),
          },
        ),
        at: midnightish,
      );
      expect(decision, const NotifyDecision());
    });

    test('a mention pages through quiet hours', () {
      expect(
        decide(
          message: msg(body: 'Ada the build is red'),
          policy: NotificationPolicy(quietHours: nightly()),
          at: midnightish,
        ).delivers,
        isTrue,
      );
    });

    test('quiet hours in silent mode post without sound', () {
      expect(
        decide(
          policy: NotificationPolicy(
            quietHours: nightly(deliverSilently: true),
          ),
          at: midnightish,
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
            policy: NotificationPolicy(quietHours: nightly()),
            at: midnightish,
          ),
        ),
        NotificationSuppression.chatMuted,
      );
    });

    test('a mention breaks through a per-leg mute', () {
      // The WhatsApp leg is muted; being named on it is still being named.
      final decision = decide(
        message: msg(roomId: '!wa:example.org', body: 'Ada can you look'),
        forChat: mergedChat(whatsappMuted: true),
      );
      expect(decision.delivers, isTrue);
      expect(decision.mentioned, isTrue);
    });

    test('mentionsBypassMute off keeps a per-leg mute silent', () {
      expect(
        reasonFor(
          decide(
            message: msg(roomId: '!wa:example.org', body: 'Ada can you look'),
            forChat: mergedChat(whatsappMuted: true),
            policy: NotificationPolicy(mentionsBypassMute: false),
          ),
        ),
        NotificationSuppression.sourceMuted,
      );
    });

    test('quiet hours with allowMentions off silence a mention too', () {
      // The do-not-disturb reading of the setting: nothing gets through, not
      // even a page.
      expect(
        reasonFor(
          decide(
            message: msg(body: 'Ada the build is red'),
            policy: NotificationPolicy(
              quietHours: nightly(allowMentions: false),
            ),
            at: midnightish,
          ),
        ),
        NotificationSuppression.quietHours,
      );
    });

    test('a silenced mention still arrives marked as one', () {
      // Silent delivery must not lose the flag: the shade sorts by it in the
      // morning, and a mention demoted to chatter is the thing the user
      // complains about.
      expect(
        decide(
          message: msg(body: 'Ada the build is red'),
          policy: NotificationPolicy(
            quietHours: nightly(allowMentions: false, deliverSilently: true),
          ),
          at: midnightish,
        ),
        const SilentDecision(mentioned: true),
      );
    });

    test('a VIP chat notifies loudly through silent quiet hours', () {
      expect(
        decide(
          policy: NotificationPolicy(
            quietHours: nightly(deliverSilently: true),
            chats: const {
              '!room:example.org': ChatNotificationOverride(
                bypassQuietHours: true,
              ),
            },
          ),
          at: midnightish,
        ),
        const NotifyDecision(),
      );
    });

    test('a per-chat mentionsOnly override turns it on for one chat', () {
      // The other direction of the override: mentions-only for the busy group,
      // everything as normal elsewhere.
      final policy = NotificationPolicy(
        chats: const {
          '!standup:example.org': ChatNotificationOverride(mentionsOnly: true),
        },
      );
      expect(
        reasonFor(
          decide(
            policy: policy,
            forChat: chat(id: '!standup:example.org'),
          ),
        ),
        NotificationSuppression.mentionsOnly,
      );
      expect(decide(policy: policy).delivers, isTrue);
    });

    test('an override is keyed on the merged id, not on a source room', () {
      // Muting a merged contact is one entry covering every leg. An entry keyed
      // on a room id silences half a conversation and looks like a bug in the
      // bridge rather than a setting the user chose.
      final byMergedId = NotificationPolicy().muteChat('merged:contact_1');
      final byRoomId = NotificationPolicy().muteChat('!wa:example.org');
      final whatsapp = msg(roomId: '!wa:example.org');
      final signal = msg(
        roomId: '!sg:example.org',
        network: ChatNetwork.signal,
      );

      expect(
        reasonFor(
          decide(message: whatsapp, forChat: mergedChat(), policy: byMergedId),
        ),
        NotificationSuppression.chatMuted,
      );
      expect(
        reasonFor(
          decide(message: signal, forChat: mergedChat(), policy: byMergedId),
        ),
        NotificationSuppression.chatMuted,
      );
      expect(
        decide(
          message: whatsapp,
          forChat: mergedChat(),
          policy: byRoomId,
        ).delivers,
        isTrue,
        reason: 'a merged chat is never looked up by one of its room ids',
      );
    });
  });

  group('rule order', () {
    // The first rule that fires is reported as *the* reason, so the diagnosis
    // names the setting the user would actually go and change.
    test('own messages beat a redaction', () {
      expect(
        reasonFor(decide(message: msg(isOwn: true, redacted: true))),
        NotificationSuppression.ownMessage,
      );
    });

    test('the global switch beats the read marker', () {
      expect(
        reasonFor(
          decide(policy: NotificationPolicy(enabled: false), lastReadAt: now),
        ),
        NotificationSuppression.globallyDisabled,
      );
    });

    test('a read message does not re-notify even as a mention', () {
      // Read on the laptop, pushed to the phone. The mention bypass applies to
      // mutes, not to facts about what the user has already seen.
      expect(
        reasonFor(
          decide(
            message: msg(
              body: 'Ada can you look',
              timestamp: now.subtract(const Duration(minutes: 5)),
            ),
            lastReadAt: now,
          ),
        ),
        NotificationSuppression.alreadyRead,
      );
    });

    test('a disabled network beats a muted chat', () {
      expect(
        reasonFor(
          decide(
            forChat: chat(muted: true),
            policy: NotificationPolicy(
              disabledNetworks: const {ChatNetwork.whatsapp},
            ),
          ),
        ),
        NotificationSuppression.networkDisabled,
      );
    });

    test('a muted chat beats mentions-only', () {
      expect(
        reasonFor(
          decide(
            forChat: chat(muted: true),
            policy: NotificationPolicy(mentionsOnly: true),
          ),
        ),
        NotificationSuppression.chatMuted,
      );
    });

    test('mentions-only beats quiet hours', () {
      expect(
        reasonFor(
          decide(
            policy: NotificationPolicy(
              mentionsOnly: true,
              quietHours: nightly(),
            ),
            at: midnightish,
          ),
        ),
        NotificationSuppression.mentionsOnly,
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

    test('is muted a millisecond before expiry', () {
      // The boundary the "mute for 1 hour" action lands on, to the resolution
      // the clock actually has.
      expect(
        reasonFor(
          decide(
            policy: policy,
            at: until.subtract(const Duration(milliseconds: 1)),
          ),
        ),
        NotificationSuppression.chatMuted,
      );
    });

    test('is not muted after expiry', () {
      expect(
        decide(
          policy: policy,
          at: until.add(const Duration(hours: 9)),
        ).delivers,
        isTrue,
      );
    });

    test('an expiry in the past is dead on arrival', () {
      // What a mute left over from yesterday's session looks like when the app
      // reloads the policy: nothing at all.
      final stale = NotificationPolicy().muteChat(
        '!room:example.org',
        until: now.subtract(const Duration(days: 1)),
      );
      expect(decide(policy: stale).delivers, isTrue);
    });

    test('an indefinite mute ignores the clock', () {
      final forever = NotificationPolicy().muteChat('!room:example.org');
      expect(
        reasonFor(
          decide(policy: forever, at: now.add(const Duration(days: 365))),
        ),
        NotificationSuppression.chatMuted,
      );
    });

    test('muting for an hour over an indefinite mute becomes timed', () {
      final timed = NotificationPolicy()
          .muteChat('!room:example.org')
          .muteChat('!room:example.org', until: until);
      expect(
        reasonFor(
          decide(policy: timed, at: until.subtract(const Duration(minutes: 1))),
        ),
        NotificationSuppression.chatMuted,
      );
      expect(decide(policy: timed, at: until).delivers, isTrue);
    });

    test('a local expiry is stored as UTC', () {
      // The mute is compared against a `now` that a background isolate
      // produces, which has no reason to share the UI isolate's timezone.
      final local = NotificationPolicy().muteChat(
        '!room:example.org',
        until: DateTime.utc(2026, 1, 15, 22).toLocal(),
      );
      expect(local.overrideFor('!room:example.org').mutedUntil!.isUtc, isTrue);
      expect(decide(policy: local, at: until).delivers, isTrue);
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

    test('unmuting keeps the settings the user did not touch', () {
      final vip = NotificationPolicy()
          .withChatOverride(
            '!room:example.org',
            const ChatNotificationOverride(bypassQuietHours: true),
          )
          .muteChat('!room:example.org', until: until);
      final lifted = vip.unmuteChat('!room:example.org');
      expect(lifted.overrideFor('!room:example.org').bypassQuietHours, isTrue);
      expect(lifted.chats, hasLength(1));
    });

    test('pruneExpiredMutes drops a lapsed timed mute', () {
      final pruned = policy.pruneExpiredMutes(
        until.add(const Duration(minutes: 1)),
      );
      expect(pruned.chats, isEmpty);
    });

    test('pruneExpiredMutes leaves a mute that is still running', () {
      final pruned = policy.pruneExpiredMutes(
        until.subtract(const Duration(minutes: 1)),
      );
      expect(pruned.overrideFor('!room:example.org').mutedUntil, until);
    });

    test('pruneExpiredMutes never touches an indefinite mute', () {
      // No expiry means nothing to lapse. A tidy-up that silently unmuted a
      // chat the user muted for good would be the worst possible bug in a
      // function whose whole job is housekeeping.
      final forever = NotificationPolicy().muteChat('!room:example.org');
      final pruned = forever.pruneExpiredMutes(
        now.add(const Duration(days: 365)),
      );
      expect(pruned.overrideFor('!room:example.org').muted, isTrue);
      expect(identical(pruned, forever), isTrue);
    });

    test('pruneExpiredMutes returns the same instance when nothing lapsed', () {
      // What lets the settings screen prune on open without that being a
      // settings write on every visit.
      final untouched = policy.pruneExpiredMutes(
        until.subtract(const Duration(hours: 1)),
      );
      expect(identical(untouched, policy), isTrue);
    });

    test('pruneExpiredMutes keeps the settings that are not the mute', () {
      final vip = NotificationPolicy()
          .withChatOverride(
            '!room:example.org',
            const ChatNotificationOverride(bypassQuietHours: true),
          )
          .muteChat('!room:example.org', until: until);
      final pruned = vip.pruneExpiredMutes(until.add(const Duration(days: 1)));
      expect(pruned.overrideFor('!room:example.org').bypassQuietHours, isTrue);
      expect(pruned.overrideFor('!room:example.org').mutedUntil, isNull);
      expect(pruned.chats, hasLength(1));
    });

    test('pruneExpiredMutes prunes only the chats that lapsed', () {
      final mixed = NotificationPolicy()
          .muteChat('!lapsed:example.org', until: until)
          .muteChat(
            '!running:example.org',
            until: until.add(const Duration(days: 1)),
          )
          .muteChat('!forever:example.org');
      final pruned = mixed.pruneExpiredMutes(
        until.add(const Duration(minutes: 1)),
      );
      expect(
        pruned.chats.keys,
        unorderedEquals(['!running:example.org', '!forever:example.org']),
      );
    });
  });

  group('quiet hours window', () {
    final window = nightly(); // 22:00 → 07:00, UTC.

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
      final berlin = nightly(offsetMinutes: 120);
      expect(berlin.isActiveAt(DateTime.utc(2026, 1, 15, 21)), isTrue);
      expect(window.isActiveAt(DateTime.utc(2026, 1, 15, 21)), isFalse);
    });

    test('a zero-length window is no window at all', () {
      const none = QuietHours(startMinute: 60, endMinute: 60);
      expect(none.isActiveAt(DateTime.utc(2026, 1, 15, 1)), isFalse);
    });

    test('includes its start minute and excludes its end', () {
      expect(window.isActiveAt(DateTime.utc(2026, 1, 15, 22)), isTrue);
      expect(window.isActiveAt(DateTime.utc(2026, 1, 15, 21, 59)), isFalse);
      expect(window.isActiveAt(DateTime.utc(2026, 1, 16, 6, 59)), isTrue);
    });

    test('a window inside one day does not wrap', () {
      // A lunch-hour window, the case the wrapping branch must not swallow.
      const lunch = QuietHours(startMinute: 12 * 60, endMinute: 13 * 60);
      expect(lunch.isActiveAt(DateTime.utc(2026, 1, 15, 12, 30)), isTrue);
      expect(lunch.isActiveAt(DateTime.utc(2026, 1, 15, 3)), isFalse);
      expect(lunch.isActiveAt(DateTime.utc(2026, 1, 15, 23)), isFalse);
    });

    test('a negative offset moves the window the other way', () {
      // UTC-05:00: 03:00 UTC is 22:00 the previous evening, inside the window.
      final newYork = nightly(offsetMinutes: -300);
      expect(newYork.isActiveAt(DateTime.utc(2026, 1, 16, 3)), isTrue);
      expect(newYork.isActiveAt(DateTime.utc(2026, 1, 15, 21)), isFalse);
    });

    test('a half-hour offset is a real place', () {
      // UTC+05:30. 16:35 UTC is 22:05 in Kolkata.
      final kolkata = nightly(offsetMinutes: 330);
      expect(kolkata.isActiveAt(DateTime.utc(2026, 1, 15, 16, 35)), isTrue);
      expect(kolkata.isActiveAt(DateTime.utc(2026, 1, 15, 16, 25)), isFalse);
    });

    test('a local-time argument is normalised before comparing', () {
      // The foreground path passes a local `DateTime`, a background isolate a
      // UTC one. They have to agree.
      final at = DateTime.utc(2026, 1, 15, 23, 30);
      expect(window.isActiveAt(at.toLocal()), window.isActiveAt(at));
    });
  });

  group('policy json', () {
    test('round-trips every field', () {
      final policy = NotificationPolicy(
        enabled: false,
        mentionsOnly: true,
        showPreviews: false,
        mentionsBypassMute: false,
        quietHours: nightly(offsetMinutes: -330, deliverSilently: true),
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

    test('a timed mute survives the round trip and still expires', () {
      final until = DateTime.utc(2026, 1, 15, 22);
      final reloaded = NotificationPolicy.fromJson(
        NotificationPolicy()
            .muteChat('!room:example.org', until: until)
            .toJson(),
      );
      expect(
        reasonFor(
          decide(
            policy: reloaded,
            at: until.subtract(const Duration(minutes: 1)),
          ),
        ),
        NotificationSuppression.chatMuted,
      );
      expect(decide(policy: reloaded, at: until).delivers, isTrue);
    });

    test('a chat entry with a non-string key is skipped', () {
      final policy = NotificationPolicy.fromJson({
        'chats': {
          7: {'muted': true},
          '!room:example.org': {'muted': true},
        },
      });
      expect(policy.chats.keys, ['!room:example.org']);
    });

    test('an entry that decodes to nothing is not resurrected', () {
      final policy = NotificationPolicy.fromJson({
        'chats': {'!room:example.org': <String, Object?>{}},
      });
      expect(policy.chats, isEmpty);
    });

    test('unknown keys are ignored rather than fatal', () {
      // Reading a blob written by a newer build: the fields this version knows
      // still apply.
      final policy = NotificationPolicy.fromJson({
        'enabled': false,
        'somethingFromTheFuture': {'nested': true},
      });
      expect(policy.enabled, isFalse);
      expect(policy.showPreviews, isTrue);
    });

    test('nothing at all is the default policy', () {
      // What `SettingsStore.getJson` hands back before the user has ever opened
      // the settings screen — and after a corrupt blob.
      expect(NotificationPolicy.fromJson(null), NotificationPolicy());
      expect(NotificationPolicy.fromJson('corrupt'), NotificationPolicy());
      expect(
        decide(policy: NotificationPolicy.fromJson(null)).delivers,
        isTrue,
      );
    });

    test('quiet hours survive a fractional offset from a JSON number', () {
      // `jsonDecode` hands back a double where an int was written.
      final quiet = QuietHours.fromJson({
        'startMinute': 1320.0,
        'endMinute': 420.0,
        'offsetMinutes': 330.0,
      })!;
      expect(quiet, nightly(offsetMinutes: 330));
    });

    test('a window missing its bounds is no window', () {
      expect(QuietHours.fromJson({'offsetMinutes': 60}), isNull);
      expect(QuietHours.fromJson(null), isNull);
    });

    test('withChatOverride(null) removes an entry', () {
      final policy = NotificationPolicy()
          .muteChat('!room:example.org')
          .withChatOverride('!room:example.org', null);
      expect(policy.chats, isEmpty);
      expect(decide(policy: policy).delivers, isTrue);
    });

    test('the collections are unmodifiable, so a policy cannot drift', () {
      final policy = NotificationPolicy(
        mutedNetworks: const {ChatNetwork.whatsapp},
      );
      expect(
        () => policy.mutedNetworks.add(ChatNetwork.signal),
        throwsUnsupportedError,
      );
      expect(
        () => policy.chats['x'] = const ChatNotificationOverride(),
        throwsUnsupportedError,
      );
    });
  });
}
