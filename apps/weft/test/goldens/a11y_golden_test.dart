import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/search/search_screen.dart';
import 'package:weft/features/settings/endpoints_screen.dart';

import '../support/golden_harness.dart';
import '../support/seeded_repository.dart';

/// Weft under the four conditions an accessibility pass is actually judged on.
///
/// The rest of `test/a11y/` asks questions a tree can answer — does this node
/// have a label, does Tab reach it, is this token pair 4.5:1. None of them can
/// see the failures this file exists for, because every one of them is a
/// *picture*: a row still anchored to the physical left in Arabic, a label
/// clipped by a container sized for 1.0× text, a hairline that disappears when
/// the palette is pushed apart. The semantics tree is identical in all four.
///
/// Five scenes × four variants × two themes. Each scene is the widget the app
/// builds rather than a fragment on a bare `Scaffold`, for the reason the
/// attachment goldens give: a chip takes its ink from the bubble it hangs off
/// and its width from the pane it sits in, so an image of one on its own would
/// pass unchanged through the regression it exists to catch.
///
/// **On the right-to-left images.** The SDK's Roboto has no Hebrew and no
/// Arabic coverage — checked rather than assumed: zero of the 112 Hebrew
/// codepoints and zero of the 256 Arabic ones are in its `cmap`. So every
/// right-to-left *word* here draws as a placeholder box, the way emoji do in
/// `rich_content_golden_test.dart`, and for the same reason: the alternative is
/// reaching for a host font and making the images depend on which machine took
/// them. It costs these goldens nothing they are for. Bidi resolution is by
/// codepoint and happens before shaping, so the run is still laid out
/// right-to-left, still aligned to the trailing edge of its bubble, and still
/// sitting in a mirrored screen — the direction is legible in the boxes'
/// *arrangement*, which is the whole claim. Reading the words is the device
/// pass in task 9.
void main() {
  setUpAll(loadGoldenFonts);

  // One window per scene, held constant across the variants: the variant has to
  // be the only thing that differs between two images, or the diff is
  // unreadable. Each is big enough that nothing is scrolled out of frame at
  // 1.0× and small enough that 2.0× has somewhere to fail.
  const inboxWindow = Size(1180, 900);
  const chatWindow = Size(600, 900);
  const screenWindow = Size(940, 900);

  late DemoChatRepository demo;

  setUp(() {
    // The parse cache is global and keyed by `(roomId, eventId)`. Forty pumps
    // of the same fixture would otherwise all render the first one's words.
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  /// A thread whose messages do not agree about which way they read.
  ///
  /// Four bubbles covering the cases the bidi rule has to separate: a Hebrew
  /// message from a peer, an English reply of the reader's own, an Arabic
  /// message on a second leg of the merged chat, and — the one that catches a
  /// majority-vote direction heuristic — a Hebrew message carrying two Latin
  /// brand names, which is right-to-left by the first-strong rule and
  /// left-to-right by character count.
  SeededChatRepository mixedThread() => SeededChatRepository(
    demo,
    messages: [
      seededMessage(
        eventId: r'$he',
        body: 'שלום, מתי נפגשים ביום חמישי?',
        minutesAgo: 24,
      ),
      seededMessage(
        eventId: r'$en',
        body: 'the usual place, quarter past two',
        isOwn: true,
        minutesAgo: 20,
      ),
      seededMessage(
        eventId: r'$ar',
        roomId: '!seeded_signal:example.org',
        network: ChatNetwork.signal,
        senderName: 'Ravi Prasad',
        senderId: '@ravi:example.org',
        body: 'أنا في الطريق، خمس دقائق',
        minutesAgo: 12,
      ),
      seededMessage(
        eventId: r'$mixed',
        body: 'העברתי את הקישור ב־Signal ולא ב־Telegram',
        minutesAgo: 6,
      ),
    ],
  );

  /// A store, torn down with the test that made it.
  WeftStores freshStores() {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    return stores;
  }

  /// A search index with enough in it to draw a result list and its filters.
  ///
  /// The bodies are deliberately long enough to wrap: a snippet that fits on
  /// one line at 1.0× and needs three at 2.0× is where a result row clips, and
  /// a row that never wraps would report nothing.
  WeftStores indexedStores() {
    final stores = freshStores();
    for (final (eventId, body, network, sender) in [
      (
        r'$one',
        'the roof is leaking again over the back stairs — I have put a bucket '
            'under it for now',
        ChatNetwork.telegram,
        'Anna Maven',
      ),
      (
        r'$two',
        'roof inspection is booked for Thursday morning, they said to expect '
            'about two hours',
        ChatNetwork.whatsapp,
        'Ravi Prasad',
      ),
      (
        r'$three',
        'did the roof people ever send the quote?',
        ChatNetwork.signal,
        'Lena Okafor',
      ),
    ]) {
      stores.search.indexMessage(
        WeftMessage(
          eventId: eventId,
          roomId: '!room:example.org',
          network: network,
          senderId: '@${sender.split(' ').first.toLowerCase()}:example.org',
          senderName: sender,
          timestamp: DateTime(2026, 8, 18, 14, 32),
          kind: MessageKind.text,
          isOwn: false,
          body: body,
        ),
        chatId: 'merged:anna',
        chatTitle: 'The Thursday plan',
      );
    }
    return stores;
  }

  /// Puts the composer into reply mode against the bubble carrying [body].
  ///
  /// Driven through the message actions sheet rather than by reaching into
  /// [ChatView]'s state, because the sheet is itself a surface the text scale
  /// can break — a scene that set the mode directly would capture a composer
  /// that had never proved it could be *reached* at 2.0×. `ensureVisible`
  /// rather than a bare tap for the same reason: the sheet scrolls, and at 2.0×
  /// the row it opens on is no longer where it was.
  Future<void> openReply(WidgetTester tester, String body) async {
    await tester.longPress(
      find.text(body, findRichText: true).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    final reply = find.widgetWithText(ListTile, 'Reply');
    await tester.ensureVisible(reply);
    await tester.pumpAndSettle();
    await tester.tap(reply);
    await tester.pumpAndSettle();
  }

  /// One screen and the finder that frames it.
  ///
  /// Every scene takes a [Key] and hangs it on the widget it pumps. Two images
  /// are captured per test — dark then light — and without a key the second
  /// `pumpWidget` reuses the first run's `State`, so the light image of the
  /// composer scene would be taken with the dark run's reply mode still open:
  /// a golden of the wrong thing that never fails.
  final scenes =
      <
        ({
          String name,
          Finder target,
          Future<void> Function(
            WidgetTester,
            WeftThemeMode,
            WeftGoldenVariant,
            Key,
          )
          pump,
        })
      >[
        (
          name: 'inbox',
          target: find.byType(InboxShell),
          pump: (tester, mode, variant, key) async {
            await pumpWeft(
              tester,
              InboxShell(key: key),
              size: inboxWindow,
              mode: mode,
              variant: variant,
              repository: demo,
              stores: freshStores(),
            );
          },
        ),
        (
          name: 'chat_mixed',
          target: find.byType(ChatView),
          pump: (tester, mode, variant, key) async {
            final repository = mixedThread();
            await pumpWeft(
              tester,
              ChatView(key: key, chatId: repository.chatId),
              size: chatWindow,
              mode: mode,
              variant: variant,
              repository: repository,
            );
          },
        ),
        (
          name: 'composer_reply',
          target: find.byType(ChatView),
          pump: (tester, mode, variant, key) async {
            final repository = mixedThread();
            await pumpWeft(
              tester,
              ChatView(key: key, chatId: repository.chatId),
              size: chatWindow,
              mode: mode,
              variant: variant,
              repository: repository,
            );
            // The Arabic bubble on purpose: the reply chip then has to hold a
            // right-to-left preview inside a composer whose own chrome follows the
            // reader, which is the bar's hardest case and the one the phase's
            // "bidirectional text" bullet is about.
            await openReply(tester, 'أنا في الطريق، خمس دقائق');
          },
        ),
        (
          name: 'search',
          target: find.byType(SearchScreen),
          pump: (tester, mode, variant, key) async {
            await pumpWeft(
              tester,
              SearchScreen(key: key, initialQuery: 'roof'),
              size: screenWindow,
              mode: mode,
              variant: variant,
              repository: demo,
              stores: indexedStores(),
            );
          },
        ),
        (
          name: 'settings',
          target: find.byType(EndpointsScreen),
          pump: (tester, mode, variant, key) async {
            await pumpWeft(
              tester,
              EndpointsScreen(key: key),
              size: screenWindow,
              mode: mode,
              variant: variant,
              repository: demo,
              stores: freshStores(),
            );
          },
        ),
      ];

  for (final scene in scenes) {
    group(scene.name, () {
      for (final variant in weftAccessibilityVariants) {
        testWidgets(variant.name, (tester) async {
          for (final (mode, suffix) in const [
            (WeftThemeMode.dark, 'dark'),
            (WeftThemeMode.light, 'light'),
          ]) {
            clearMessageDocumentCache();
            await scene.pump(
              tester,
              mode,
              variant,
              ValueKey('${variant.name}_$suffix'),
            );
            await expectLater(
              scene.target,
              matchesGoldenFile(
                'a11y_${scene.name}_${variant.name}_$suffix.png',
              ),
            );
          }
        });
      }
    });
  }
}
