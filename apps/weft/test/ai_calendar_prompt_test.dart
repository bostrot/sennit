import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:weft/services/ai/auto_reply_writer.dart';
import 'package:weft/services/ai/smart_replies.dart';

/// The calendar as the two AI prompts carry it: in the system message, in one
/// wording for both, and not at all when there is none.
void main() {
  const section =
      'It is now Sat 2026-10-17 21:10.\n'
      'The user is busy at these times, and free at every other time until '
      'Sat 2026-10-31 21:10:\n'
      '- Mon 2026-10-19 09:00–10:30';

  /// A model that records what it was sent and answers [content].
  (http.Client, List<Map<String, Object?>>) recording(String content) {
    final bodies = <Map<String, Object?>>[];
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, Object?>);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': content},
              'finish_reason': 'stop',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    return (client, bodies);
  }

  String systemOf(Map<String, Object?> body) =>
      ((body['messages']! as List).first as Map)['content'] as String;

  group('calendarPromptBlock', () {
    test('is empty without a calendar', () {
      expect(calendarPromptBlock(null), '');
      expect(calendarPromptBlock('  '), '');
    });

    test('carries the section and the rules for using it', () {
      final block = calendarPromptBlock(section);

      expect(block, contains(section));
      expect(block, contains('answer from this calendar'));
      expect(block, contains('Never say what the user is busy with'));
    });
  });

  group('composeAutoReply', () {
    Future<List<Map<String, Object?>>> send({String? calendar}) async {
      final (client, bodies) = recording('<reply>Monday is full.</reply>');
      final draft = await composeAutoReply(
        baseUrl: 'http://localhost:11434/v1',
        model: 'llama3',
        instruction: 'Say I am away.',
        chatTitle: 'Grace',
        transcript: const ['Grace: free on Monday morning?'],
        calendar: calendar,
        client: client,
      );
      expect(draft.text, 'Monday is full.');
      return bodies;
    }

    test(
      'the calendar follows the instruction in the system message',
      () async {
        final system = systemOf((await send(calendar: section)).single);

        expect(system, contains(section));
        expect(
          system.indexOf('Say I am away.'),
          lessThan(system.indexOf(section)),
        );
      },
    );

    test('no calendar, no calendar paragraph', () async {
      final system = systemOf((await send()).single);

      expect(system, isNot(contains("The user's calendar")));
    });
  });

  group('suggestSmartReplies', () {
    test('the chips are suggested in the light of the calendar', () async {
      final (client, bodies) = recording(
        '{"replies": ["Monday is full, Tuesday?"]}',
      );

      final replies = await suggestSmartReplies(
        baseUrl: 'http://localhost:11434/v1',
        model: 'llama3',
        chatTitle: 'Grace',
        transcript: const ['Grace: free on Monday morning?'],
        calendar: section,
        client: client,
      );

      expect(replies, ['Monday is full, Tuesday?']);
      expect(systemOf(bodies.single), contains(section));
    });
  });
}
