import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/notification_providers.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/services/notifications/conversation_clearer.dart';
import 'package:weft/services/notifications/notification_actions.dart';
import 'package:weft/services/notifications/open_chats.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/recording_repository.dart';
import 'package:weft/app/localisation.dart';

/// Stands in for the dismisser `main` installs once the service exists.
class _RecordingDismisser extends NotificationDismisserNotifier {
  _RecordingDismisser(this.cleared);

  final List<String> cleared;

  @override
  NotificationDismisser? build() =>
      (String chatId) async => cleared.add(chatId);
}

/// Opening a conversation reads it.
///
/// The inbox tile marked the chat read on tap, which covered the inbox and
/// nothing else. A notification tap routes straight to [ChatView] through the
/// deep-link handler and never touches that tile, so the conversation the user
/// was *looking at* kept its unread badge and its notification stayed in the
/// shade — and the next message they sent appeared to be what had left the
/// badge behind.
///
/// Reading belongs to the screen that shows the messages, so every door into
/// it — tile, deep link, share sheet, two-pane click-through — clears the
/// same state.
void main() {
  const mergedChat = 'merged:anna';

  late DemoChatRepository demo;
  late RecordingChatRepository repository;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
    repository = RecordingChatRepository(demo);
  });
  tearDown(() => demo.dispose());

  // Foreground is the app's to say, not the test binding's.
  late OpenChats openChats;
  setUp(() => openChats = OpenChats(isForeground: () => true));

  Future<List<String>> pump(
    WidgetTester tester, {
    String chatId = mergedChat,
    List<String>? dismissed,
    bool preview = false,
  }) async {
    final cleared = dismissed ?? <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository),
          openChatsProvider.overrideWithValue(openChats),
          notificationDismisserProvider.overrideWith(
            () => _RecordingDismisser(cleared),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: ChatView(chatId: chatId, preview: preview),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return cleared;
  }

  testWidgets('an open chat is on screen, and stops being when it is left', (
    tester,
  ) async {
    await pump(tester);
    expect(openChats.isOpen(mergedChat), isTrue);
    expect(openChats.isOpen('!konrad_wa_room:example.org'), isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(openChats.isOpen(mergedChat), isFalse);
  });

  testWidgets('a preview is a peek, and is not on screen', (tester) async {
    await pump(tester, preview: true);
    expect(openChats.isOpen(mergedChat), isFalse);
  });

  List<String> readCalls() => repository.calls
      .where((c) => c.method == 'markRead')
      .map((c) => c.key ?? '')
      .toList();

  testWidgets('opening a chat marks it read', (tester) async {
    await pump(tester);
    expect(readCalls(), contains(mergedChat));
  });

  testWidgets('opening a chat clears its notifications', (tester) async {
    final cleared = await pump(tester);
    expect(cleared, contains(mergedChat));
  });

  testWidgets('switching conversations reads the one now on screen', (
    tester,
  ) async {
    final cleared = await pump(tester);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository),
          openChatsProvider.overrideWithValue(openChats),
          notificationDismisserProvider.overrideWith(
            () => _RecordingDismisser(cleared),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: const ChatView(chatId: '!konrad_wa_room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(readCalls(), contains('!konrad_wa_room:example.org'));
    expect(cleared, contains('!konrad_wa_room:example.org'));
  });

  testWidgets('a chat that does not exist is not marked read', (tester) async {
    final cleared = await pump(tester, chatId: 'merged:nobody');
    expect(readCalls(), isEmpty);
    expect(cleared, isEmpty);
  });

  testWidgets('opening a thread reads the conversation it belongs to', (
    tester,
  ) async {
    // A thread is a screen of its own with a bar and a composer of its own, and
    // it is easy to build one that quietly stops doing the two things every
    // door into a conversation has to do.
    final cleared = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository),
          openChatsProvider.overrideWithValue(openChats),
          notificationDismisserProvider.overrideWith(
            () => _RecordingDismisser(cleared),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: const ChatView(chatId: mergedChat, threadRootId: r'$anything'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(readCalls(), contains(mergedChat));
    expect(cleared, contains(mergedChat));
  });

  group('clearing every surface', () {
    test('the shade is cancelled and the companions are republished', () async {
      // Two different mechanisms, one verb. The shade has rows that persist on
      // their own and are cancelled; the watch and the widget read the
      // snapshot and clear by it being written again.
      final dismissed = <String>[];
      var republished = 0;
      final clearer = ConversationClearer(
        dismissChat: (id) async => dismissed.add(id),
        republish: () async => republished++,
      );

      await clearer.clear('merged:anna');

      expect(dismissed, ['merged:anna']);
      expect(republished, 1);
    });

    test('a failing shade cancel still refreshes the companions', () async {
      // Each failure is one surface out of date; letting it become two is the
      // thing worth avoiding.
      var republished = 0;
      final clearer = ConversationClearer(
        dismissChat: (_) async => throw StateError('no notification service'),
        republish: () async => republished++,
      );

      await clearer.clear('merged:anna');

      expect(republished, 1);
    });

    test('a failing republish does not stop the shade being cleared', () async {
      final dismissed = <String>[];
      final clearer = ConversationClearer(
        dismissChat: (id) async => dismissed.add(id),
        republish: () async => throw StateError('no container'),
      );

      await clearer.clear('merged:anna');

      expect(dismissed, ['merged:anna']);
    });

    test('nothing wired up is a silent no-op, not a crash', () async {
      // The state a cold start and every widget test is in.
      const clearer = ConversationClearer(dismissChat: null, republish: null);
      await expectLater(clearer.clear('merged:anna'), completes);
    });
  });

  group('read on another device', () {
    Chat chat(String id, {int unread = 0}) => Chat(
      id: id,
      title: id,
      unreadCount: unread,
      sources: [ChatSource(roomId: id, network: ChatNetwork.matrix)],
    );

    late List<String> cleared;
    late ReadElsewhereWatcher watcher;

    setUp(() {
      cleared = [];
      watcher = ReadElsewhereWatcher(
        ConversationClearer(
          dismissChat: (id) async => cleared.add(id),
          republish: () async {},
        ),
      );
    });

    test('a chat that stops being unread is cleared', () async {
      // Nothing on this device did anything: the laptop's `m.read` synced, the
      // count dropped, and the row is still in the shade. The clearing push
      // covers a phone that is asleep; this covers one that is awake.
      await watcher.onChats([chat('!a', unread: 2)]);
      expect(cleared, isEmpty, reason: 'still unread');

      await watcher.onChats([chat('!a')]);
      expect(cleared, ['!a']);
    });

    test('a chat that was already read is not cleared again', () async {
      // The transition is what matters, not the state. A *new* notification
      // can legitimately be posted between two ticks, and clearing on every
      // tick would wipe it.
      await watcher.onChats([chat('!a')]);
      await watcher.onChats([chat('!a')]);
      expect(cleared, isEmpty);
    });

    test('a chat that becomes unread again can be cleared again', () async {
      await watcher.onChats([chat('!a', unread: 1)]);
      await watcher.onChats([chat('!a')]);
      await watcher.onChats([chat('!a', unread: 1)]);
      await watcher.onChats([chat('!a')]);
      expect(cleared, ['!a', '!a']);
    });

    test('a chat that leaves the list entirely is not cleared', () async {
      // Archived, deleted, or the account signed out — and `_stopInboxSurfaces`
      // owns all three. Clearing here would be a second answer to a question
      // that has already been answered somewhere with more context.
      await watcher.onChats([chat('!a', unread: 1)]);
      await watcher.onChats([]);
      expect(cleared, isEmpty);
    });

    test('only the chats that changed are cleared', () async {
      await watcher.onChats([chat('!a', unread: 1), chat('!b', unread: 3)]);
      await watcher.onChats([chat('!a'), chat('!b', unread: 3)]);
      expect(cleared, ['!a']);
    });
  });
}
