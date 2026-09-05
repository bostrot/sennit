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

/// Holding Send opens the scheduler.
///
/// The affordance is invisible — nothing on screen says "hold me" except the
/// tooltip — so nothing but a test notices when it stops working. It did stop:
/// the button carries a tooltip, Flutter's `Tooltip` claims long presses by
/// default, and being the deeper widget it won the gesture arena against the
/// composer's own long-press handler. The hold showed the tooltip and
/// scheduled nothing.
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

  testWidgets('holding Send offers a time to send it at', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField).last, 'Later, not now');
    await tester.pumpAndSettle();

    await tester.longPress(sendButton());
    await tester.pumpAndSettle();

    // The date step of the picker, not a tooltip.
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(find.byType(Tooltip).hitTestable(), findsWidgets);
  });

  testWidgets('an empty composer offers the microphone, not Send', (
    tester,
  ) async {
    await pump(tester);

    // Nothing to schedule and nothing to send: the row is a record button,
    // which is also why `_sendLater`'s empty-text guard never fires in
    // practice.
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
