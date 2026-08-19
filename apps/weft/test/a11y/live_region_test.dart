import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/search/search_screen.dart';

import '../support/a11y_harness.dart';
import '../support/seeded_repository.dart';
import '../support/semantics_probe.dart';

/// How a screen reader learns that something happened while it was elsewhere.
///
/// The audit's CROSS-2 finding was that the app had **no** live regions and
/// **no** announcements: every event Weft reported, it reported by redrawing
/// something. That is a complete report for someone watching the screen and
/// none at all for someone listening to it, and the two events it fails hardest
/// on are the two here — a message arriving in a conversation that is already
/// open, and a result count that changes under a query as it is typed.
///
/// The two use different mechanisms, and which one is right depends on whether
/// there is anything on screen to point at:
///
///  * The **count** is a visible line whose words change, so it is a `Semantics`
///    node with `liveRegion: true`. The reader re-announces it on change and the
///    user can navigate back to it afterwards.
///  * The **arrival** has no node — the new bubble is below the fold, or the
///    reader is in the composer — so it goes out on the platform's announcement
///    channel instead, which is the only place it is observable at all.
///
/// What this file adds over the per-screen suites, which assert that each says
/// the right words, is the part a screen's own test cannot see: **how often**.
/// A live region that re-announces on every rebuild is worse than none, because
/// it talks over whatever the user is reading, and there is no way to tell that
/// from a single-frame assertion.
void main() {
  late DemoChatRepository demo;
  late WeftStores stores;

  setUp(() {
    demo = DemoChatRepository(uploadTick: Duration.zero);
    stores = WeftStores.inMemory();
  });
  tearDown(() {
    demo.dispose();
    stores.dispose();
  });

  group('a message arriving', () {
    /// Opens a chat holding [history] that [GrowingChatRepository.arrive] can
    /// then add to.
    Future<GrowingChatRepository> pumpGrowingChat(
      WidgetTester tester,
      List<WeftMessage> history,
    ) async {
      final repository = GrowingChatRepository(demo, messages: history);
      await pumpScreen(
        tester,
        ChatView(chatId: repository.chatId),
        repository: repository,
        stores: stores,
      );
      return repository;
    }

    /// Reacts to the bubble carrying [text], which is the cheapest way to make
    /// the open view re-read its timeline and so notice what has arrived.
    Future<void> nudgeTimeline(WidgetTester tester, String text) async {
      await tester.longPress(
        find.text(text, findRichText: true).first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('React with 👍'));
      await tester.pumpAndSettle();
    }

    testWidgets('is announced, with who sent it and what it said', (
      tester,
    ) async {
      final announced = watchAnnouncements(tester);
      final repository = await pumpGrowingChat(tester, [
        seededMessage(eventId: r'$one', body: 'Where are we?'),
      ]);

      repository.arrive(
        seededMessage(
          eventId: r'$two',
          body: 'actually, make it seven',
          minutesAgo: -5,
        ),
      );
      await nudgeTimeline(tester, 'Where are we?');

      expect(announced, [
        'New message from Anna Maven, actually, make it seven',
      ]);
    });

    testWidgets('is announced once, not once per frame', (tester) async {
      final announced = watchAnnouncements(tester);
      final repository = await pumpGrowingChat(tester, [
        seededMessage(eventId: r'$one', body: 'Where are we?'),
      ]);

      repository.arrive(
        seededMessage(eventId: r'$two', body: 'seven works', minutesAgo: -5),
      );
      await nudgeTimeline(tester, 'Where are we?');
      expect(announced, hasLength(1));

      // Ten more frames of the same message sitting at the bottom of the same
      // list. This is the failure mode a live region on the list itself would
      // have — the node's label changes when anything in it changes, and a
      // timeline redraws on a reaction, a delivery receipt or a scroll.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(announced, hasLength(1));
    });

    testWidgets('the history the chat opened on is not news', (tester) async {
      final announced = watchAnnouncements(tester);
      await pumpGrowingChat(tester, [
        seededMessage(eventId: r'$one', body: 'Where are we?'),
        seededMessage(eventId: r'$two', body: 'the usual place', minutesAgo: 1),
      ]);

      // The opening load is the whole visible history. Announcing it would
      // read the conversation out on arrival, and would do it again on every
      // page of backfill.
      expect(announced, isEmpty);
    });

    testWidgets("the reader's own message is not announced to them", (
      tester,
    ) async {
      final announced = watchAnnouncements(tester);
      final repository = await pumpGrowingChat(tester, [
        seededMessage(eventId: r'$one', body: 'Where are we?'),
      ]);

      repository.arrive(
        seededMessage(
          eventId: r'$mine',
          body: 'on my way',
          isOwn: true,
          minutesAgo: -5,
        ),
      );
      await nudgeTimeline(tester, 'Where are we?');

      expect(announced, isEmpty);
    });
  });

  group('a search result count', () {
    WeftMessage indexed(String eventId, String body) => WeftMessage(
      eventId: eventId,
      roomId: '!room:example.org',
      network: ChatNetwork.telegram,
      senderId: '@grace:example.org',
      senderName: 'Grace',
      timestamp: DateTime(2026, 8, 18, 14, 32),
      kind: MessageKind.text,
      isOwn: false,
      body: body,
    );

    Future<void> pumpSearch(WidgetTester tester, {String? query}) async {
      for (final message in [
        indexed(r'$one', 'the roof is on fire'),
        indexed(r'$two', 'the roof leaks again'),
        // Deliberately shares no stem with the query: "roofs" would match the
        // prefix search and make the count three.
        indexed(r'$three', 'the kitchen tap drips'),
      ]) {
        stores.search.indexMessage(
          message,
          chatId: 'merged:anna',
          chatTitle: 'The Thursday plan',
        );
      }
      await pumpScreen(
        tester,
        SearchScreen(initialQuery: query),
        repository: demo,
        stores: stores,
      );
    }

    testWidgets('is a live region rather than a number to go and find', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSearch(tester, query: 'roof');

      // The reader is in the field they just typed into; the count is a line
      // further down the page they have no reason to visit.
      expect(liveRegionsIn(tester), contains('2 results'));
      handle.dispose();
    });

    testWidgets('follows the query as it is typed', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSearch(tester);

      /// Types [query] and waits past the field's 250ms debounce.
      ///
      /// `pumpAndSettle` alone is not enough: it stops as soon as no frame is
      /// scheduled, which is one 100ms step after the keystroke — so the timer
      /// that actually runs the search never fires and the assertion below
      /// would be about a screen that had not searched yet.
      Future<void> type(String query) async {
        await tester.enterText(find.byType(TextField), query);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      }

      await type('roof');
      expect(liveRegionsIn(tester), contains('2 results'));

      // The point of a live region rather than a label: the *change* is the
      // announcement. A count that only spoke when the reader navigated onto it
      // would say nothing at the moment it became true.
      await type('roof is');
      expect(liveRegionsIn(tester), contains('1 result'));
      handle.dispose();
    });

    testWidgets('says an empty search is empty, once', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSearch(tester, query: 'submarine');

      expect(liveRegionsIn(tester), contains('Nothing matched.'));
      // In one place rather than two: a summary line *and* a centred "Nothing
      // matched" is one sentence for a sighted user and two announcements for
      // a reader.
      expect(liveRegionsIn(tester).where((l) => l.contains('Nothing')), [
        'Nothing matched.',
      ]);
      handle.dispose();
    });

    testWidgets('the count is the only live region on the screen', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSearch(tester, query: 'roof');

      // Every result row *changing* is not news — the count changing is. A
      // screen with a live region per row announces the whole result list on
      // every keystroke, which is the version of this feature that gets turned
      // off.
      expect(liveRegionsIn(tester), hasLength(1));
      handle.dispose();
    });
  });
}
