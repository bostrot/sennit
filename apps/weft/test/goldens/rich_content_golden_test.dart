import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/services/links/link_preview_service.dart';

import '../support/golden_harness.dart';
import '../support/seeded_repository.dart';

/// Goldens for the rich-content surfaces built in Phase 05.
///
/// Every scene is captured *inside [ChatView]*, for the reason the attachment
/// goldens state: a reply chip, a reaction bar and a preview card all take
/// their ink from the bubble they hang off — `ownBubbleText` on the user's
/// side, the network's accent on a peer's — and an image of one on a bare
/// Scaffold would pass unchanged through exactly the regression it exists to
/// catch. The reaction bar and the preview card sit *outside* the bubble's
/// decoration and the reply chip sits *inside* it, which is a layout decision
/// only a picture can hold anyone to.
///
/// The fixtures are seeded rather than demo-generated. The demo inbox is a
/// fixed past with plain bodies, no links and one person reacting, so a
/// formatted body, somebody else's reaction and a cross-leg reply are all
/// unreachable from it — [SeededChatRepository] serves an arbitrary history
/// through the real [MergedTimeline], so the widget in the image is still the
/// chat view wired the way the app wires it.
void main() {
  setUpAll(loadGoldenFonts);

  late DemoChatRepository demo;

  setUp(() {
    // The parse cache is global and keyed by `(roomId, eventId)`. Two scenes
    // reusing an id would otherwise render the first one's words.
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  /// Pumps a seeded chat and captures it under [name] for both themes.
  ///
  /// One helper rather than two tests because the thing being compared across
  /// the pair is the *same* tree: a reaction chip that reads on a dark surface
  /// and disappears on a light one is the failure mode, and it is only visible
  /// when the two images come from an identical fixture.
  Future<void> expectChatGolden(
    WidgetTester tester,
    String name, {
    required List<WeftMessage> history,
    Size size = const Size(560, 820),
    WeftStores Function()? stores,
    LinkPreviewFetch? linkPreviewFetch,
    Future<void> Function(WidgetTester tester)? after,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      clearMessageDocumentCache();
      final repository = SeededChatRepository(demo, messages: history);
      final opened = stores?.call();
      if (opened != null) addTearDown(opened.dispose);

      await pumpWeft(
        tester,
        // Keyed by the theme, so the second pump builds a *new* [ChatView]
        // state rather than reusing the first one's. Without it a scene that
        // drives the UI — opening reply mode, say — captures the light image
        // with the dark run's composer still open.
        ChatView(key: ValueKey(suffix), chatId: repository.chatId),
        size: size,
        mode: mode,
        repository: repository,
        stores: opened,
        linkPreviewFetch: linkPreviewFetch,
      );
      await after?.call(tester);

      await expectLater(
        find.byType(ChatView),
        matchesGoldenFile('${name}_$suffix.png'),
      );
    }
  }

  testWidgets('a formatted body, both themes', (tester) async {
    // Every block kind the renderer handles, in the order the parser can
    // produce them: heading, prose with the four inline flags, a link, a
    // mention pill, a blockquote, both list kinds and a code block. A tag that
    // stops being styled — or one that starts eating the space around it —
    // shows up here and nowhere else.
    await expectChatGolden(
      tester,
      'rich_formatted',
      size: const Size(560, 980),
      history: [
        seededMessage(
          eventId: r'$prose',
          minutesAgo: 12,
          body:
              'Release plan\n'
              'Thursday, if the pipeline stays green. Ask Anna about the '
              'rollout notes.',
          formattedBody:
              '<h3>Release plan</h3>'
              '<p><b>Thursday</b>, if the pipeline stays <i>green</i>. '
              '<s>Wednesday</s> is off the table — see '
              '<a href="https://example.org/rollout">the rollout notes</a>, '
              'and ask '
              '<a href="https://matrix.to/#/@anna:example.org">Anna</a> '
              'before you touch <code>deploy.sh</code>.</p>'
              '<blockquote>we agreed to hold the flag until QA signs '
              'off</blockquote>'
              '<ul><li>freeze at 09:00</li><li>tag the build</li></ul>'
              '<ol start="3"><li>announce</li><li>watch the graphs</li></ol>',
        ),
        seededMessage(
          eventId: r'$snippet',
          isOwn: true,
          minutesAgo: 9,
          body: 'run this first:\n\nexport WEFT_LOG=debug\nweft doctor --all',
          formattedBody:
              '<p>run this first:</p>'
              '<pre><code>export WEFT_LOG=debug\n'
              'weft doctor --all</code></pre>',
        ),
      ],
    );
  });

  testWidgets('reply chips, both themes', (tester) async {
    // Three chips and the composer's bar, which is the same widget in its
    // `compact` form: a resolved reply on the leg the target is on, a reply
    // from a *different* leg of the merged chat, and a reply whose target has
    // not been paginated in. The stub is the one worth an image — it has to
    // read as "not here yet" rather than as a message somebody sent.
    await expectChatGolden(
      tester,
      'rich_reply',
      history: [
        seededMessage(
          eventId: r'$asked',
          minutesAgo: 20,
          body: 'Where are we meeting on Thursday?',
        ),
        seededMessage(
          eventId: r'$answered',
          isOwn: true,
          minutesAgo: 18,
          replyToEventId: r'$asked',
          body:
              '> <@anna:example.org> Where are we meeting on Thursday?\n\n'
              'the usual place, 14:00',
        ),
        // A second leg of the same merged chat, answering a message that lives
        // in the first one — the case the chip's network glyph exists for.
        seededMessage(
          eventId: r'$echoed',
          roomId: '!seeded_signal:example.org',
          network: ChatNetwork.signal,
          senderName: 'Ravi Prasad',
          senderId: '@ravi:example.org',
          minutesAgo: 15,
          replyToEventId: r'$asked',
          body: 'I can be there by quarter past.',
        ),
        seededMessage(
          eventId: r'$dangling',
          isOwn: true,
          minutesAgo: 12,
          replyToEventId: r'$never_paginated_in',
          body: 'about that — yes, agreed',
        ),
      ],
      after: (tester) async {
        // Opens reply mode so the composer's context bar is in the frame. It
        // is the same [ReplyChip] with two lines instead of one, sitting on the
        // app surface rather than on a bubble, which is the only place its
        // colours can be judged. The target is the Signal leg's message —
        // nothing quotes it, so the finder is unambiguous, and the bar carries
        // a network glyph the way it does in a merged chat.
        await tester.longPress(
          find.text('I can be there by quarter past.', findRichText: true),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reply'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('reaction bars, both themes', (tester) async {
    // The two states colour alone cannot separate: a tally the reader is part
    // of is outlined as well as tinted, and one they are not is neither. The
    // bar hangs below the bubble and lines up with its side, so a peer bubble
    // and an own bubble are both here.
    //
    // The emoji themselves draw as placeholder boxes: no emoji face ships in
    // the SDK cache, and reaching for the host's would make the image depend on
    // which machine took it. What this golden is for is the chip — its fill,
    // its outline, the count beside it and where the bar sits — all of which
    // are the app's own pixels.
    final reactedAt = DateTime(2026, 8, 18, 13, 40);
    await expectChatGolden(
      tester,
      'rich_reactions',
      history: [
        seededMessage(
          eventId: r'$news',
          minutesAgo: 30,
          body: 'The migration finished — no rows dropped.',
          reactions: [
            ReactionTally(
              key: '🎉',
              senderIds: const [
                '@ravi:example.org',
                '@sam:example.org',
                '@lena:example.org',
              ],
              firstReactedAt: reactedAt,
            ),
            ReactionTally(
              key: '👍',
              senderIds: const ['@me:example.org', '@ravi:example.org'],
              firstReactedAt: reactedAt.add(const Duration(minutes: 1)),
              byLocalUser: true,
              localEventId: r'$my_thumb',
            ),
          ],
        ),
        seededMessage(
          eventId: r'$thanks',
          isOwn: true,
          minutesAgo: 26,
          body: 'Thanks for staying up for it.',
          reactions: [
            ReactionTally(
              key: '❤',
              senderIds: const ['@anna:example.org'],
              firstReactedAt: reactedAt.add(const Duration(minutes: 4)),
            ),
          ],
        ),
      ],
    );
  });

  testWidgets('link preview cards, both themes', (tester) async {
    // The only scene with the privacy gate open, which is what it takes to draw
    // a card at all: a settings store that says yes and a homeserver that
    // answers. Both bubbles are here because the card takes the bubble's fill —
    // a translucent own-bubble over the user's side, the peer fill on the
    // other — and the own variant is the one that can go unreadable.
    await expectChatGolden(
      tester,
      'rich_link_preview',
      stores: () {
        final stores = WeftStores.inMemory();
        const LinkPreviewSettings(enabled: true).writeTo(stores.settings);
        return stores;
      },
      linkPreviewFetch: (url) async => switch (url.host) {
        'weft.example' => LinkPreview(
          url: url.toString(),
          title: 'Bridging without a bridge: what Weft got wrong first',
          description:
              'Three rewrites of the merged timeline, and the watermark '
              'rule that finally made it stop reordering itself.',
          siteName: 'The Weft Log',
        ),
        // No site name and no description: the shortest card the layout has to
        // hold, which is where a stray divider or a collapsed row shows up.
        _ => LinkPreview(
          url: url.toString(),
          title: 'Thursday, 14:00 — agenda',
        ),
      },
      history: [
        seededMessage(
          eventId: r'$shared',
          minutesAgo: 40,
          body: 'this is the one I meant https://weft.example/posts/merging',
        ),
        seededMessage(
          eventId: r'$agenda',
          isOwn: true,
          minutesAgo: 36,
          body: 'agenda is here: https://notes.example/thursday',
        ),
      ],
    );
  });
}
