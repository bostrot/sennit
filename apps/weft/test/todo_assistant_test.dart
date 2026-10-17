/// The to-do assistant's prompt, parser and gate.
///
/// The parser is the part that decides what lands on someone's list, so it is
/// pinned against the shapes small local models actually produce: fenced
/// JSON, bare-string entries, reasoning before the answer, numbers that point
/// past the end of the list, and titles the list already has.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/services/todo/todo_assistant.dart';
import 'package:weft/services/todo/todo_item.dart';

void main() {
  final open = [
    TodoItem(id: 'a', title: 'Return the drill', createdAt: DateTime(2026)),
    TodoItem(id: 'b', title: 'Book the table', createdAt: DateTime(2026)),
  ];

  group('parseTodoChanges', () {
    test('reads adds with due dates and maps done numbers to ids', () {
      final changes = parseTodoChanges(
        '{"add": [{"title": "Send Anna the photos", "due": "2026-05-05"}], '
        '"done": [2]}',
        open: open,
      );
      expect(changes.add.single.title, 'Send Anna the photos');
      expect(changes.add.single.due, DateTime(2026, 5, 5));
      expect(changes.complete, {'b'});
    });

    test('takes fenced JSON after reasoning, and bare-string entries', () {
      final changes = parseTodoChanges(
        '<think>she asked for the cable</think>\n'
        '```json\n{"add": ["Bring the long cable"], "done": ["1"]}\n```',
        open: open,
      );
      expect(changes.add.single.title, 'Bring the long cable');
      expect(changes.add.single.due, isNull);
      expect(changes.complete, {'a'});
    });

    test(
      'drops out-of-range numbers, duplicates, junk and impossible dates',
      () {
        final changes = parseTodoChanges(
          '{"add": [{"title": "return the DRILL!"}, {"title": ""}, 7, '
          '{"title": "Call the bank", "due": "2026-02-30"}, '
          '{"title": "Call the bank"}], "done": [0, 3, "x"]}',
          open: open,
        );
        expect(changes.add.map((p) => p.title), ['Call the bank']);
        expect(changes.add.single.due, isNull);
        expect(changes.complete, isEmpty);
      },
    );

    test('caps how many entries one answer may add', () {
      final many = [for (var i = 0; i < 8; i++) '"Task $i"'].join(',');
      final changes = parseTodoChanges('{"add": [$many], "done": []}');
      expect(changes.add, hasLength(kTodoMaxAddsPerAnswer));
    });

    test('anything that is not JSON changes nothing', () {
      expect(parseTodoChanges('Sure! I added it.').isEmpty, isTrue);
      expect(parseTodoChanges('<think>still going').isEmpty, isTrue);
      expect(parseTodoChanges('{"add": "nope"').isEmpty, isTrue);
    });
  });

  group('mightConcernTodo', () {
    test(
      'lets requests, promises and reports through in several languages',
      () {
        expect(mightConcernTodo('Could you bring the cable?'), isTrue);
        expect(mightConcernTodo('Kannst du morgen die Fotos schicken'), isTrue);
        expect(mightConcernTodo("N'oublie pas le pain"), isTrue);
        expect(mightConcernTodo('记得买牛奶'), isTrue);
        expect(mightConcernTodo('ok, erledigt'), isTrue);
      },
    );

    test('keeps small talk away from the model', () {
      expect(mightConcernTodo('haha nice'), isFalse);
      expect(mightConcernTodo('Good morning!'), isFalse);
      expect(mightConcernTodo('   '), isFalse);
    });
  });

  group('proposeTodoChanges', () {
    test(
      'sends the numbered open list and the transcript, reads the answer',
      () async {
        late Map<String, Object?> sent;
        final client = MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content':
                        '{"add": [{"title": "Bring the cable"}], '
                        '"done": [1]}',
                  },
                },
              ],
            }),
            200,
          );
        });

        final changes = await proposeTodoChanges(
          baseUrl: 'http://llm.local/v1/',
          model: 'small',
          chatTitle: 'Grace',
          transcript: const ['Grace: Could you bring the cable?'],
          open: open,
          today: DateTime(2026, 10, 17),
          client: client,
        );

        final messages = (sent['messages']! as List).cast<Map>();
        final last = messages.last['content'] as String;
        expect(last, contains('Today is 2026-10-17.'));
        expect(last, contains('1. Return the drill'));
        expect(last, contains('2. Book the table'));
        expect(last, contains('Grace: Could you bring the cable?'));
        expect(changes!.add.single.title, 'Bring the cable');
        expect(changes.complete, {'a'});
      },
    );

    test('a failing endpoint answers null rather than throwing', () async {
      final client = MockClient((_) async => http.Response('nope', 500));
      final changes = await proposeTodoChanges(
        baseUrl: 'http://llm.local/v1',
        model: 'small',
        chatTitle: 'Grace',
        transcript: const ['Grace: please call me'],
        open: const [],
        today: DateTime(2026, 10, 17),
        client: client,
      );
      expect(changes, isNull);
    });

    test('an empty transcript never reaches the endpoint', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });
      final changes = await proposeTodoChanges(
        baseUrl: 'http://llm.local/v1',
        model: 'small',
        chatTitle: 'Grace',
        transcript: const [],
        open: const [],
        today: DateTime(2026, 10, 17),
        client: client,
      );
      expect(changes, isNull);
      expect(called, isFalse);
    });
  });

  group('TodoItem', () {
    test('round-trips through JSON', () {
      final item = TodoItem(
        id: 'x',
        title: 'Send Anna the photos',
        createdAt: DateTime.utc(2026, 5, 4, 9),
        due: DateTime(2026, 5, 5),
        chatId: '!room',
        chatTitle: 'Anna',
        fromAi: true,
      ).copyWith(done: true);
      final back = TodoItem.fromJson(jsonDecode(jsonEncode(item.toJson())))!;
      expect(back.title, item.title);
      expect(back.due, DateTime(2026, 5, 5));
      expect(back.done, isTrue);
      expect(back.doneAt, isNotNull);
      expect(back.chatTitle, 'Anna');
      expect(back.fromAi, isTrue);
      expect(back.copyWith(done: false).doneAt, isNull);
    });

    test('skips rows it cannot read instead of losing the list', () {
      final items = TodoItem.listFromJson([
        {'id': 'ok', 'title': 'Keep me'},
        {'id': '', 'title': 'no id'},
        'garbage',
        {'id': 'no-title'},
      ]);
      expect(items.map((i) => i.id), ['ok']);
      expect(TodoItem.listFromJson('not a list'), isEmpty);
    });
  });
}
