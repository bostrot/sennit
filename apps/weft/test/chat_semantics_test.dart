import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/chat/unverified_devices_banner.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart' show RoomTrust;

import 'support/semantics_probe.dart';
import 'support/seeded_repository.dart';

/// What the conversation says to a screen reader.
///
/// The audit found the timeline to be the worst surface in the app for this:
/// message bubbles carried **no** `Semantics` at all, so the sender, the leg,
/// the time, the delivery state and the reaction summary were each their own
/// node in visual rather than reading order — and the two facts a reader most
/// needs, *who said this* and *on what*, were carried entirely by which side of
/// the screen the bubble sat on and the colour of a hairline down its edge.
///
/// The rule these tests hold the code to is not "wrap everything in one node".
/// A bubble body holds links and mention pills that must stay individually
/// reachable as controls, so the merge is deliberately partial: a group label
/// over a body that keeps its own nodes.
void main() {
  late DemoChatRepository demo;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  /// Pumps a chat seeded with [history] and returns the repository behind it.
  Future<SeededChatRepository> pumpChat(
    WidgetTester tester,
    List<WeftMessage> history,
  ) async {
    final repository = SeededChatRepository(demo, messages: history);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: ChatView(chatId: repository.chatId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repository;
  }

  /// Long-presses the bubble carrying [text] and picks the first quick
  /// reaction, which is the cheapest way to make the view re-read its timeline.
  Future<void> react(WidgetTester tester, String text) async {
    await tester.longPress(
      find.text(text, findRichText: true).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('React with 👍'));
    await tester.pumpAndSettle();
  }

  group('message bubbles', () {
    testWidgets('name the sender and the leg the words came from', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(
          eventId: r'$one',
          body: 'Where are we meeting?',
          roomId: '!tg:example.org',
        ),
        seededMessage(
          eventId: r'$two',
          body: 'the usual place',
          isOwn: true,
          network: ChatNetwork.signal,
          roomId: '!sig:example.org',
          minutesAgo: 2,
        ),
      ]);

      // A merged chat, so the leg is part of what the bubble means: which app
      // this was actually said on is information a sighted user gets from a
      // 3dp hairline and a reader got from nothing.
      final labels = labelsIn(tester);
      expect(labels, contains('Anna Maven, on Telegram'));
      expect(labels, contains('You, on Signal'));

      // Once each, not three times. The bubble also paints the network as a
      // glyph and a caption above the text, and both of those carried the same
      // word — so on a device a merged thread read "Anna Maven, on Telegram.
      // Telegram. Telegram." for every message in it. The caption is how a
      // sighted reader learns the leg; a reader who has just been told it does
      // not need it twice more.
      expect(labels, isNot(contains('Telegram')));
      expect(labels, isNot(contains('Signal')));
      handle.dispose();
    });

    testWidgets('say the time and the delivery state as one clause', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(
          eventId: r'$sent',
          body: 'on my way',
          isOwn: true,
          timestamp: DateTime(2026, 8, 18, 14, 32),
        ),
      ]);

      // Three nodes before this, one of which was an unlabelled 13dp tick
      // whose only difference between delivered and read is its colour.
      expect(labelsIn(tester), contains('Sent 14:32, Read'));
      handle.dispose();
    });

    testWidgets('offer the action sheet as a named long-press', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(eventId: r'$one', body: 'Where are we meeting?'),
      ]);

      // The sheet is the *only* way to reply, react, edit, copy, forward or
      // delete, and it was reachable solely by an unadvertised long-press with
      // nothing naming what it would do.
      final node = tester.getSemantics(find.bySemanticsLabel('Anna Maven'));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.longPress),
        isTrue,
      );
      // The hint is what turns "long press available" into "long press shows
      // actions" — the action existed already; nothing said what it led to.
      expect(node.hintOverrides?.onLongPressHint, 'show actions');
      handle.dispose();
    });

    testWidgets('summarise the reactions rather than making them be counted', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(
          eventId: r'$one',
          body: 'ship it',
          reactions: [
            ReactionTally(
              key: '👍',
              senderIds: ['@a:example.org', '@b:example.org'],
              firstReactedAt: DateTime(2026, 8, 18, 14, 33),
            ),
            ReactionTally(
              key: '🎉',
              senderIds: ['@c:example.org'],
              firstReactedAt: DateTime(2026, 8, 18, 14, 34),
            ),
          ],
        ),
      ]);

      final labels = labelsIn(tester);
      expect(labels, contains('3 reactions'));
      // And the chips stay reachable underneath it: they are controls, and a
      // summary that swallowed them would be a worse trade than the one it
      // fixes.
      expect(labels, contains('👍 2'));
      handle.dispose();
    });

    testWidgets('say when a message was edited, and where the versions are', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(
          eventId: r'$edited',
          body: 'quarter past, not half',
          isOwn: true,
          editedAt: DateTime(2026, 8, 18, 14, 35),
          editHistory: [
            EditRecord(
              eventId: r'$edited',
              body: 'half past',
              timestamp: DateTime(2026, 8, 18, 14, 30),
            ),
            EditRecord(
              eventId: r'$edit1',
              body: 'quarter past, not half',
              timestamp: DateTime(2026, 8, 18, 14, 35),
            ),
          ],
        ),
      ]);

      // An annotation now, not a control. It was the whole tap target for
      // opening the edit history and it is a 10dp italic run inside a metadata
      // line — TAP-15, the smallest target in the app — which cannot be grown
      // to 48dp without pushing the bubble apart. So it says where the versions
      // went instead of being the only way to them.
      expect(
        labelsIn(tester),
        contains('Edited at 14:35, versions in the message actions'),
      );
      handle.dispose();
    });

    testWidgets('offer the edit history where the other actions are', (
      tester,
    ) async {
      await pumpChat(tester, [
        seededMessage(
          eventId: r'$edited',
          body: 'quarter past, not half',
          isOwn: true,
          editedAt: DateTime(2026, 8, 18, 14, 35),
          editHistory: [
            EditRecord(
              eventId: r'$edited',
              body: 'half past',
              timestamp: DateTime(2026, 8, 18, 14, 30),
            ),
            EditRecord(
              eventId: r'$edit1',
              body: 'quarter past, not half',
              timestamp: DateTime(2026, 8, 18, 14, 35),
            ),
          ],
        ),
      ]);

      await tester.longPress(
        find.text('quarter past, not half', findRichText: true).first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit history'));
      await tester.pumpAndSettle();

      // The sheet the marker used to be the only door to. Reachable from a
      // keyboard for the first time, since the bubble's action sheet is Enter.
      expect(find.text('half past'), findsOneWidget);
    });

    testWidgets('day dividers are headings, not bare dates', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(
          eventId: r'$one',
          body: 'morning',
          timestamp: DateTime(2026, 8, 18, 9),
        ),
      ]);

      expect(labelsIn(tester), contains('Messages from Aug 18'));
      handle.dispose();
    });
  });

  group('the composer', () {
    testWidgets('keeps saying what it will do after the first keystroke', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(eventId: r'$one', body: 'Where are we meeting?'),
      ]);

      // The mode lived only in the hint, and a hint disappears the moment a
      // character is typed — so a reader who started replying and then typed
      // had nothing left telling them the next send is a reply.
      await tester.enterText(find.byType(TextField), 'the usual place');
      await tester.pumpAndSettle();

      expect(labelsIn(tester), contains('Message via Telegram'));
      handle.dispose();
    });

    testWidgets('announces reply mode as it appears', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(eventId: r'$one', body: 'Where are we meeting?'),
      ]);

      await tester.longPress(
        find.text('Where are we meeting?', findRichText: true).first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();

      // The bar is put there by a long-press three bubbles up the thread, so
      // its *appearing* is the whole event — hence a live region rather than a
      // label a reader would have to go looking for.
      final bar = find.bySemanticsLabel('Replying to Anna Maven');
      expect(bar, findsOneWidget);
      expect(tester.getSemantics(bar).flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });

    testWidgets('the disabled in-chat search does not pretend to work', (
      tester,
    ) async {
      await pumpChat(tester, [
        seededMessage(eventId: r'$one', body: 'Where are we meeting?'),
      ]);

      // `onPressed: () {}` announced as an enabled button, took a tap and did
      // nothing — indistinguishable, to a reader, from a tap that failed.
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.search_rounded),
      );
      expect(button.onPressed, isNull);
      expect(
        find.byTooltip('Search in conversation — not available yet'),
        findsOneWidget,
      );
    });
  });

  group('rich content', () {
    testWidgets('a mention pill is a control, and @room says what it does', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        // `@room` is recognised from the plain text, not from an anchor —
        // it is the one mention that has no user behind it to link to.
        seededMessage(eventId: r'$roomwide', body: 'ping @room'),
        seededMessage(
          eventId: r'$mention',
          minutesAgo: 1,
          body: 'and Anna',
          formattedBody:
              '<p>and '
              '<a href="https://matrix.to/#/@anna:example.org">Anna</a></p>',
        ),
      ]);

      final labels = labelsIn(tester);
      // A `GestureDetector` inside a `WidgetSpan` is not a button to a reader:
      // both pills announced as bare runs of text with no hint they go
      // anywhere, and `@room` is the one that pinged everybody.
      expect(labels, contains('@room, mentions everyone'));
      expect(labels, contains('Mention: Anna'));
      handle.dispose();
    });

    testWidgets('a bullet is not read aloud, an ordered marker is', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(
          eventId: r'$lists',
          body: 'freeze\ntag\nannounce',
          formattedBody:
              '<ul><li>freeze</li></ul><ol start="3"><li>announce</li></ol>',
        ),
      ]);

      // The bullet is the list's *shape*, announced once per line as the
      // character "bullet". The ordered marker is information — "step 3" — and
      // stays. Both land inside the paragraph's merged node, so the assertion
      // is over the joined text rather than over separate labels.
      final spoken = labelsIn(tester).join('\n');
      expect(spoken, isNot(contains('•')));
      expect(spoken, contains('3.'));
      handle.dispose();
    });

    testWidgets('a code block says there is a code block', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChat(tester, [
        seededMessage(
          eventId: r'$code',
          body: 'weft doctor --all',
          formattedBody: '<pre><code>weft doctor --all</code></pre>',
        ),
      ]);

      // The region scrolls horizontally, and nothing but that scroll said so.
      expect(labelsIn(tester), contains('Code block'));
      handle.dispose();
    });
  });

  group('live regions', () {
    testWidgets('a message arriving while the chat is open is announced', (
      tester,
    ) async {
      final announced = watchAnnouncements(tester);
      final repository = GrowingChatRepository(
        demo,
        messages: [seededMessage(eventId: r'$one', body: 'Where are we?')],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: ChatView(chatId: repository.chatId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The opening load is the whole visible history and is deliberately
      // silent. A live region on the list would re-announce it — and would do
      // the same again on every page of backfill.
      expect(announced, isEmpty);

      repository.arrive(
        seededMessage(
          eventId: r'$two',
          body: 'actually, make it seven',
          minutesAgo: -5,
        ),
      );
      // Any relation action re-reads the timeline, which is the frame the new
      // message reaches the list on.
      await react(tester, 'Where are we?');

      // Not "on Telegram": this fixture is a single-leg chat, and naming the
      // network on every bubble of a chat that only has one is noise. The leg
      // is announced when — and only when — the chat is merged.
      expect(announced, [
        'New message from Anna Maven, actually, make it seven',
      ]);
    });

    testWidgets('the reader own send is not news to them', (tester) async {
      final announced = watchAnnouncements(tester);
      final repository = GrowingChatRepository(
        demo,
        messages: [seededMessage(eventId: r'$one', body: 'Where are we?')],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: ChatView(chatId: repository.chatId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      repository.arrive(
        seededMessage(
          eventId: r'$mine',
          body: 'on my way',
          isOwn: true,
          minutesAgo: -5,
        ),
      );
      await react(tester, 'Where are we?');

      expect(announced, isEmpty);
    });

    testWidgets('the unverified-devices strip announces itself', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: WeftTheme.build(),
          home: Scaffold(
            body: UnverifiedDevicesBanner(
              trust: const RoomTrust(
                encrypted: true,
                unverifiedDevices: 1,
                unverifiedUsers: 1,
                includesOwnDevice: true,
              ),
              onVerify: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // It arrives in response to a trust change — someone signed in on a new
      // phone — and a reader already in the composer gets no other sign that
      // what they are about to send has grown an audience.
      final strip = tester.getSemantics(find.byType(UnverifiedDevicesBanner));
      expect(strip.flagsCollection.isLiveRegion, isTrue);
      expect(strip.label, contains('not verified'));
      // And the way out stays a reachable control underneath the warning,
      // named with its object rather than as a bare verb.
      expect(labelsIn(tester), contains('Verify your device'));
      handle.dispose();
    });
  });
}
