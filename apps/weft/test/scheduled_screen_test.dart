import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/schedule/scheduled_screen.dart';
import 'package:weft/services/schedule/scheduled_actions.dart';
import 'package:weft_design/weft_design.dart';

/// Stands in for the OS: notes what was scheduled and taken back.
class _FakeReminders extends ReminderScheduler {
  final scheduled = <int>[];
  final cancelled = <int>[];

  @override
  Future<void> remind({
    required String chatId,
    required String title,
    required String body,
    required DateTime at,
  }) async => scheduled.add(ReminderScheduler.idFor(chatId, at));

  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

void main() {
  // Whole minutes: stored times round-trip through milliseconds.
  final now = DateTime.now();
  final soon = DateTime(now.year, now.month, now.day + 2, 9);
  final later = soon.add(const Duration(hours: 3));

  ScheduledMessage message() => ScheduledMessage(
    id: 'send-1',
    chatId: '!a:x',
    chatTitle: 'Alice',
    body: 'Happy birthday!',
    dueAtMs: soon.millisecondsSinceEpoch,
  );

  PendingReminder reminder() => PendingReminder(
    chatId: '!b:x',
    chatTitle: 'Bob',
    title: 'Reminder: Bob',
    body: 'Bring the keys',
    dueAtMs: later.millisecondsSinceEpoch,
  );

  Future<({WeftStores stores, ProviderContainer container, _FakeReminders os})>
  pump(WidgetTester tester, {bool seed = true}) async {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    final os = _FakeReminders();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storesProvider.overrideWithValue(stores),
          reminderSchedulerProvider.overrideWithValue(os),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: const ScheduledScreen(),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ScheduledScreen)),
      listen: false,
    );
    if (seed) {
      container.read(messageSchedulerProvider.notifier).schedule(message());
      await container.read(reminderListProvider.notifier).add(reminder());
    }
    await tester.pumpAndSettle();
    return (stores: stores, container: container, os: os);
  }

  testWidgets('says how to schedule when nothing is waiting', (tester) async {
    await pump(tester, seed: false);
    expect(find.textContaining('Long-press Send'), findsOneWidget);
  });

  testWidgets('lists scheduled messages and reminders together', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Send later'), findsOneWidget);
    expect(find.text('Reminders'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Happy birthday!'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Bring the keys'), findsOneWidget);
  });

  testWidgets('edits the text of a scheduled message', (tester) async {
    final (:stores, :container, os: _) = await pump(tester);
    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit text'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Happy birthday, Alice!');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Happy birthday, Alice!'), findsOneWidget);
    final queued = container.read(messageSchedulerProvider).single;
    expect(queued.body, 'Happy birthday, Alice!');
    expect(queued.dueAtMs, soon.millisecondsSinceEpoch);
    // Persisted, so the edit outlives a restart.
    final pending = stores.settings.getJson('schedule.outbox')!['pending'];
    expect((pending as List).single['body'], 'Happy birthday, Alice!');
  });

  testWidgets('deleting a reminder takes it back from the OS', (tester) async {
    final (stores: _, :container, :os) = await pump(tester);
    await tester.tap(find.byTooltip('More').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Bring the keys'), findsNothing);
    expect(container.read(reminderListProvider), isEmpty);
    expect(os.cancelled, [reminder().id]);
  });

  test('reminders that already fired are dropped on load', () {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    final past = PendingReminder(
      chatId: '!c:x',
      chatTitle: 'Carol',
      title: 'Reminder',
      body: '',
      dueAtMs: DateTime.now()
          .subtract(const Duration(minutes: 1))
          .millisecondsSinceEpoch,
    );
    stores.settings.setJson('schedule.reminders', {
      'pending': [past.toJson(), reminder().toJson()],
    });
    final container = ProviderContainer(
      overrides: [storesProvider.overrideWithValue(stores)],
    );
    addTearDown(container.dispose);

    expect(container.read(reminderListProvider).map((r) => r.chatTitle), [
      'Bob',
    ]);
  });

  test('moving a reminder reschedules it under its new id', () async {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    final os = _FakeReminders();
    final container = ProviderContainer(
      overrides: [
        storesProvider.overrideWithValue(stores),
        reminderSchedulerProvider.overrideWithValue(os),
      ],
    );
    addTearDown(container.dispose);
    final list = container.read(reminderListProvider.notifier);
    await list.add(reminder());
    final moved = later.add(const Duration(days: 1));
    await list.reschedule(reminder(), moved);

    expect(os.cancelled, [reminder().id]);
    expect(os.scheduled.last, reminder().at(moved).id);
    expect(container.read(reminderListProvider).single.dueAt, moved);
  });
}
