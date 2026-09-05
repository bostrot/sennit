import 'package:test/test.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/fixtures.dart';

/// One test per [AutoReplyRefusal], then the cases where two rules disagree and
/// one has to win.
///
/// The guards come first and in the order the engine applies them, because that
/// order is itself a promise: a stranger's message inside a matching rule's
/// window must read as `pendingRequest` and not as anything a later check would
/// have said. `decide`, `msg`, `state` and `rule` come from
/// `support/fixtures.dart`; the ledger's own behaviour is in `ledger_test.dart`
/// and the JSON round trip in `rule_json_test.dart`.
void main() {
  group('the ordinary case', () {
    test('an incoming message with a matching rule plans a reply', () {
      final decision = decide();

      expect(decision.willReply, isTrue);
      expect(decision.rule?.id, 'rule_1');
      expect(decision.refusal, isNull);
      expect(decision, AutoReplyPlanned(rule()));
    });
  });

  group('the guards, in the order they fire', () {
    test('the user own message is never answered', () {
      expect(
        reasonFor(decide(message: msg(isOwn: true))),
        AutoReplyRefusal.ownMessage,
      );
    });

    test('a message from one of the user own ids is never answered', () {
      // The bridge echo of a message sent from the phone arrives with isOwn
      // unset often enough that the sender id has to be checked too — and this
      // is the shortest loop there is, so it is checked first.
      expect(
        reasonFor(decide(message: msg(senderId: '@ada:example.org'))),
        AutoReplyRefusal.ownMessage,
      );
    });

    test('a redacted message is never answered', () {
      expect(
        reasonFor(decide(message: msg(redacted: true, body: ''))),
        AutoReplyRefusal.redacted,
      );
    });

    test('a call or state event is never answered', () {
      expect(
        reasonFor(decide(message: msg(kind: MessageKind.event))),
        AutoReplyRefusal.nonMessageEvent,
      );
    });

    test('another auto-reply is never answered', () {
      expect(
        reasonFor(decide(message: msg(isAutoReply: true))),
        AutoReplyRefusal.autoReplyEcho,
      );
    });

    test('an auto-reply beats redaction to the answer only when it is not '
        'redacted', () {
      // Order check rather than a behaviour change: a redacted auto-reply is
      // reported as redacted, because that is the cheaper and more unarguable
      // fact and it is checked first.
      expect(
        reasonFor(decide(message: msg(isAutoReply: true, redacted: true))),
        AutoReplyRefusal.redacted,
      );
    });

    test('a message with no words is never answered', () {
      // A captionless photo. A model handed no text invents some.
      expect(
        reasonFor(
          decide(
            message: msg(body: '', kind: MessageKind.image),
          ),
        ),
        AutoReplyRefusal.emptyMessage,
      );
    });

    test('a voice note is answerable once it has a transcript', () {
      expect(
        decide(
          message: msg(
            body: '',
            kind: MessageKind.voice,
            transcript: 'are you around this afternoon?',
          ),
        ).willReply,
        isTrue,
      );
    });

    test('a chat request from an unknown sender is never answered', () {
      // The whole promise of holding a stranger's message is that they learn
      // nothing. A machine-written answer tells them the handle is live, is
      // read, and is worth trying again.
      expect(
        reasonFor(
          decide(
            forChat: state(forChat: chat(request: ChatRequestState.pending)),
          ),
        ),
        AutoReplyRefusal.pendingRequest,
      );
    });

    test('a request refusal wins over every rule that would have matched', () {
      expect(
        reasonFor(
          decide(
            forChat: state(
              forChat: chat(request: ChatRequestState.pending),
              labels: {'Work'},
            ),
            rules: [
              rule(id: 'wide'),
              rule(id: 'narrow', audience: const LabelAudience('Work')),
            ],
          ),
        ),
        AutoReplyRefusal.pendingRequest,
      );
    });

    test('an accepted request is an ordinary conversation again', () {
      expect(
        decide(
          forChat: state(forChat: chat(request: ChatRequestState.accepted)),
        ).willReply,
        isTrue,
      );
    });

    test('a bridge management room is never answered', () {
      expect(
        reasonFor(decide(forChat: state(isServiceChat: true))),
        AutoReplyRefusal.serviceChat,
      );
    });

    test('a status broadcast is never answered', () {
      expect(
        reasonFor(decide(forChat: state(isBroadcast: true))),
        AutoReplyRefusal.broadcast,
      );
    });
  });

  group('audience matching', () {
    test('everyone covers any conversation', () {
      expect(
        decide(rules: [rule(audience: const EveryoneAudience())]).willReply,
        isTrue,
      );
    });

    test('a network audience matches the leg the message arrived on', () {
      expect(
        decide(
          message: msg(network: ChatNetwork.whatsapp),
          rules: [
            rule(audience: const NetworkAudience({ChatNetwork.whatsapp})),
          ],
        ).willReply,
        isTrue,
      );
    });

    test('a network audience ignores the other legs of a merged chat', () {
      // The chat spans WhatsApp and Signal; the rule is scoped to SMS. Matching
      // on the chat's networks rather than the message's would fire here.
      expect(
        reasonFor(
          decide(
            message: msg(network: ChatNetwork.signal),
            forChat: state(forChat: mergedChat()),
            rules: [
              rule(audience: const NetworkAudience({ChatNetwork.sms})),
            ],
          ),
        ),
        AutoReplyRefusal.noRuleMatched,
      );
    });

    test('a network audience fires on the matching leg of a merged chat', () {
      expect(
        decide(
          message: msg(network: ChatNetwork.signal),
          forChat: state(forChat: mergedChat()),
          rules: [
            rule(audience: const NetworkAudience({ChatNetwork.signal})),
          ],
        ).willReply,
        isTrue,
      );
    });

    test('a label audience matches what the app filed the chat under', () {
      expect(
        decide(
          forChat: state(labels: {'Work', 'Verein'}),
          rules: [rule(audience: const LabelAudience('Verein'))],
        ).willReply,
        isTrue,
      );
    });

    test('a label audience does not match a chat without the label', () {
      expect(
        reasonFor(
          decide(
            forChat: state(labels: {'Family'}),
            rules: [rule(audience: const LabelAudience('Work'))],
          ),
        ),
        AutoReplyRefusal.noRuleMatched,
      );
    });

    test('a contact audience matches the unified contact id', () {
      // The merge fold's answer, so a person on WhatsApp and Signal is one
      // entry rather than two.
      expect(
        decide(
          forChat: state(forChat: mergedChat(contactId: 'contact_1')),
          rules: [
            rule(audience: const ContactAudience({'contact_1'})),
          ],
        ).willReply,
        isTrue,
      );
    });

    test('a contact audience matches a plain chat id too', () {
      // Every group, and every DM the graph has no contact for.
      expect(
        decide(
          forChat: state(forChat: chat(id: '!book-club:example.org')),
          rules: [
            rule(audience: const ContactAudience({'!book-club:example.org'})),
          ],
        ).willReply,
        isTrue,
      );
    });

    test('a contact audience naming someone else does not match', () {
      expect(
        reasonFor(
          decide(
            forChat: state(forChat: mergedChat(contactId: 'contact_1')),
            rules: [
              rule(audience: const ContactAudience({'contact_9'})),
            ],
          ),
        ),
        AutoReplyRefusal.noRuleMatched,
      );
    });

    test('a disabled rule does not match', () {
      expect(
        reasonFor(decide(rules: [rule(enabled: false)])),
        AutoReplyRefusal.noRuleMatched,
      );
    });

    test('an enabled rule with a blank prompt does not match', () {
      // Nothing to send, so it must not shadow a working rule of lower
      // precedence either — see the precedence group.
      expect(
        reasonFor(decide(rules: [rule(prompt: '   ')])),
        AutoReplyRefusal.noRuleMatched,
      );
    });

    test('no rules at all is a refusal, not a crash', () {
      expect(
        reasonFor(decide(rules: const [])),
        AutoReplyRefusal.noRuleMatched,
      );
    });
  });

  group('precedence between overlapping rules', () {
    test('a contact rule beats a label rule', () {
      final decision = decide(
        forChat: state(
          forChat: mergedChat(contactId: 'contact_1'),
          labels: {'Work'},
        ),
        rules: [
          rule(id: 'label', audience: const LabelAudience('Work')),
          rule(id: 'contact', audience: const ContactAudience({'contact_1'})),
        ],
      );

      expect(decision.rule?.id, 'contact');
    });

    test('a label rule beats a network rule', () {
      final decision = decide(
        forChat: state(labels: {'Work'}),
        rules: [
          rule(
            id: 'network',
            audience: const NetworkAudience({ChatNetwork.whatsapp}),
          ),
          rule(id: 'label', audience: const LabelAudience('Work')),
        ],
      );

      expect(decision.rule?.id, 'label');
    });

    test('a network rule beats the blanket rule', () {
      final decision = decide(
        rules: [
          rule(id: 'everyone'),
          rule(
            id: 'network',
            audience: const NetworkAudience({ChatNetwork.whatsapp}),
          ),
        ],
      );

      expect(decision.rule?.id, 'network');
    });

    test('two rules of equal specificity resolve to the earlier one', () {
      // The list is the user's own order on the settings screen, so "the first
      // one I wrote wins" is something they can see and rearrange.
      final decision = decide(
        forChat: state(labels: {'Work', 'Verein'}),
        rules: [
          rule(id: 'first', audience: const LabelAudience('Work')),
          rule(id: 'second', audience: const LabelAudience('Verein')),
        ],
      );

      expect(decision.rule?.id, 'first');
    });

    test('a disabled narrow rule does not shadow a wide one', () {
      final decision = decide(
        forChat: state(labels: {'Work'}),
        rules: [
          rule(
            id: 'narrow',
            enabled: false,
            audience: const LabelAudience('Work'),
          ),
          rule(id: 'wide'),
        ],
      );

      expect(decision.rule?.id, 'wide');
    });

    test('an out-of-hours narrow rule falls through to a wide open one', () {
      // The audience/window split exists for exactly this. Selecting the
      // winner first and *then* checking its window would leave the user with
      // silence at 22:00 instead of the blanket rule they also wrote.
      final decision = decide(
        forChat: state(labels: {'Work'}),
        when: at(hour: 22),
        rules: [
          rule(
            id: 'narrow',
            audience: const LabelAudience('Work'),
            window: officeHours(),
          ),
          rule(id: 'wide'),
        ],
      );

      expect(decision.rule?.id, 'wide');
    });

    test('every matching rule being out of hours reads as outsideSchedule', () {
      expect(
        reasonFor(
          decide(
            when: at(hour: 22),
            rules: [rule(window: officeHours())],
          ),
        ),
        AutoReplyRefusal.outsideSchedule,
      );
    });

    test(
      'a chat no rule covers reads as noRuleMatched, not outsideSchedule',
      () {
        // The two refusals answer different questions and the settings screen
        // words them differently: "nothing is set up for this chat" versus "come
        // back at nine".
        expect(
          reasonFor(
            decide(
              when: at(hour: 22),
              rules: [
                rule(
                  audience: const LabelAudience('Work'),
                  window: officeHours(),
                ),
              ],
            ),
          ),
          AutoReplyRefusal.noRuleMatched,
        );
      },
    );
  });

  group('the per-conversation cooldown', () {
    test('a reply inside the cooldown is refused', () {
      expect(
        reasonFor(
          decide(
            forChat: state(
              recentReplies: [sent(ago: const Duration(minutes: 10))],
            ),
            rules: [rule(cooldown: const Duration(minutes: 30))],
          ),
        ),
        AutoReplyRefusal.cooling,
      );
    });

    test('the boundary minute is still cooling', () {
      // `<` rather than `<=`: at exactly the cooldown the interval the user
      // asked for has elapsed, so this is the last refused instant.
      expect(
        reasonFor(
          decide(
            forChat: state(
              recentReplies: [
                sent(
                  ago: const Duration(minutes: 30) - const Duration(seconds: 1),
                ),
              ],
            ),
            rules: [rule(cooldown: const Duration(minutes: 30))],
          ),
        ),
        AutoReplyRefusal.cooling,
      );
    });

    test('exactly at the cooldown it may reply again', () {
      expect(
        decide(
          forChat: state(
            recentReplies: [sent(ago: const Duration(minutes: 30))],
          ),
          rules: [rule(cooldown: const Duration(minutes: 30))],
        ).willReply,
        isTrue,
      );
    });

    test('the cooldown counts any auto-reply here, not only this rule own', () {
      // Two rules taking turns would otherwise halve the interval the user set.
      expect(
        reasonFor(
          decide(
            forChat: state(
              recentReplies: [
                sent(ruleId: 'someone_else', ago: const Duration(minutes: 5)),
              ],
            ),
            rules: [rule(id: 'mine', cooldown: const Duration(minutes: 30))],
          ),
        ),
        AutoReplyRefusal.cooling,
      );
    });

    test('a zero cooldown still obeys the cap', () {
      // The cap is what makes a zero cooldown safe to offer at all.
      expect(
        reasonFor(
          decide(
            forChat: state(
              recentReplies: [
                for (var i = 0; i < kAutoReplyMaxPerConversation; i++)
                  sent(ago: Duration(minutes: i + 1)),
              ],
            ),
            rules: [rule(cooldown: Duration.zero)],
          ),
        ),
        AutoReplyRefusal.conversationCap,
      );
    });
  });

  group('the loop cap', () {
    test('one below the cap still replies', () {
      expect(
        decide(
          forChat: state(
            recentReplies: [
              for (var i = 0; i < kAutoReplyMaxPerConversation - 1; i++)
                sent(ago: Duration(minutes: i + 1)),
            ],
          ),
        ).willReply,
        isTrue,
      );
    });

    test('at the cap it stops, and says so rather than saying cooling', () {
      // The distinction matters: "waiting a while" and "being stopped" are
      // different answers, and only one of them ever changes on its own.
      expect(
        reasonFor(
          decide(
            forChat: state(
              recentReplies: [
                for (var i = 0; i < kAutoReplyMaxPerConversation; i++)
                  sent(ago: Duration(minutes: i + 1)),
              ],
            ),
          ),
        ),
        AutoReplyRefusal.conversationCap,
      );
    });

    test('replies older than the cap window do not count', () {
      expect(
        decide(
          forChat: state(
            recentReplies: [
              for (var i = 0; i < kAutoReplyMaxPerConversation; i++)
                sent(ago: kAutoReplyCapWindow + Duration(minutes: i + 1)),
            ],
          ),
        ).willReply,
        isTrue,
      );
    });

    test('an entry exactly at the window edge still counts', () {
      // `!isBefore` rather than `isAfter`, so the cap cannot be stepped over by
      // arriving on the boundary second.
      expect(
        reasonFor(
          decide(
            forChat: state(
              recentReplies: [
                for (var i = 0; i < kAutoReplyMaxPerConversation - 1; i++)
                  sent(ago: Duration(minutes: i + 1)),
                sent(ago: kAutoReplyCapWindow),
              ],
            ),
          ),
        ),
        AutoReplyRefusal.conversationCap,
      );
    });

    test('the cap cannot be raised by a rule', () {
      // There is no field for it, which is the point — this test exists so that
      // adding one is a test failure rather than a quiet capability.
      final everything = rule(cooldown: Duration.zero).toJson();
      expect(everything.keys, isNot(contains('maxPerConversation')));
      expect(everything.keys, isNot(contains('cap')));
    });
  });

  group('schedule windows', () {
    test('inside office hours it replies', () {
      expect(
        decide(
          when: at(hour: 12),
          rules: [rule(window: officeHours())],
        ).willReply,
        isTrue,
      );
    });

    test('the opening minute is inside', () {
      expect(
        decide(
          when: at(hour: 9),
          rules: [rule(window: officeHours())],
        ).willReply,
        isTrue,
      );
    });

    test('the minute before opening is outside', () {
      expect(
        reasonFor(
          decide(
            when: at(hour: 8, minute: 59),
            rules: [rule(window: officeHours())],
          ),
        ),
        AutoReplyRefusal.outsideSchedule,
      );
    });

    test('the closing minute is outside — the end is exclusive', () {
      expect(
        reasonFor(
          decide(
            when: at(hour: 17),
            rules: [rule(window: officeHours())],
          ),
        ),
        AutoReplyRefusal.outsideSchedule,
      );
    });

    test('the minute before closing is inside', () {
      expect(
        decide(
          when: at(hour: 16, minute: 59),
          rules: [rule(window: officeHours())],
        ).willReply,
        isTrue,
      );
    });

    test('a rule with no window replies at three in the morning', () {
      expect(decide(when: at(hour: 3)).willReply, isTrue);
    });
  });

  group('schedule windows across midnight', () {
    test('the evening half is inside', () {
      expect(
        decide(
          when: at(hour: 23),
          rules: [rule(window: overnight())],
        ).willReply,
        isTrue,
      );
    });

    test('the morning half is inside', () {
      expect(
        decide(
          when: at(hour: 2),
          rules: [rule(window: overnight())],
        ).willReply,
        isTrue,
      );
    });

    test('the middle of the afternoon is outside', () {
      expect(
        reasonFor(
          decide(
            when: at(hour: 14),
            rules: [rule(window: overnight())],
          ),
        ),
        AutoReplyRefusal.outsideSchedule,
      );
    });

    test('a zero-length window means always, not never', () {
      // The opposite reading to QuietHours, and deliberately: a half-finished
      // form must not start withholding a reply the user asked for.
      const always = ReplyWindow(startMinute: 0, endMinute: 0);
      expect(always.isAlways, isTrue);
      expect(
        decide(
          when: at(hour: 4),
          rules: [rule(window: always)],
        ).willReply,
        isTrue,
      );
    });
  });

  group('schedule windows in a timezone that is not the runner own', () {
    test(
      'office hours in +05:30 open five and a half hours earlier in UTC',
      () {
        // 09:00 in Kolkata is 03:30 UTC. The window carries the offset so a
        // background isolate with no local timezone reaches the same verdict.
        final kolkata = officeHours(offsetMinutes: 330);

        expect(
          decide(
            when: at(hour: 3, minute: 29),
            rules: [rule(window: kolkata)],
          ).refusal,
          AutoReplyRefusal.outsideSchedule,
        );
        expect(
          decide(
            when: at(hour: 3, minute: 30),
            rules: [rule(window: kolkata)],
          ).willReply,
          isTrue,
        );
        expect(
          decide(
            when: at(hour: 11, minute: 29),
            rules: [rule(window: kolkata)],
          ).willReply,
          isTrue,
        );
        expect(
          decide(
            when: at(hour: 11, minute: 30),
            rules: [rule(window: kolkata)],
          ).refusal,
          AutoReplyRefusal.outsideSchedule,
        );
      },
    );

    test('a west-of-UTC offset shifts the other way', () {
      // 09:00 in Los Angeles (UTC−8) is 17:00 UTC.
      final la = officeHours(offsetMinutes: -8 * 60);

      expect(
        decide(
          when: at(hour: 12),
          rules: [rule(window: la)],
        ).refusal,
        AutoReplyRefusal.outsideSchedule,
      );
      expect(
        decide(
          when: at(hour: 17),
          rules: [rule(window: la)],
        ).willReply,
        isTrue,
      );
    });

    test('a +14:00 offset can push a window onto the next UTC day', () {
      // Kiritimati. 09:00 local on Friday the 16th is 19:00 UTC on Thursday
      // the 15th, and a naive UTC-only comparison would call it Thursday.
      final kiritimati = officeHours(
        offsetMinutes: 14 * 60,
        weekdays: const {DateTime.friday},
      );

      expect(
        decide(
          when: at(hour: 19),
          rules: [rule(window: kiritimati)],
        ).willReply,
        isTrue,
      );
    });

    test('a passed-in now is what decides, not the ambient clock', () {
      // `decide` runs everything under a clock pinned to 30 June at 03:00,
      // which is outside office hours. If anything inside reached for it, the
      // in-hours case below would fail.
      expect(
        decide(
          when: at(hour: 12),
          rules: [rule(window: officeHours())],
        ).willReply,
        isTrue,
      );
    });
  });

  group('weekday windows', () {
    test('an empty weekday set means every day', () {
      expect(
        decide(
          when: at(hour: 12, day: 17),
          rules: [rule(window: officeHours())],
        ).willReply,
        isTrue,
      );
    });

    test('a weekday window is closed on the days it does not name', () {
      // The 15th is a Thursday; the 17th is a Saturday.
      final weekdaysOnly = officeHours(
        weekdays: const {
          DateTime.monday,
          DateTime.tuesday,
          DateTime.wednesday,
          DateTime.thursday,
          DateTime.friday,
        },
      );

      expect(
        decide(
          when: at(hour: 12),
          rules: [rule(window: weekdaysOnly)],
        ).willReply,
        isTrue,
      );
      expect(
        decide(
          when: at(hour: 12, day: 17),
          rules: [rule(window: weekdaysOnly)],
        ).refusal,
        AutoReplyRefusal.outsideSchedule,
      );
    });

    test('a wrapping window belongs to the day it opened on', () {
      // Friday 22:00 → Saturday 07:00 is *the Friday window*. Two in the
      // morning on Saturday is inside it; two in the morning on Friday is not,
      // because that belongs to Thursday's.
      final fridayNight = overnight(weekdays: const {DateTime.friday});

      // Friday the 16th, 23:00 — the evening half.
      expect(
        decide(
          when: at(hour: 23, day: 16),
          rules: [rule(window: fridayNight)],
        ).willReply,
        isTrue,
      );
      // Saturday the 17th, 02:00 — the morning half of Friday's window.
      expect(
        decide(
          when: at(hour: 2, day: 17),
          rules: [rule(window: fridayNight)],
        ).willReply,
        isTrue,
      );
      // Friday the 16th, 02:00 — this belongs to Thursday's window.
      expect(
        decide(
          when: at(hour: 2, day: 16),
          rules: [rule(window: fridayNight)],
        ).refusal,
        AutoReplyRefusal.outsideSchedule,
      );
    });
  });
}
