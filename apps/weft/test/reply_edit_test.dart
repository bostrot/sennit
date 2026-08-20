import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/reply_chip.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/recording_repository.dart';
import 'support/seeded_repository.dart';

/// Replying and editing, from the long-press to the event that goes out.
///
/// Both go through the composer's context bar, and the reason they are tested
/// together is that they share it: a bar that said "Replying" while the send
/// path was a replacement would rewrite a message the user last touched ten
/// minutes ago, and nothing on screen would have said so.
void main() {
  const mergedChat = 'merged:anna';
  const telegramRoom = '!anna_tg_room:example.org';
  const peerLine = 'Quick update from my side.';
  const ownLine = 'Sounds good 👍';

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
          theme: WeftTheme.build(),
          home: const ChatView(chatId: mergedChat),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> longPressBubble(WidgetTester tester, String text) async {
    await tester.longPress(
      find.text(text, findRichText: true).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
  }

  Future<void> chooseAction(WidgetTester tester, String label) async {
    final target = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(label),
    );
    // The sheet is a list and the destructive action is at the bottom of it,
    // so on a short screen the tile is in the tree without being on the screen.
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> typeAndSend(
    WidgetTester tester,
    String text, {
    String tooltip = 'Send — hold to schedule',
  }) async {
    await tester.enterText(find.byType(TextField), text);
    // The trailing button is the microphone until the first character lands;
    // one frame turns it into Send.
    await tester.pump();
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
  }

  /// Dismisses an open sheet by tapping the barrier above it.
  Future<void> dismissSheet(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  /// Every message across every leg, relations folded in.
  Future<List<WeftMessage>> loaded() async {
    final timeline = await demo.timelineFor(mergedChat);
    for (var round = 0; round < 6; round++) {
      await timeline.loadMore(count: 30);
    }
    return [for (final source in timeline.sources) ...source.loaded];
  }

  group('reply', () {
    testWidgets('the composer says who is being answered, and can be left', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byType(ReplyChip), findsNothing);

      await longPressBubble(tester, peerLine);
      await chooseAction(tester, 'Reply');

      expect(find.byType(ReplyChip), findsOneWidget);
      expect(find.text('Anna Maven'), findsWidgets);
      expect(find.byTooltip('Cancel reply'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pumpAndSettle();
      expect(find.byType(ReplyChip), findsNothing);
    });

    testWidgets('sending goes out as a reply to the message long-pressed', (
      tester,
    ) async {
      await pump(tester);
      await longPressBubble(tester, peerLine);
      await chooseAction(tester, 'Reply');
      await typeAndSend(tester, 'yes, 14:00');

      final call = repository.lastCallTo('sendReply');
      expect(call, isNotNull);
      expect(call!.body, 'yes, 14:00');

      // The target is the bubble that was long-pressed — on the Telegram leg,
      // which is not the chat's send network.
      final messages = await loaded();
      final target = messages.firstWhere((m) => m.eventId == call.eventId);
      expect(target.roomId, telegramRoom);
      expect(target.body, peerLine);

      // And the context bar is gone: a bar still naming a target over an empty
      // field is a state the user cannot type their way out of.
      expect(find.byTooltip('Cancel reply'), findsNothing);
    });

    testWidgets('a reply renders a chip above the bubble that answers', (
      tester,
    ) async {
      await pump(tester);
      await longPressBubble(tester, peerLine);
      await chooseAction(tester, 'Reply');
      await typeAndSend(tester, 'on my way');

      // The chip quotes the target, so both the answer and the question are on
      // screen — the reason a chip exists rather than a bare indent.
      expect(find.byType(ReplyChip), findsOneWidget);
      final chip = tester.widget<ReplyChip>(find.byType(ReplyChip));
      expect(chip.preview.body, peerLine);
      expect(chip.preview.roomId, telegramRoom);
      expect(chip.preview.isStub, isFalse);
    });

    testWidgets('tapping a chip scrolls to the message it quotes', (
      tester,
    ) async {
      await pump(tester);
      await longPressBubble(tester, peerLine);
      await chooseAction(tester, 'Reply');
      await typeAndSend(tester, 'coming');

      await tester.tap(find.byType(ReplyChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The tap goes through `_jumpTo`, the same path a search result takes:
      // it paginates until the target is loaded, scrolls to the widget rather
      // than to an index, and pulses it. What is assertable here is that the
      // chip is wired to it and that the target is on screen afterwards.
      expect(find.text(peerLine, findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);

      // Drains the three-second highlight clear, which is a real timer and
      // fails the test at teardown if it is still pending.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('leaving reply mode keeps what the user typed', (tester) async {
      // The asymmetry with edit, and it is deliberate: these are words the user
      // wrote and may still want to send to the room, where an edit's prefill
      // is a copy of a message already in the thread.
      await pump(tester);
      await longPressBubble(tester, peerLine);
      await chooseAction(tester, 'Reply');
      await tester.enterText(find.byType(TextField), 'half a thought');

      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'half a thought',
      );
    });

    testWidgets('a reply to something not loaded renders a stub, not nothing', (
      tester,
    ) async {
      // An answer with no visible question is a worse lie than an answer above
      // a greyed-out "not loaded".
      await repository.sendReply(
        mergedChat,
        'about that',
        replyToEventId: r'$never_paginated_in',
      );
      await pump(tester);

      final chip = tester.widget<ReplyChip>(find.byType(ReplyChip));
      expect(chip.preview.isStub, isTrue);
      expect(find.text('Replying to a message'), findsOneWidget);
    });

    testWidgets('tapping a stub gives up quietly rather than spinning', (
      tester,
    ) async {
      // The tap is a request to go and fetch the target, and the target here
      // does not exist on any leg. `_jumpTo` is bounded for exactly this: an
      // unbounded search would page the whole conversation on one tap and end
      // in the same place.
      await repository.sendReply(
        mergedChat,
        'about that',
        replyToEventId: r'$never_paginated_in',
      );
      await pump(tester);

      await tester.tap(find.byType(ReplyChip));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ReplyChip), findsOneWidget);
    });
  });

  group('delete', () {
    testWidgets('a redaction is confirmed first, and can be refused', (
      tester,
    ) async {
      await pump(tester);
      await longPressBubble(tester, ownLine);
      await chooseAction(tester, 'Delete');

      // Irreversible: the redaction reaches every other client in the room, so
      // there is nothing to undo once it has gone.
      expect(find.text('Delete this message?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repository.lastCallTo('redact'), isNull);
    });

    testWidgets('a confirmed delete empties the bubble rather than the row', (
      tester,
    ) async {
      await pump(tester);
      await longPressBubble(tester, ownLine);
      await chooseAction(tester, 'Delete');
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(repository.lastCallTo('redact'), isNotNull);
      expect(find.text('Message deleted'), findsOneWidget);
    });

    testWidgets('a deleted message offers nothing but deleting it again', (
      tester,
    ) async {
      // There is nothing left to quote, react to, copy or rewrite — the words
      // are gone from the room, and an action sheet that still offered them
      // would be offering to send events about an event that no longer says
      // anything. Delete stays, because a local tidy-up has to stay reachable.
      await pump(tester);
      await longPressBubble(tester, ownLine);
      await chooseAction(tester, 'Delete');
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      await longPressBubble(tester, 'Message deleted');

      expect(find.text('Reply'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Copy text'), findsNothing);
      expect(find.text('Forward'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Delete'),
        ),
        findsOneWidget,
      );
    });
  });

  group('edit', () {
    testWidgets('editing is offered on the reader own message only', (
      tester,
    ) async {
      await pump(tester);

      await longPressBubble(tester, ownLine);
      expect(find.text('Edit'), findsOneWidget);
      await dismissSheet(tester);

      // A replacement of someone else's event is one every well-behaved client
      // ignores, so offering the action would be offering a control that does
      // nothing.
      await longPressBubble(tester, peerLine);
      expect(find.text('Edit'), findsNothing);
    });

    testWidgets('the composer opens with the message words in it', (
      tester,
    ) async {
      await pump(tester);
      await longPressBubble(tester, ownLine);
      await chooseAction(tester, 'Edit');

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        ownLine,
      );
      expect(find.byTooltip('Save edit'), findsOneWidget);
    });

    testWidgets('saving replaces the message rather than sending a new one', (
      tester,
    ) async {
      await pump(tester);
      await longPressBubble(tester, ownLine);
      await chooseAction(tester, 'Edit');
      await typeAndSend(tester, 'Sounds great', tooltip: 'Save edit');

      final call = repository.lastCallTo('editMessage');
      expect(call?.body, 'Sounds great');
      expect(repository.lastCallTo('send'), isNull);
      expect(repository.lastCallTo('sendReply'), isNull);

      final messages = await loaded();
      final edited = messages.firstWhere((m) => m.eventId == call!.eventId);
      expect(edited.body, 'Sounds great');
      expect(edited.isEdited, isTrue);
    });

    testWidgets('an edited message says so, and opens its history', (
      tester,
    ) async {
      await pump(tester);
      await longPressBubble(tester, ownLine);
      await chooseAction(tester, 'Edit');
      await typeAndSend(tester, 'Sounds great', tooltip: 'Save edit');

      expect(find.textContaining('edited'), findsOneWidget);

      // Through the action sheet, not through the marker. The marker used to
      // be the only door to the history and it is a 10dp italic run — TAP-15,
      // the smallest tap target in the app, and one a line of running text
      // cannot be grown out of. It says where the versions went; the sheet
      // holds them, beside every other operation on a message.
      await longPressBubble(tester, 'Sounds great');
      await chooseAction(tester, 'Edit history');

      expect(find.text('Edit history'), findsWidgets);
      expect(find.text('Original'), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
      // Both versions are in the sheet: the words that were replaced exist
      // nowhere else once the timeline has resolved the edit.
      expect(find.textContaining(ownLine), findsWidgets);
      expect(find.textContaining('Sounds great'), findsWidgets);
    });

    testWidgets('cancelling an edit clears the words it put in the composer', (
      tester,
    ) async {
      await pump(tester);
      await longPressBubble(tester, ownLine);
      await chooseAction(tester, 'Edit');

      await tester.tap(find.byTooltip('Cancel edit'));
      await tester.pumpAndSettle();

      // Leaving them behind would arm the composer with a duplicate of a
      // message already in the thread.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      expect(find.byTooltip('Save edit'), findsNothing);
    });

    testWidgets('saving an emptied edit sends nothing and stays in the bar', (
      tester,
    ) async {
      // An empty replacement is not a delete, and sending one would blank a
      // message through a path with no confirmation on it. The mode stays, so
      // the user can either type or cancel — both of which say what they meant.
      await pump(tester);
      await longPressBubble(tester, ownLine);
      await chooseAction(tester, 'Edit');
      await typeAndSend(tester, '   ', tooltip: 'Save edit');

      expect(repository.lastCallTo('editMessage'), isNull);
      expect(repository.lastCallTo('redact'), isNull);
      expect(find.byTooltip('Save edit'), findsOneWidget);
    });

    testWidgets('choosing edit while replying leaves one mode, not two', (
      tester,
    ) async {
      // Both modes share the bar and the send button, so the failure this
      // guards against is a bar reading "Replying" over a send path that
      // rewrites a message from ten minutes ago.
      await pump(tester);
      await longPressBubble(tester, peerLine);
      await chooseAction(tester, 'Reply');
      await longPressBubble(tester, ownLine);
      await chooseAction(tester, 'Edit');

      expect(find.byTooltip('Cancel reply'), findsNothing);
      expect(find.byTooltip('Cancel edit'), findsOneWidget);
      expect(find.byTooltip('Send'), findsNothing);
      // And the words in the field are the message's, not a half-typed reply:
      // whatever was in the composer belonged to the mode that just ended.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        ownLine,
      );
    });
  });

  /// What the fixtures cannot produce: bodies that carry a `> <@someone> …`
  /// fallback, which every bridge sends, and a message that knows it was edited
  /// without holding the versions.
  group('messages the fixtures cannot make', () {
    Future<void> pumpSeeded(
      WidgetTester tester,
      List<WeftMessage> messages,
    ) async {
      final seeded = SeededChatRepository(demo, messages: messages);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(seeded)],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: ChatView(chatId: seeded.chatId),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'an edited message with no versions says so and opens nothing',
      (tester) async {
        // Every message mapped outside an open timeline is in this state: the
        // event carries `m.relates_to` and the replacements are only reachable
        // through the timeline that was never opened. A marker that opened an
        // empty sheet would be worse than one that does not open.
        await pumpSeeded(tester, [
          seededMessage(
            eventId: r'$edited',
            body: 'Friday, 14:00',
            editedAt: DateTime(2026, 8, 18, 14, 2),
            minutesAgo: 3,
          ),
        ]);

        expect(find.text('edited 14:02'), findsOneWidget);

        await tester.tap(find.text('edited 14:02'));
        await tester.pumpAndSettle();

        expect(find.text('Edit history'), findsNothing);
      },
    );
  });

  /// An edit of a *reply*, which the demo fixtures cannot produce: their bodies
  /// carry no `> <@someone> …` fallback, and every bridge sends one.
  group('editing a message that quotes another', () {
    testWidgets('the composer opens with the words, not the quote', (
      tester,
    ) async {
      // The fallback is the plain-text copy of the quote, rendered as the chip
      // above the bubble. Putting it in the composer would have the user
      // re-sending somebody else's sentence with their own edit under it, and
      // the bridge would then quote the quote.
      final seeded = SeededChatRepository(
        demo,
        messages: [
          seededMessage(
            eventId: r'$asked',
            body: 'where are we meeting',
            minutesAgo: 5,
          ),
          seededMessage(
            eventId: r'$answered',
            body:
                '> <@anna:example.org> where are we meeting\n\n'
                'the usual place',
            replyToEventId: r'$asked',
            isOwn: true,
            minutesAgo: 4,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(seeded)],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: ChatView(chatId: seeded.chatId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await longPressBubble(tester, 'the usual place');
      await chooseAction(tester, 'Edit');

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'the usual place',
      );
    });
  });
}
