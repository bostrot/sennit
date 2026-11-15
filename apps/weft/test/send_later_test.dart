import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';

import 'support/recording_repository.dart';
import 'package:weft/app/localisation.dart';

/// Send sends; scheduling is asked for by name.
///
/// Holding Send used to open the scheduler's date picker. Half a second is
/// not a deliberate act — a slow press landed in a calendar with the message
/// unsent — so the hold is gone and "Send later" is a row in the attach menu.
/// Both halves are pinned here: a press of any length sends, and the row
/// reaches the picker.
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

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: const ChatView(chatId: mergedChat),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder sendButton() => find.byIcon(Icons.send_rounded);

  testWidgets('holding Send sends, and opens no picker', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField).last, 'Held a moment');
    await tester.pumpAndSettle();

    await tester.longPress(sendButton());
    await tester.pumpAndSettle();

    expect(find.byType(DatePickerDialog), findsNothing);
    expect(
      repository.calls.where((c) => c.method == 'send').map((c) => c.body),
      contains('Held a moment'),
    );
  });

  testWidgets('"Send later" in the attach menu offers a time to send it at', (
    tester,
  ) async {
    await pump(tester);
    final l10n = tester.element(find.byType(ChatView)).l10n;

    await tester.enterText(find.byType(TextField).last, 'Later, not now');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(l10n.attachSheetTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.attachSourceSendLater));
    await tester.pumpAndSettle();

    // The date step of the picker, with the message still unsent.
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(repository.calls.where((c) => c.method == 'send'), isEmpty);
  });

  testWidgets('an empty composer offers the microphone, not Send', (
    tester,
  ) async {
    await pump(tester);

    // Nothing to send: the row is a record button.
    expect(sendButton(), findsNothing);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
  });

  testWidgets('a plain tap still sends immediately', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField).last, 'Right now');
    await tester.pumpAndSettle();

    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    expect(
      repository.calls.where((c) => c.method == 'send').map((c) => c.body),
      contains('Right now'),
    );
    expect(find.byType(DatePickerDialog), findsNothing);
  });
}
