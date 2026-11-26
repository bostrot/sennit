import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/settings/appearance_sheet.dart';

import '../support/golden_harness.dart';
import '../support/seeded_repository.dart';

/// A phone at 100 %, 150 % and 200 % text: the inbox, a conversation with its
/// composer, and the appearance sheet with the text size preview.
///
/// The text size setting multiplies the system's, so between them the phone
/// and the slider reach these sizes and beyond; what has to hold is that rows
/// grow and wrap instead of clipping. An overflow anywhere fails the test
/// before the image is compared.
void main() {
  setUpAll(loadGoldenFonts);

  const phone = Size(412, 915);
  const variants = [
    WeftGoldenVariant(name: 'text_100'),
    WeftGoldenVariant(name: 'text_150', textScale: 1.5),
    WeftGoldenVariant(name: 'text_200', textScale: 2.0),
  ];

  late DemoChatRepository demo;
  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  WeftStores freshStores() {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    return stores;
  }

  SeededChatRepository thread() => SeededChatRepository(
    demo,
    messages: [
      seededMessage(
        eventId: r'$ask',
        body: 'Are you still coming for lunch on Sunday? Bring the photos!',
        minutesAgo: 24,
      ),
      seededMessage(
        eventId: r'$yes',
        body: 'Of course, I will be there at one.',
        isOwn: true,
        minutesAgo: 20,
      ),
      seededMessage(eventId: r'$ok', body: 'Wonderful', minutesAgo: 6),
    ],
  );

  for (final variant in variants) {
    group(variant.name, () {
      testWidgets('inbox', (tester) async {
        await pumpWeft(
          tester,
          const InboxShell(),
          size: phone,
          mode: WeftThemeMode.light,
          variant: variant,
          repository: demo,
          stores: freshStores(),
        );
        await expectLater(
          find.byType(InboxShell),
          matchesGoldenFile('text_size_inbox_${variant.name}.png'),
        );
      });

      testWidgets('chat', (tester) async {
        final repository = thread();
        await pumpWeft(
          tester,
          ChatView(chatId: repository.chatId),
          size: phone,
          mode: WeftThemeMode.light,
          variant: variant,
          repository: repository,
        );
        await expectLater(
          find.byType(ChatView),
          matchesGoldenFile('text_size_chat_${variant.name}.png'),
        );
      });

      testWidgets('appearance', (tester) async {
        await pumpWeft(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showAppearanceSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          size: phone,
          mode: WeftThemeMode.light,
          variant: variant,
          stores: freshStores(),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(TextSizePreview));
        await tester.pumpAndSettle();
        // The preview alone: the rest of the sheet gains a setting every so
        // often, and is laid out — and checked for overflow — either way.
        await expectLater(
          find.byType(TextSizePreview),
          matchesGoldenFile('text_size_appearance_${variant.name}.png'),
        );
      });
    });
  }
}
