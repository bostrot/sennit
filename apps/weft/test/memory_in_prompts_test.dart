/// Personal memory in the AI features beyond the reply chips, quick messages
/// and auto-replies (those are in person_memory_test.dart): the to-do review
/// and a calendar entry's title, and the share of the budget each feature
/// gives it.
///
/// The claims: each prompt carries the memory in its system message and
/// nowhere else, says nothing about notes without one, and a short-answer
/// feature carries less of it than a message the user sends.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/services/ai/event_title.dart';
import 'package:weft/services/ai/llm_budget.dart';
import 'package:weft/services/ai/person_memory.dart';
import 'package:weft/services/todo/todo_assistant.dart';

const _hosted = 'https://api.openai.com/v1';

const _memory = AiMemory(
  chat: 'Planning Mia\'s birthday party',
  people: [(name: 'Lea', note: 'My sister, calls me Ricky')],
);

http.Client _answering(String content, void Function(Map body) onRequest) =>
    MockClient((request) async {
      onRequest(jsonDecode(request.body) as Map);
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

List<Map> _messages(Map body) => (body['messages'] as List).cast<Map>();

void main() {
  group('the to-do review', () {
    Future<Map> ask(AiMemory? memory) async {
      late Map sent;
      await proposeTodoChanges(
        baseUrl: _hosted,
        model: 'gpt',
        chatTitle: 'Lea',
        transcript: const ['Lea: Kannst du das Geschenk besorgen?'],
        open: const [],
        today: DateTime(2026, 11, 24),
        memory: memory,
        client: _answering('{"add": [], "done": []}', (b) => sent = b),
      );
      return sent;
    }

    test('carries the memory in its system message only', () async {
      final messages = _messages(await ask(_memory));
      expect(messages.first['content'], contains('My sister, calls me Ricky'));
      expect(messages.first['content'], contains("Mia's birthday party"));
      expect(
        messages.skip(1).where((m) => '${m['content']}'.contains('Ricky')),
        isEmpty,
      );
    });

    test('without one, says nothing about notes', () async {
      final messages = _messages(await ask(null));
      expect(messages.first['content'], isNot(contains('noted')));
    });
  });

  group('a calendar title', () {
    Future<Map> ask(AiMemory? memory) async {
      late Map sent;
      await suggestEventTitle(
        baseUrl: _hosted,
        model: 'gpt',
        transcript: const ['>> Lea: Party am Samstag um 15 Uhr'],
        memory: memory,
        client: _answering('{"title": "Party bei Lea"}', (b) => sent = b),
      );
      return sent;
    }

    test('carries the memory in its system message only', () async {
      final messages = _messages(await ask(_memory));
      expect(messages.first['content'], contains('My sister'));
      expect(
        messages.skip(1).where((m) => '${m['content']}'.contains('sister')),
        isEmpty,
      );
    });

    test('without one, says nothing about notes', () async {
      final messages = _messages(await ask(null));
      expect(messages.first['content'], isNot(contains('noted')));
    });
  });

  group('the budget per feature', () {
    test('short answers carry less than a message the user sends', () {
      for (final base in [_hosted, 'http://localhost:11434/v1']) {
        final budget = LlmBudget.resolve(base);
        final full = budget.memoryCharsFor(AiFeature.quickMessage);
        expect(full, budget.memoryChars);
        expect(budget.memoryCharsFor(AiFeature.autoReply), full);
        expect(
          budget.memoryCharsFor(AiFeature.smartReplies),
          lessThanOrEqualTo(full),
        );
        expect(
          budget.memoryCharsFor(AiFeature.eventTitle),
          lessThanOrEqualTo(budget.memoryCharsFor(AiFeature.todo)),
        );
        expect(budget.memoryCharsFor(AiFeature.todo), lessThanOrEqualTo(full));
      }
    });

    test('a long chat memory is cut to the feature\'s share', () {
      final budget = LlmBudget.resolve(_hosted);
      final memory = AiMemory(chat: List.filled(400, 'Fakt').join('\n'));
      String block(AiFeature feature) => memoryPromptBlock(
        memory,
        baseUrl: _hosted,
        budget: budget,
        feature: feature,
      );
      final chips = block(AiFeature.smartReplies);
      final quick = block(AiFeature.quickMessage);
      expect(chips.length, lessThan(quick.length));
      expect(
        quick.length,
        lessThanOrEqualTo(budget.memoryChars + 400),
        reason: 'the block is the memory plus a fixed preamble',
      );
    });
  });
}
