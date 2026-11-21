import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/link_preview_card.dart';
import 'package:weft/features/chat/rich_text_view.dart';

import '../support/attachment_fixtures.dart';
import '../support/golden_harness.dart';
import '../support/seeded_repository.dart';

/// Goldens for the link preview card's own states.
///
/// `rich_content_golden_test.dart` already pins the card inside a bubble with
/// a homeserver answering. This file pins what that scene cannot reach: a
/// thumbnail (the real one is an authenticated homeserver request a test
/// cannot answer, so the card body is pumped with the picture handed in), a
/// title long enough to clamp, a right-to-left layout, and a card a *bridge*
/// attached in an encrypted room — drawn with no homeserver asked at all.
void main() {
  setUpAll(loadGoldenFonts);

  final photo = MemoryImage(kPhoto);

  const withImage = LinkPreview(
    url: 'https://weft.example/posts/merging',
    title: 'Bridging without a bridge: what Weft got wrong first',
    description:
        'Three rewrites of the merged timeline, and the watermark rule that '
        'finally made it stop reordering itself.',
    siteName: 'The Weft Log',
    imageUrl: 'mxc://example.org/photo',
  );
  const textOnly = LinkPreview(
    url: 'https://notes.example/thursday',
    title: 'Thursday, 14:00 — agenda',
  );
  final longTitle = LinkPreview.fromOpenGraph('https://news.example/a', {
    'og:title':
        'A headline that goes on for considerably longer than any card has '
        'room for, so that the clamp, the ellipsis and the two-line limit '
        'all have to do their jobs at once',
    'og:description':
        'And a description that is just as unwilling to stop, which the '
        'card cuts at two lines rather than letting it push the bubble below '
        'off the screen.',
    'og:site_name': 'News',
  });

  /// The four cards, stacked on the conversation background: both sides of
  /// the conversation, because the own card takes a translucent own-bubble
  /// fill and is the one that can go unreadable.
  Widget sheet() => Builder(
    builder: (context) => Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(WeftSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinkPreviewCardBody(
              preview: withImage,
              own: false,
              network: ChatNetwork.telegram,
              image: photo,
            ),
            const SizedBox(height: WeftSpace.md),
            const LinkPreviewCardBody(
              preview: textOnly,
              own: false,
              network: ChatNetwork.signal,
            ),
            const SizedBox(height: WeftSpace.md),
            LinkPreviewCardBody(
              preview: longTitle,
              own: false,
              network: ChatNetwork.whatsapp,
            ),
            const SizedBox(height: WeftSpace.md),
            ColoredBox(
              color: context.palette.ownBubble,
              child: Padding(
                padding: const EdgeInsets.all(WeftSpace.sm),
                child: LinkPreviewCardBody(
                  preview: withImage,
                  own: true,
                  network: ChatNetwork.telegram,
                  image: photo,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> expectSheetGolden(
    WidgetTester tester,
    String name, {
    WeftGoldenVariant variant = weftGoldenBaseline,
  }) async {
    await primeImage(tester, photo);
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      await pumpWeft(
        tester,
        KeyedSubtree(key: ValueKey(suffix), child: sheet()),
        size: const Size(480, 620),
        mode: mode,
        variant: variant,
      );
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('${name}_$suffix.png'),
      );
    }
  }

  testWidgets('cards with and without a picture, and a long title', (
    tester,
  ) async {
    await expectSheetGolden(tester, 'link_preview_cards');
  });

  testWidgets('the same cards right to left', (tester) async {
    // The rule down the card's leading edge, the thumbnail and the text
    // alignment all have to follow the reading direction; a card that kept its
    // left-hand rule in Arabic is the regression this pins.
    await expectSheetGolden(
      tester,
      'link_preview_cards_rtl',
      variant: weftAccessibilityVariants.first,
    );
  });

  testWidgets('a preview a bridge attached, in an encrypted chat', (
    tester,
  ) async {
    // Default settings — previews on, encrypted chats off — and no homeserver
    // to ask: the card is the one WhatsApp showed, relayed by the bridge.
    final demo = DemoChatRepository(uploadTick: Duration.zero);
    addTearDown(demo.dispose);
    final asked = <Uri>[];
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      clearMessageDocumentCache();
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      final repository = SeededChatRepository(
        demo,
        messages: [
          seededMessage(
            eventId: r'$bridged',
            network: ChatNetwork.whatsapp,
            minutesAgo: 20,
            encrypted: true,
            body: 'flights are up https://travel.example/deals/lisbon',
            bridgedLinkPreviews: const [
              {
                'matched_url': 'https://travel.example/deals/lisbon',
                'og:title': 'Lisbon from €89 return',
                'og:description': 'Spring fares, direct flights only.',
                'og:site_name': 'Travel Example',
              },
            ],
          ),
          seededMessage(
            eventId: r'$asked',
            network: ChatNetwork.whatsapp,
            minutesAgo: 18,
            encrypted: true,
            // No bridge preview and encrypted previews off: no card, and
            // nothing asked.
            body: 'and the hotel https://hotel.example/lisbon',
          ),
        ],
      );
      await pumpWeft(
        tester,
        ChatView(key: ValueKey(suffix), chatId: repository.chatId),
        size: const Size(560, 640),
        mode: mode,
        repository: repository,
        stores: stores,
        linkPreviewFetch: (url) async {
          asked.add(url);
          return null;
        },
      );
      await expectLater(
        find.byType(ChatView),
        matchesGoldenFile('link_preview_bridged_$suffix.png'),
      );
    }
    expect(asked, isEmpty);
  });
}
