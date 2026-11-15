/// The list, its storage, its Home Assistant mirror, and the screen.
///
/// Over a real in-memory store, because the promise that matters is "what you
/// ticked is still ticked after a restart"; and over a fake Home Assistant
/// that records calls, because the mirror is fire-and-forget and would
/// otherwise fail where nobody looks.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/app/todo_providers.dart';
import 'package:weft/features/settings/integrations_screen.dart';
import 'package:weft/features/todo/todo_screen.dart';
import 'package:weft/services/integrations/home_assistant.dart';
import 'package:weft/services/todo/todo_assistant.dart';
import 'package:weft/services/todo/todo_item.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

void main() {
  final en = lookupAppL10n(const Locale('en'));
  const chat = Chat(
    id: '!anna:example.org',
    title: 'Anna',
    sources: [
      ChatSource(roomId: '!anna:example.org', network: ChatNetwork.signal),
    ],
  );

  /// Every call the fake Home Assistant received, as `path body`.
  late List<String> haCalls;
  late int haStatus;

  HomeAssistantClient fakeHa() => HomeAssistantClient(
    baseUrl: Uri.parse('http://ha.local:8123'),
    token: 't',
    httpClient: MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/states') {
        return http.Response(
          jsonEncode([
            {
              'entity_id': 'todo.shopping',
              'attributes': {'friendly_name': 'Shopping'},
            },
            {'entity_id': 'light.kitchen', 'attributes': <String, Object?>{}},
            {
              'entity_id': 'todo.sennit',
              'attributes': {'friendly_name': 'Sennit'},
            },
          ]),
          200,
        );
      }
      haCalls.add('${request.url.path} ${request.body}');
      return http.Response('[]', haStatus);
    }),
  );

  setUp(() {
    haCalls = [];
    haStatus = 200;
  });

  ProviderContainer containerFor(WeftStores stores, {HomeAssistantClient? ha}) {
    final container = ProviderContainer(
      overrides: [
        storesProvider.overrideWithValue(stores),
        homeAssistantProvider.overrideWithValue(ha),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('TodoList', () {
    test('survives a restart: adds, ticks and edits are written', () {
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);

      final first = containerFor(stores);
      final list = first.read(todoListProvider.notifier);
      final milk = list.add('  Buy   milk ')!;
      list.add('Call the bank', due: DateTime(2026, 10, 20));
      list.setDone(milk.id, done: true);
      expect(list.add('   '), isNull);

      final second = containerFor(stores);
      final items = second.read(todoListProvider);
      expect(items.map((i) => i.title), ['Call the bank', 'Buy milk']);
      expect(items.last.done, isTrue);
      expect(items.first.due, DateTime(2026, 10, 20));

      second
          .read(todoListProvider.notifier)
          .edit(items.first.id, title: 'Call the bank about the card');
      expect(second.read(todoListProvider).first.due, isNull);
      expect(second.read(todoListProvider.notifier).clearDone(), 1);
      expect(second.read(todoListProvider), hasLength(1));
    });

    test('applies the assistant: adds with the chat, ticks, skips repeats', () {
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      final container = containerFor(stores);
      final list = container.read(todoListProvider.notifier);
      list.add('Book the table');
      final drill = list.add('Return the drill', chatId: chat.id)!;

      list.applyChanges(
        chat,
        TodoChanges(
          add: const [
            TodoProposal(title: 'Send Anna the photos'),
            TodoProposal(title: 'book the table'),
          ],
          complete: {drill.id},
        ),
      );

      final items = container.read(todoListProvider);
      final photos = items.firstWhere((i) => i.title == 'Send Anna the photos');
      expect(photos.fromAi, isTrue);
      expect(photos.chatTitle, 'Anna');
      expect(
        items.where((i) => i.title.toLowerCase() == 'book the table'),
        hasLength(1),
      );
      expect(items.firstWhere((i) => i.id == drill.id).done, isTrue);
      expect(list.openFor(chat.id).map((i) => i.title), [
        'Send Anna the photos',
      ]);
    });

    test('mirrors into Home Assistant only when switched on and aimed', () async {
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      final container = containerFor(stores, ha: fakeHa());
      final list = container.read(todoListProvider.notifier);

      list.add('Not mirrored');
      await pumpEventQueue();
      expect(haCalls, isEmpty);

      stores.settings
        ..setBool(TodoSettings.homeAssistantSync, value: true)
        ..setString(TodoSettings.homeAssistantEntity, 'todo.sennit');
      container.read(settingsRevisionProvider.notifier).bump();

      final item = list.add('Buy milk', due: DateTime(2026, 10, 20))!;
      list.setDone(item.id, done: true);
      await pumpEventQueue();

      expect(haCalls, [
        '/api/services/todo/add_item '
            '{"entity_id":"todo.sennit","item":"Buy milk","due_date":"2026-10-20"}',
        '/api/services/todo/update_item '
            '{"entity_id":"todo.sennit","item":"Buy milk","status":"completed"}',
      ]);
    });

    test('a Home Assistant that is down does not stop the list', () async {
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      stores.settings
        ..setBool(TodoSettings.homeAssistantSync, value: true)
        ..setString(TodoSettings.homeAssistantEntity, 'todo.sennit');
      haStatus = 500;
      final container = containerFor(stores, ha: fakeHa());

      container.read(todoListProvider.notifier).add('Still here');
      await pumpEventQueue();
      expect(container.read(todoListProvider).single.title, 'Still here');
    });
  });

  group('HomeAssistantClient to-do calls', () {
    test('lists only todo entities, sorted by name', () async {
      final lists = await fakeHa().todoLists();
      expect(lists.map((l) => l.entityId), ['todo.sennit', 'todo.shopping']);
      expect(lists.first.name, 'Sennit');
    });

    test('retries without the date when a list has no due dates', () async {
      final calls = <Map<String, Object?>>[];
      final ha = HomeAssistantClient(
        baseUrl: Uri.parse('http://ha.local:8123/'),
        token: 't',
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          calls.add(body);
          return http.Response('', body.containsKey('due_date') ? 400 : 200);
        }),
      );
      await ha.addTodoItem(
        'todo.shopping',
        'Milk',
        due: DateTime(2026, 10, 20),
      );
      expect(calls, hasLength(2));
      expect(calls.last, {'entity_id': 'todo.shopping', 'item': 'Milk'});
    });

    test('reports a refusal it cannot work around', () async {
      haStatus = 401;
      await expectLater(
        fakeHa().setTodoItemDone('todo.sennit', 'Milk', done: false),
        throwsA(isA<HomeAssistantException>()),
      );
      expect(haCalls.single, contains('"status":"needs_action"'));
    });
  });

  group('TodoScreen', () {
    Future<WeftStores> pump(WidgetTester tester, {HomeAssistantClient? ha}) {
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      return tester
          .pumpWidget(
            ProviderScope(
              overrides: [
                storesProvider.overrideWithValue(stores),
                homeAssistantProvider.overrideWithValue(ha),
              ],
              child: MaterialApp(
                localizationsDelegates: weftLocalizationsDelegates,
                supportedLocales: weftSupportedLocales,
                theme: WeftTheme.build(),
                home: const TodoScreen(),
              ),
            ),
          )
          .then((_) => tester.pumpAndSettle())
          .then((_) => stores);
    }

    testWidgets('adds an entry, ticks it, and folds it under Done', (
      tester,
    ) async {
      final stores = await pump(tester);
      expect(find.text(en.todoEmpty), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Buy milk');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Buy milk'), findsOneWidget);
      expect(find.text(en.todoEmpty), findsNothing);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(find.text(en.todoDoneSection(1)), findsOneWidget);
      // Folded away until asked for.
      expect(find.text('Buy milk'), findsNothing);
      await tester.tap(find.text(en.todoDoneSection(1)));
      await tester.pumpAndSettle();
      expect(find.text('Buy milk'), findsOneWidget);

      final saved = TodoItem.listFromJson(
        stores.settings.getJson(TodoSettings.items)?['items'],
      );
      expect(saved.single.done, isTrue);
    });

    testWidgets('the settings sheet says what is missing before a switch '
        'can be turned on', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip(en.todoSettingsTooltip));
      await tester.pumpAndSettle();

      expect(find.text(en.todoAiNeedsEndpoint), findsOneWidget);
      expect(find.text(en.todoHaNeedsSetup), findsOneWidget);
      final switches = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(switches.every((s) => s.onChanged == null), isTrue);
    });

    testWidgets('with Home Assistant connected, its lists can be picked', (
      tester,
    ) async {
      final stores = await pump(tester, ha: fakeHa());
      await tester.tap(find.byTooltip(en.todoSettingsTooltip));
      await tester.pumpAndSettle();

      await tester.tap(find.text(en.todoHaTitle));
      await tester.pumpAndSettle();
      expect(stores.settings.getBool(TodoSettings.homeAssistantSync), isTrue);

      await tester.tap(find.text(en.todoHaListField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sennit').last);
      await tester.pumpAndSettle();
      expect(
        stores.settings.getString(TodoSettings.homeAssistantEntity),
        'todo.sennit',
      );
    });
  });
}
