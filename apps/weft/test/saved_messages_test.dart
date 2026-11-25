import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/saved_messages.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/chat/saved_messages_screen.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';
import 'package:weft_sync/weft_sync.dart';

import 'support/seeded_repository.dart';

/// Saving messages to come back to: the rows, the action on a message, and
/// the list that finds them again.
void main() {
  final a = seededMessage(
    eventId: r'$a',
    body: 'the wifi code',
    minutesAgo: 30,
  );
  final b = seededMessage(eventId: r'$b', body: 'see you at 8', minutesAgo: 20);

  SavedMessage saved(
    String eventId,
    String text, {
    String room = '!r:x',
    String sender = 'Sam',
    int savedAt = 0,
  }) => SavedMessage(
    eventId: eventId,
    chatId: room,
    roomId: room,
    senderName: sender,
    text: text,
    sentAt: DateTime.utc(2026, 11, 1),
    savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt),
  );

  group('the rows', () {
    test('round-trip, newest save first', () {
      final settings = WeftStores.inMemory().settings;
      setMessageSaved(settings, saved(r'$1', 'one', savedAt: 1), isSaved: true);
      setMessageSaved(settings, saved(r'$2', 'two', savedAt: 2), isSaved: true);

      final list = readSavedMessages(settings);
      expect(list.map((s) => s.eventId), [r'$2', r'$1']);
      expect(list.last.text, 'one');
      expect(list.last.senderName, 'Sam');
      expect(
        list.last.sentAt.isAtSameMomentAs(DateTime.utc(2026, 11, 1)),
        isTrue,
      );

      setMessageSaved(settings, list.last, isSaved: false);
      expect(readSavedMessages(settings).map((s) => s.eventId), [r'$2']);
    });

    test('a row this version cannot read is skipped', () {
      final settings = WeftStores.inMemory().settings
        ..setString('${WeftSettings.savedMessagePrefix}\$x', 'not json')
        ..setString('${WeftSettings.savedMessagePrefix}\$y', '{"room": 1}');
      expect(readSavedMessages(settings), isEmpty);
    });

    test('travel with device sync', () {
      expect(
        SyncPolicy.syncsSetting('${WeftSettings.savedMessagePrefix}\$a'),
        isTrue,
      );
    });
  });

  test('filtering by room and by every word of the query', () {
    final list = [
      saved(r'$1', 'The wifi code is 1234', room: '!home:x'),
      saved(r'$2', 'Dinner at eight', room: '!home:x', sender: 'Kim'),
      saved(r'$3', 'wifi at the office', room: '!work:x'),
    ];
    expect(filterSavedMessages(list, query: 'wifi').map((s) => s.eventId), [
      r'$1',
      r'$3',
    ]);
    expect(
      filterSavedMessages(
        list,
        rooms: {'!home:x'},
        query: 'WIFI code',
      ).map((s) => s.eventId),
      [r'$1'],
    );
    expect(filterSavedMessages(list, query: 'kim').map((s) => s.eventId), [
      r'$2',
    ]);
  });

  group('in the app', () {
    late DemoChatRepository demo;
    late WeftStores stores;

    setUp(() {
      clearMessageDocumentCache();
      demo = DemoChatRepository(uploadTick: Duration.zero);
      stores = WeftStores.inMemory();
    });
    tearDown(() => demo.dispose());

    Future<void> pump(WidgetTester tester, Widget home) async {
      final repository = SeededChatRepository(demo, messages: [a, b]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(repository),
            storesProvider.overrideWithValue(stores),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(),
            home: home,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> chooseAction(WidgetTester tester, String label) async {
      await tester.longPress(
        find.text('the wifi code', findRichText: true).first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      final action = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(label),
      );
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
    }

    testWidgets('save puts the message on the list, and the sheet then '
        'offers to take it off', (tester) async {
      await pump(tester, const ChatView(chatId: 'seeded:chat'));

      await chooseAction(tester, 'Save');
      final list = readSavedMessages(stores.settings);
      expect(list.single.eventId, r'$a');
      expect(list.single.text, 'the wifi code');
      expect(list.single.chatId, 'seeded:chat');
      expect(find.text('Saved'), findsOneWidget);

      await chooseAction(tester, 'Remove from saved');
      expect(readSavedMessages(stores.settings), isEmpty);
    });

    testWidgets('the list searches and removes', (tester) async {
      setMessageSaved(
        stores.settings,
        SavedMessage.of(a, chatId: 'seeded:chat', text: a.body),
        isSaved: true,
      );
      setMessageSaved(
        stores.settings,
        SavedMessage.of(b, chatId: 'seeded:chat', text: b.body),
        isSaved: true,
      );
      await pump(tester, const SavedMessagesScreen());
      expect(find.text('the wifi code'), findsOneWidget);
      expect(find.text('see you at 8'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'wifi');
      await tester.pumpAndSettle();
      expect(find.text('see you at 8'), findsNothing);

      await tester.tap(find.byTooltip('Remove from saved'));
      await tester.pumpAndSettle();
      expect(readSavedMessages(stores.settings).single.eventId, r'$b');
      expect(find.text('No saved message matches.'), findsOneWidget);
    });

    testWidgets('an empty list says how to save', (tester) async {
      await pump(tester, const SavedMessagesScreen());
      expect(
        find.text('Nothing saved yet. Long-press a message and choose Save.'),
        findsOneWidget,
      );
    });
  });
}
