import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/draft_providers.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft_design/weft_design.dart';

import 'support/golden_harness.dart';
import 'support/load_repository.dart';

/// What happens to text typed into a conversation and not sent.
///
/// It stays with the conversation: leaving and coming back finds it in the
/// composer, and the inbox row says there is something unsent there. Sending
/// it is what takes it away.
void main() {
  late WeftStores stores;

  setUp(() => stores = WeftStores.inMemory());
  tearDown(() => stores.dispose());

  const first = '!load_1:example.org';
  const second = '!load_2:example.org';

  Future<StateNotifierLike> open(WidgetTester tester) async {
    await pumpWeft(
      tester,
      const InboxShell(),
      repository: LoadChatRepository(chatCount: 8),
      stores: stores,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(InboxShell)),
    );
    final selected = container.read(selectedChatProvider.notifier);
    return (select: selected.select, container: container);
  }

  Finder composer() => find.descendant(
    of: find.byType(ChatView),
    matching: find.byType(TextField),
  );

  String rowDraft(WidgetTester tester, String chatId) => tester
      .widgetList<ChatTile>(find.byType(ChatTile))
      .firstWhere((t) => t.chat.id == chatId)
      .draft
      .toString();

  testWidgets('a draft survives switching away and back', (tester) async {
    final app = await open(tester);
    app.select(first);
    await tester.pumpAndSettle();
    await tester.enterText(composer().last, 'see you at');
    await tester.pump();

    app.select(second);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(composer().last).controller!.text,
      isEmpty,
      reason: 'the next conversation does not inherit the text',
    );
    expect(rowDraft(tester, first), 'see you at');
    expect(stores.settings.getString('draft.$first'), 'see you at');

    app.select(first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(composer().last).controller!.text,
      'see you at',
    );
  });

  testWidgets('a draft is saved while typing, before the chat is left', (
    tester,
  ) async {
    final app = await open(tester);
    app.select(first);
    await tester.pumpAndSettle();
    await tester.enterText(composer().last, 'half a thought');
    await tester.pump(const Duration(seconds: 2));
    expect(stores.settings.getString('draft.$first'), 'half a thought');
  });

  testWidgets('clearing the composer removes the draft', (tester) async {
    stores.settings.setString('draft.$first', 'old words');
    final app = await open(tester);
    expect(
      app.container.read(draftsProvider),
      containsPair(first, 'old words'),
    );
    app.select(first);
    await tester.pumpAndSettle();
    await tester.enterText(composer().last, '');
    app.select(second);
    await tester.pumpAndSettle();
    expect(stores.settings.getString('draft.$first'), isNull);
    expect(app.container.read(draftsProvider), isNot(contains(first)));
  });
}

typedef StateNotifierLike = ({
  void Function(String) select,
  ProviderContainer container,
});
