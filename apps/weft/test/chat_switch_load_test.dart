import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/golden_harness.dart';
import 'support/load_repository.dart';

/// What opening and switching conversations costs, counted rather than timed.
///
/// A stopwatch in a widget test measures the debug-mode JIT; these count the
/// work that scales with how a person moves through their inbox — pages pulled
/// from the homeserver, rows written to the search index, bubbles built — and
/// which conversation a fast click-through ends up showing. Each scenario
/// prints one `LOAD {…}` line, which is what the before/after numbers in the
/// change were read from.
void main() {
  setUp(clearMessageDocumentCache);

  /// Every bubble mounted, the cache extent's included.
  int builtBubbles(WidgetTester tester) => find
      .descendant(
        of: find.byType(ChatView),
        matching: find.byType(WeftSelectionLine, skipOffstage: false),
      )
      .evaluate()
      .length;

  void report(String scenario, Map<String, Object> numbers) =>
      // ignore: avoid_print
      print('LOAD $scenario $numbers');

  testWidgets('opening a conversation pulls one page and indexes what it '
      'shows', (tester) async {
    final repo = _repository();
    await pumpWeft(
      tester,
      const InboxShell(),
      repository: repo,
      size: const Size(412, 915),
    );

    await tester.tap(find.text('Load test group').first);
    await tester.pumpAndSettle();
    final first = (
      pages: repo.pages,
      loaded: repo.loadedIn(LoadChatRepository.groupChatId),
      indexed: repo.indexed,
      bubbles: builtBubbles(tester),
    );
    report('phone_first_open', {
      'pages': first.pages,
      'loaded': first.loaded,
      'indexed': first.indexed,
      'bubbles': first.bubbles,
    });

    // In and out of the same conversation, as someone checking it does.
    for (var i = 0; i < 5; i++) {
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load test group').first);
      await tester.pumpAndSettle();
    }
    report('phone_reopen_x5', {
      'pages': repo.pages - first.pages,
      'loaded': repo.loadedIn(LoadChatRepository.groupChatId),
      'indexed': repo.indexed - first.indexed,
      'bubbles': builtBubbles(tester),
    });

    // An open is a screenful plus a buffer, not the whole history.
    expect(first.pages, lessThanOrEqualTo(1));
    expect(first.bubbles, lessThan(40));
    // A conversation already open once is read from what is already loaded:
    // no page per visit, and nothing re-written to the index.
    expect(repo.pages - first.pages, 0);
    expect(repo.loadedIn(LoadChatRepository.groupChatId), first.loaded);
    expect(repo.indexed - first.indexed, 0);
  });

  testWidgets('a fast click-through on two panes lands on the last click', (
    tester,
  ) async {
    final repo = _repository(
      // The first conversation's rooms take a while to open — a cold room
      // read from disk — and the second's are already warm.
      openDelays: {'!load_1:example.org': const Duration(milliseconds: 400)},
    );
    await pumpWeft(tester, const InboxShell(), repository: repo);

    await tester.tap(find.text('Load test group').first);
    await tester.pumpAndSettle();
    final pagesBefore = repo.pages;

    // Two clicks 50ms apart, the slow room first — through the selection a
    // row's tap sets, so the timing is the test's and not the gesture
    // arena's.
    final selected = ProviderScope.containerOf(
      tester.element(find.byType(InboxShell)),
    ).read(selectedChatProvider.notifier);
    selected.select('!load_1:example.org');
    await tester.pump(const Duration(milliseconds: 50));
    selected.select('!load_2:example.org');
    // Frame by frame past the slow room's open, so a stale answer has had
    // its chance to land.
    for (var t = 0; t < 500; t += 50) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final shownMeanwhile = _shownRooms(tester);
    await tester.pumpAndSettle();

    final chat = tester.widget<ChatView>(find.byType(ChatView));
    final shown = _shownRooms(tester);
    report('split_click_through', {
      'selected': chat.chatId,
      'shownMeanwhile': shownMeanwhile,
      'shown': shown,
      'pages': repo.pages - pagesBefore,
      'indexedForWrongChat': repo.indexedUnderWrongChat,
    });

    expect(chat.chatId, '!load_2:example.org');
    expect(shownMeanwhile, {'!load_2:example.org'});
    expect(shown, {'!load_2:example.org'});
    expect(repo.indexedUnderWrongChat, 0);
  });

  testWidgets('switching conversations on two panes starts each at its newest '
      'message', (tester) async {
    final repo = _repository();
    await pumpWeft(tester, const InboxShell(), repository: repo);

    await tester.tap(find.text('Load test group').first);
    await tester.pumpAndSettle();
    final thread = find
        .descendant(
          of: find.byType(ChatView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(thread, const Offset(0, 600));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Contact 3 ').first);
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ChatView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    report('split_switch_scroll', {'offset': position.pixels});
    expect(position.pixels, 0);
  });

  testWidgets('history arrives a page at a time as the reader scrolls up', (
    tester,
  ) async {
    final repo = _repository();
    await pumpWeft(
      tester,
      const ChatView(chatId: LoadChatRepository.groupChatId),
      repository: repo,
      size: const Size(412, 915),
    );
    await tester.pumpAndSettle();
    final opened = repo.loadedIn(LoadChatRepository.groupChatId);

    final thread = find.byType(Scrollable).first;
    for (var i = 0; i < 6; i++) {
      await tester.drag(thread, const Offset(0, 800));
      await tester.pumpAndSettle();
    }
    final scrolled = repo.loadedIn(LoadChatRepository.groupChatId);
    report('phone_scroll_back', {
      'opened': opened,
      'scrolled': scrolled,
      'pages': repo.pages,
      'bubbles': builtBubbles(tester),
    });

    // More arrived as the reader went, and only some of it is built.
    expect(scrolled, greaterThan(opened));
    expect(scrolled, lessThan(3000));
    expect(builtBubbles(tester), lessThan(40));
  });

  testWidgets('a jump lands on a message far past the rows that are built', (
    tester,
  ) async {
    const target = r'$g_150';
    final repo = _repository();
    await pumpWeft(
      tester,
      const ChatView(
        chatId: LoadChatRepository.groupChatId,
        initialEventId: target,
      ),
      repository: repo,
      size: const Size(412, 915),
    );
    // Not settled: the highlight pulses, so the list is read while it does.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final bubble = find.byWidgetPredicate(
      (w) =>
          w.runtimeType.toString() == '_MessageBubble' &&
          ((w as dynamic).message as WeftMessage).eventId == target,
    );
    expect(bubble, findsOneWidget);
    final rect = tester.getRect(bubble);
    final screen = tester.getRect(find.byType(Scrollable).first);
    expect(screen.overlaps(rect), isTrue, reason: 'the target is on screen');
    await tester.pumpAndSettle();
  });
}

/// A mid-sized account whose timelines behave like Matrix ones.
LoadChatRepository _repository({Map<String, Duration> openDelays = const {}}) =>
    LoadChatRepository(
      chatCount: 60,
      groupMessages: 3000,
      groupMembers: 8,
      cachesTimelines: true,
      openDelays: openDelays,
    );

/// The rooms of the bubbles on screen.
///
/// Read off the bubbles themselves: the bodies repeat across these fixtures,
/// so the text says nothing about which conversation it came from.
Set<String> _shownRooms(WidgetTester tester) => {
  for (final element
      in find
          .descendant(
            of: find.byType(ChatView),
            matching: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_MessageBubble',
            ),
          )
          .evaluate())
    ((element.widget as dynamic).message as WeftMessage).roomId,
};
