import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/notification_providers.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/services/notifications/notification_actions.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';

import 'support/recording_repository.dart';

/// Stands in for the dismisser `main` installs once the service exists.
class _RecordingDismisser extends NotificationDismisserNotifier {
  _RecordingDismisser(this.cleared);

  final List<String> cleared;

  @override
  NotificationDismisser? build() => (String chatId) async => cleared.add(chatId);
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

  Future<List<String>> pump(
    WidgetTester tester, {
    String chatId = mergedChat,
    List<String>? dismissed,
  }) async {
    final cleared = dismissed ?? <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository),
          notificationDismisserProvider.overrideWith(
            () => _RecordingDismisser(cleared),
          ),
        ],
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: ChatView(chatId: chatId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return cleared;
  }

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
          notificationDismisserProvider.overrideWith(
            () => _RecordingDismisser(cleared),
          ),
        ],
        child: MaterialApp(
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
}
