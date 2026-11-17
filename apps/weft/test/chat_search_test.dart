import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_search.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';

import 'support/seeded_repository.dart';

/// Search within one conversation.
///
/// The bar's search button was a placeholder: disabled, with the reason in a
/// tooltip, which on a phone is a reason nobody can read. These hold the
/// working search to the things a reader relies on — that the button does
/// something, that "nothing typed" and "nothing found" look different, that
/// the arrows walk the matches and bring each into view, and that Back and
/// Escape leave the search without leaving the conversation.
void main() {
  late DemoChatRepository demo;
  late WeftStores stores;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
    stores = WeftStores.inMemory();
  });
  tearDown(() {
    demo.dispose();
    stores.dispose();
  });

  /// Sixty messages, message 0 the newest, with "pancake" said twice: once a
  /// few minutes ago and once far enough back to be off screen.
  List<WeftMessage> history() => [
    for (var i = 0; i < 60; i++)
      seededMessage(
        eventId: '\$m$i',
        body: switch (i) {
          3 => 'pancake breakfast on sunday?',
          50 => 'the pancake place by the river',
          _ => 'message $i',
        },
        isOwn: i.isOdd,
        senderName: 'Grace Hopper',
        minutesAgo: i,
      ),
  ];

  Future<SeededChatRepository> pumpChat(
    WidgetTester tester, {
    WeftSurface surface = WeftSurface.touch,
    bool isGroup = false,
    bool pushed = false,
    bool indexed = true,
  }) async {
    tester.view.physicalSize = surface == WeftSurface.mac
        ? const Size(900, 700)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = SeededChatRepository(
      demo,
      messages: history(),
      isGroup: isGroup,
    );
    // The whole history is in the index, as it is once the conversation has
    // been read through on this device; the timeline opens with only the
    // newest page of it. A match further back is therefore one the index
    // knows about and the screen has to page back to.
    if (indexed) {
      stores.search.indexMessages(
        repository.messages,
        chatId: repository.chatId,
        chatTitle: repository.title,
      );
    }
    final chat = ChatView(chatId: repository.chatId);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository),
          storesProvider.overrideWithValue(stores),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(surface: surface),
          home: pushed
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute<void>(builder: (_) => chat)),
                      child: const Text('open'),
                    ),
                  ),
                )
              : chat,
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (pushed) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }
    return repository;
  }

  Finder searchButton() => find.byTooltip('Search in chat');
  Finder field() => find.descendant(
    of: find.byType(ChatSearchBar),
    matching: find.byType(TextField),
  );

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(field(), query);
    // Past the debounce, then whatever the jump animates.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, String tooltip) {
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );
    return button.onPressed != null;
  }

  testWidgets('the search button is enabled and opens a search field', (
    tester,
  ) async {
    await pumpChat(tester);
    expect(enabled(tester, 'Search in chat'), isTrue);

    await tester.tap(searchButton());
    await tester.pumpAndSettle();

    expect(find.text('Search messages'), findsOneWidget);
    // Nothing typed is not "nothing found": no count, and nothing to step.
    expect(find.text('No matches'), findsNothing);
    expect(enabled(tester, 'Previous match'), isFalse);
    expect(enabled(tester, 'Next match'), isFalse);
  });

  testWidgets('a match is counted and brought into view, newest first', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.tap(searchButton());
    await tester.pumpAndSettle();

    await search(tester, 'pancake');
    expect(find.text('1 of 2'), findsOneWidget);
    expect(
      find.text('pancake breakfast on sunday?').hitTestable(),
      findsOneWidget,
    );
    expect(enabled(tester, 'Next match'), isFalse);

    // Up is further back, and far enough back that the list has to move.
    expect(
      find.text('the pancake place by the river').hitTestable(),
      findsNothing,
    );
    await tester.tap(find.byTooltip('Previous match'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
    expect(
      find.text('the pancake place by the river').hitTestable(),
      findsOneWidget,
    );
    expect(enabled(tester, 'Previous match'), isFalse);

    await tester.tap(find.byTooltip('Next match'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);
  });

  testWidgets('Enter in the field steps to the next older match', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.tap(searchButton());
    await tester.pumpAndSettle();
    await search(tester, 'pancake');

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
  });

  testWidgets('a search that finds nothing says so', (tester) async {
    await pumpChat(tester);
    await tester.tap(searchButton());
    await tester.pumpAndSettle();

    await search(tester, 'waffles');
    expect(find.text('No matches'), findsOneWidget);
    expect(enabled(tester, 'Previous match'), isFalse);

    // Clearing the field goes back to the empty state, not "no matches".
    await search(tester, '');
    expect(find.text('No matches'), findsNothing);
  });

  testWidgets('names are searched in a group, and not in a one-to-one chat', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.tap(searchButton());
    await tester.pumpAndSettle();
    await search(tester, 'hopper');
    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('a group searches the sender as well as the words', (
    tester,
  ) async {
    await pumpChat(tester, isGroup: true);
    await tester.tap(searchButton());
    await tester.pumpAndSettle();
    expect(find.text('Search messages and names'), findsOneWidget);

    await search(tester, 'hopper');
    // Every message not sent by the local user: the even half of sixty.
    expect(find.text('1 of 30'), findsOneWidget);
  });

  testWidgets('Escape closes the search and keeps the conversation', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.tap(searchButton());
    await tester.pumpAndSettle();
    await search(tester, 'pancake');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Search messages'), findsNothing);
    expect(find.text('Test Chat'), findsOneWidget);
    expect(searchButton(), findsOneWidget);
  });

  testWidgets('Back closes the search before it closes the conversation', (
    tester,
  ) async {
    await pumpChat(tester, pushed: true);
    await tester.tap(searchButton());
    await tester.pumpAndSettle();
    await search(tester, 'pancake');

    // The system's Back — the gesture, the hardware key.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Search messages'), findsNothing);
    expect(find.text('Test Chat'), findsOneWidget);

    // And the next one leaves, as it always did.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('the bar arrow closes the search', (tester) async {
    await pumpChat(tester, pushed: true);
    await tester.tap(searchButton());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.text('Test Chat'), findsOneWidget);
  });

  testWidgets('the Mac toolbar opens the same search', (tester) async {
    await pumpChat(tester, surface: WeftSurface.mac);
    await tester.tap(searchButton());
    await tester.pumpAndSettle();
    expect(find.text('Search messages'), findsOneWidget);

    await search(tester, 'pancake');
    expect(find.text('1 of 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous match'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.text('Search messages'), findsNothing);
  });

  group('chatSearchMatches', () {
    SearchResult hit(
      String eventId,
      String body, {
      int minutesAgo = 0,
      String senderName = 'Grace',
    }) => SearchResult(
      eventId: eventId,
      roomId: '!room:example.org',
      chatId: 'chat',
      network: ChatNetwork.telegram,
      senderId: '@grace:example.org',
      timestamp: DateTime(2026, 8, 18).subtract(Duration(minutes: minutesAgo)),
      kind: MessageKind.text,
      body: body,
      score: 1,
      senderName: senderName,
      chatTitle: 'Grace',
    );

    test('merges the index and the loaded messages, newest first', () {
      final matches = chatSearchMatches(
        query: 'pancake',
        indexed: [hit(r'$old', 'pancake day', minutesAgo: 600)],
        loaded: [
          seededMessage(eventId: r'$new', body: 'more pancake'),
          seededMessage(eventId: r'$other', body: 'nothing here'),
        ],
      );
      expect(matches, [r'$new', r'$old']);
    });

    // The index files every row under its conversation's title, so a row
    // can match through the title alone.
    test('drops an index row that matched only through the title', () {
      expect(
        chatSearchMatches(query: 'grace', indexed: [hit(r'$1', 'hello')]),
        isEmpty,
      );
    });

    test('a message deleted since it was indexed is not a match', () {
      final redacted = WeftMessage(
        eventId: r'$1',
        roomId: '!room:example.org',
        network: ChatNetwork.telegram,
        senderId: '@grace:example.org',
        senderName: 'Grace',
        timestamp: DateTime(2026, 8, 18),
        kind: MessageKind.text,
        isOwn: false,
        body: '',
        redacted: true,
      );
      expect(
        chatSearchMatches(
          query: 'pancake',
          indexed: [hit(r'$1', 'pancake')],
          loaded: [redacted],
        ),
        isEmpty,
      );
    });

    test('every word has to appear, in any order and case', () {
      final loaded = [
        seededMessage(eventId: r'$1', body: 'Sunday pancake BREAKFAST'),
        seededMessage(eventId: r'$2', body: 'pancake on monday'),
      ];
      expect(chatSearchMatches(query: 'breakfast, pancake', loaded: loaded), [
        r'$1',
      ]);
    });

    test('blank and punctuation-only queries search nothing', () {
      final loaded = [seededMessage(eventId: r'$1', body: 'hi!')];
      expect(chatSearchMatches(query: '   ', loaded: loaded), isEmpty);
      expect(chatSearchMatches(query: '!?', loaded: loaded), isEmpty);
    });
  });
}
