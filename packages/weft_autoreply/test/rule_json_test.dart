import 'dart:convert';

import 'package:test/test.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/fixtures.dart';

/// Rules live in the settings table as one JSON blob, exactly like
/// `notify.policy`, so the round trip is load-bearing in two directions: a rule
/// written by this build has to come back identical, and a blob written by a
/// *newer* build has to degrade rather than take the whole list down with it.
void main() {
  group('round trip', () {
    test('a fully-specified rule survives unchanged', () {
      final original = AutoReplyRule(
        id: 'rule_1',
        name: 'Out of office',
        prompt: 'Say I am away until Monday.',
        audience: const ContactAudience({'contact_1', 'contact_2'}),
        enabled: true,
        window: officeHours(
          offsetMinutes: 330,
          weekdays: const {DateTime.monday, DateTime.friday},
        ),
        cooldown: const Duration(minutes: 45),
      );

      final restored = AutoReplyRule.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      );

      expect(restored, original);
    });

    test('each audience shape survives', () {
      const audiences = [
        EveryoneAudience(),
        NetworkAudience({ChatNetwork.whatsapp, ChatNetwork.sms}),
        LabelAudience('Verein'),
        ContactAudience({'contact_1'}),
      ];

      for (final audience in audiences) {
        final restored = AutoReplyAudience.fromJson(
          jsonDecode(jsonEncode(audience.toJson())),
        );
        expect(restored, audience, reason: '$audience did not survive');
      }
    });

    test('a rule with no window comes back with no window', () {
      final restored = AutoReplyRule.fromJson(
        jsonDecode(jsonEncode(rule().toJson())),
      );

      expect(restored?.window, isNull);
    });

    test('the whole list round-trips in order', () {
      final rules = [
        rule(id: 'a'),
        rule(id: 'b', audience: const LabelAudience('Work')),
        rule(id: 'c', enabled: false),
      ];

      final restored = AutoReplyRule.listFromJson(
        jsonDecode(jsonEncode(AutoReplyRule.listToJson(rules))),
      );

      expect(restored, rules);
    });

    test('an unwritten list reads as no rules', () {
      // What a fresh install finds. Null must not be a crash and must not be
      // "reply to everyone".
      expect(AutoReplyRule.listFromJson(null), isEmpty);
      expect(AutoReplyRule.listFromJson(const <String, Object?>{}), isEmpty);
      expect(AutoReplyRule.listFromJson('nonsense'), isEmpty);
    });
  });

  group('degrading rather than refusing', () {
    test('an unknown audience kind drops that rule and keeps the rest', () {
      final blob = {
        'rules': [
          {
            'id': 'from_the_future',
            'name': 'Something new',
            'prompt': 'hello',
            'audience': {'kind': 'sentiment', 'above': 0.8},
            'enabled': true,
          },
          rule(id: 'ordinary').toJson(),
        ],
      };

      final restored = AutoReplyRule.listFromJson(blob);

      expect(restored.map((r) => r.id), ['ordinary']);
    });

    test('an unknown extra field is ignored', () {
      final blob = {
        ...rule(id: 'rule_1').toJson(),
        'temperature': 0.4,
        'model': 'llama3',
      };

      expect(AutoReplyRule.fromJson(blob)?.id, 'rule_1');
    });

    test('a rule with no id is dropped', () {
      // No id means no ledger, and a rule whose cooldown cannot be tracked is
      // worse kept than dropped.
      expect(
        AutoReplyRule.fromJson({
          'prompt': 'hello',
          'audience': {'kind': 'everyone'},
        }),
        isNull,
      );
    });

    test('a missing enabled flag reads as off', () {
      // The safe direction. A rule that started replying because a field was
      // absent would be a message sent by a parser.
      expect(
        AutoReplyRule.fromJson({
          'id': 'rule_1',
          'prompt': 'hello',
          'audience': {'kind': 'everyone'},
        })?.enabled,
        isFalse,
      );
    });

    test('a nonsensical cooldown falls back to the default', () {
      expect(
        AutoReplyRule.fromJson({
          'id': 'rule_1',
          'audience': {'kind': 'everyone'},
          'cooldownMinutes': -5,
        })?.cooldown,
        kAutoReplyDefaultCooldown,
      );
      expect(
        AutoReplyRule.fromJson({
          'id': 'rule_1',
          'audience': {'kind': 'everyone'},
          'cooldownMinutes': 'soon',
        })?.cooldown,
        kAutoReplyDefaultCooldown,
      );
    });

    test('a zero cooldown is honoured, not treated as unset', () {
      expect(
        AutoReplyRule.fromJson({
          'id': 'rule_1',
          'audience': {'kind': 'everyone'},
          'cooldownMinutes': 0,
        })?.cooldown,
        Duration.zero,
      );
    });

    test('an unknown network in an audience is dropped, the rest kept', () {
      final restored = AutoReplyAudience.fromJson({
        'kind': 'network',
        'networks': ['whatsapp', 'telepathy'],
      });

      expect(restored, const NetworkAudience({ChatNetwork.whatsapp}));
    });

    test('a malformed window reads as no window rather than as no rule', () {
      final restored = AutoReplyRule.fromJson({
        'id': 'rule_1',
        'audience': {'kind': 'everyone'},
        'window': {'startMinute': 'nine'},
      });

      expect(restored?.window, isNull);
      expect(restored?.id, 'rule_1');
    });

    test('an out-of-range weekday is dropped', () {
      final restored = ReplyWindow.fromJson({
        'startMinute': 540,
        'endMinute': 1020,
        'weekdays': [1, 0, 8, 7],
      });

      expect(restored?.weekdays, {DateTime.monday, DateTime.sunday});
    });
  });

  group('copyWith', () {
    test('clearing a window is reachable', () {
      // A `??` here would make "any time" unreachable once a window was set,
      // which is a state the editor has to be able to get back to.
      final withWindow = rule(window: officeHours());

      expect(withWindow.copyWith(window: null).window, isNull);
      expect(withWindow.copyWith(name: 'Renamed').window, isNotNull);
    });

    test('the id is not copyable', () {
      // Stable across edits, so rewriting a prompt does not reset the cooldown.
      final edited = rule(id: 'rule_1').copyWith(prompt: 'something else');

      expect(edited.id, 'rule_1');
    });
  });

  group('isUsable', () {
    test('a rule needs both a switch and a prompt', () {
      expect(rule().isUsable, isTrue);
      expect(rule(enabled: false).isUsable, isFalse);
      expect(rule(prompt: '').isUsable, isFalse);
      expect(rule(prompt: '   \n ').isUsable, isFalse);
    });
  });
}
