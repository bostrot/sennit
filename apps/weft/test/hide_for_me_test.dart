import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/hidden_messages.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';
import 'package:weft_sync/weft_sync.dart';

import 'support/seeded_repository.dart';

/// Hide for me, and leaving the deleted-message placeholders out: what the
/// user sees changes, the room does not.
void main() {
  final a = seededMessage(eventId: r'$a', body: 'kept', minutesAgo: 30);
  final b = seededMessage(eventId: r'$b', body: 'hidden', minutesAgo: 20);
  final gone = seededMessage(
    eventId: r'$c',
    body: '',
    minutesAgo: 10,
  ).copyWith(redacted: true);

  group('withoutHidden', () {
    test('leaves out the hidden messages', () {
      expect(withoutHidden([a, b], hidden: {r'$b'}, hideDeleted: false), [a]);
    });

    test('leaves out deleted ones only when asked to', () {
      expect(withoutHidden([a, gone], hidden: {}, hideDeleted: false), [
        a,
        gone,
      ]);
      expect(withoutHidden([a, gone], hidden: {}, hideDeleted: true), [a]);
    });

    test('hands back the same list when nothing is left out', () {
      final list = [a, b];
      expect(
        withoutHidden(list, hidden: {r'$z'}, hideDeleted: true),
        same(list),
      );
    });
  });

  test('hidden messages and the deleted switch travel with device sync', () {
    expect(
      SyncPolicy.syncsSetting('${WeftSettings.hiddenMessagePrefix}\$b'),
      isTrue,
    );
    expect(SyncPolicy.syncsSetting(WeftSettings.hideDeletedMessages), isTrue);
  });

  group('in the conversation', () {
    late DemoChatRepository demo;
    late WeftStores stores;

    setUp(() {
      clearMessageDocumentCache();
      demo = DemoChatRepository(uploadTick: Duration.zero);
      stores = WeftStores.inMemory();
    });
    tearDown(() => demo.dispose());

    Future<void> pump(WidgetTester tester, List<WeftMessage> messages) async {
      final repository = SeededChatRepository(demo, messages: messages);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(repository),
            storesProvider.overrideWithValue(stores),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(),
            home: ChatView(chatId: repository.chatId),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('hide for me takes the message away, and undo brings it back', (
      tester,
    ) async {
      await pump(tester, [a, b]);
      expect(find.text('hidden', findRichText: true), findsOneWidget);

      await tester.longPress(
        find.text('hidden', findRichText: true).first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      final action = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Hide for me'),
      );
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();

      expect(find.text('hidden', findRichText: true), findsNothing);
      expect(find.text('kept', findRichText: true), findsOneWidget);
      expect(
        stores.settings.getString('${WeftSettings.hiddenMessagePrefix}\$b'),
        b.roomId,
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('hidden', findRichText: true), findsOneWidget);
      expect(
        stores.settings.getString('${WeftSettings.hiddenMessagePrefix}\$b'),
        isNull,
      );
    });

    testWidgets('deleted placeholders go when the switch is on', (
      tester,
    ) async {
      await pump(tester, [a, gone]);
      expect(find.text('Message deleted'), findsOneWidget);

      stores.settings.setBool(WeftSettings.hideDeletedMessages, value: true);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatView)),
      );
      container.read(settingsRevisionProvider.notifier).bump();
      await tester.pumpAndSettle();

      expect(find.text('Message deleted'), findsNothing);
      expect(find.text('kept', findRichText: true), findsOneWidget);
    });
  });
}
