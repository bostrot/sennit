import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/notification_providers.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_preview.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/services/notifications/notification_actions.dart';

import 'support/golden_harness.dart';
import 'support/recording_repository.dart';
import 'package:weft/app/localisation.dart';

/// Looking at a conversation without having read it.
///
/// The whole feature is a promise about what it does *not* do, and that
/// promise is invisible: the messages look the same either way, so nothing on
/// screen tells the user whether their unread marker survived. These tests are
/// where that promise is actually kept.
class _RecordingDismisser extends NotificationDismisserNotifier {
  _RecordingDismisser(this.cleared);

  final List<String> cleared;

  @override
  NotificationDismisser? build() =>
      (String chatId) async => cleared.add(chatId);
}

void main() {
  setUpAll(loadGoldenFonts);

  const chatId = 'merged:anna';

  late DemoChatRepository demo;
  late RecordingChatRepository repository;
  late List<String> cleared;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
    repository = RecordingChatRepository(demo);
    cleared = [];
  });
  tearDown(() => demo.dispose());

  Future<void> pump(WidgetTester tester, {required bool preview}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository),
          notificationDismisserProvider.overrideWith(
            () => _RecordingDismisser(cleared),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(surface: WeftSurface.mac),
          home: ChatView(chatId: chatId, preview: preview),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> readCalls() => repository.calls
      .where((c) => c.method == 'markRead')
      .map((c) => c.key ?? '')
      .toList();

  group('a preview leaves the conversation alone', () {
    testWidgets('it is not marked read', (tester) async {
      await pump(tester, preview: true);
      expect(
        readCalls(),
        isEmpty,
        reason: 'the unread marker is the whole reason to use a preview',
      );
    });

    testWidgets('its notification is not taken down', (tester) async {
      await pump(tester, preview: true);
      expect(cleared, isEmpty);
    });

    testWidgets('opening it properly still does both', (tester) async {
      await pump(tester, preview: false);
      expect(readCalls(), contains(chatId));
      expect(cleared, contains(chatId));
    });
  });

  group('a preview cannot be typed into', () {
    testWidgets('there is no composer', (tester) async {
      await pump(tester, preview: true);
      expect(
        find.byType(TextField),
        findsNothing,
        reason: 'a preview is a look, not a place to answer from',
      );
    });

    testWidgets('the real thing has one', (tester) async {
      await pump(tester, preview: false);
      expect(find.byType(TextField), findsWidgets);
    });

    testWidgets('the header offers nothing to press', (tester) async {
      await pump(tester, preview: true);
      expect(
        find.byTooltip('Manage merge'),
        findsNothing,
        reason: 'a peek that can start a call is not a peek',
      );
      expect(find.byTooltip('Contact details'), findsNothing);
    });

    testWidgets('the real thing keeps its actions', (tester) async {
      await pump(tester, preview: false);
      expect(find.byTooltip('Manage merge'), findsOneWidget);
    });

    testWidgets('the messages are still there to read', (tester) async {
      await pump(tester, preview: true);
      // Whatever the fixture says — the claim is that a preview still shows
      // the conversation, not which sentence is in it.
      expect(find.byType(ListView), findsWidgets);
      expect(find.textContaining('WhatsApp'), findsWidgets);
    });
  });

  group('the overlay', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(repository),
            notificationDismisserProvider.overrideWith(
              () => _RecordingDismisser(cleared),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(surface: WeftSurface.mac),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showChatPreview(context, chatId),
                    child: const Text('peek'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('peek'));
      await tester.pumpAndSettle();
    }

    testWidgets('says that nothing was spent by looking', (tester) async {
      await open(tester);
      expect(
        find.text('Preview — still unread'),
        findsOneWidget,
        reason: 'the promise is invisible unless it is stated',
      );
    });

    testWidgets('closes on Escape without reading the chat', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Preview — still unread'), findsNothing);
      expect(readCalls(), isEmpty);
    });

    testWidgets('offers a way through to the conversation', (tester) async {
      await open(tester);
      expect(
        find.widgetWithText(TextButton, 'Open'),
        findsOneWidget,
        reason: 'a preview that cannot become the real thing is a dead end',
      );
    });
  });
}
