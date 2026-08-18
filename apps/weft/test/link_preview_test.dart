/// The link preview card, at the widget layer.
///
/// The companion to `link_preview_service_test.dart`, which counts requests.
/// This file asks the other half of the question: given an answer — or the
/// absence of one — what does the reader actually see? Every "no card" case
/// has to look identical, because a card that announced its own failure would
/// turn the privacy setting into a row of apologies down the conversation and
/// would leak which links the homeserver declined to look at.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/chat/link_preview_card.dart';
import 'package:weft/services/links/link_preview_service.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

WeftMessage _message({
  String body = 'look at https://example.org/a',
  ChatNetwork network = ChatNetwork.signal,
  bool redacted = false,
}) => WeftMessage(
  eventId: r'$m1',
  roomId: '!r:example.org',
  network: network,
  senderId: '@anna:example.org',
  senderName: 'Anna',
  body: body,
  timestamp: DateTime.utc(2026, 8, 18, 14),
  isOwn: false,
  kind: MessageKind.text,
  redacted: redacted,
);

/// Pumps one card with a settings store and a scripted homeserver behind it.
///
/// [answer] is what the homeserver says. Returning null is the ordinary shape
/// of a refusal, a rate limit and a page with no OpenGraph tags alike — the
/// fetcher never throws, by contract.
Future<int> _pumpCard(
  WidgetTester tester, {
  required LinkPreviewSettings settings,
  WeftMessage? message,
  LinkPreview? Function(Uri url)? answer,
  bool withFetcher = true,
}) async {
  final stores = WeftStores.inMemory();
  addTearDown(stores.dispose);
  settings.writeTo(stores.settings);

  var asked = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storesBootstrapProvider.overrideWith((ref) async => stores),
        linkPreviewFetchProvider.overrideWithValue(
          withFetcher
              ? (url) async {
                  asked++;
                  return answer?.call(url);
                }
              : null,
        ),
      ],
      child: MaterialApp(
        theme: WeftTheme.build(),
        home: Scaffold(
          body: LinkPreviewCard(message: message ?? _message(), own: false),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return asked;
}

LinkPreview? _found(Uri url) => LinkPreview(
  url: url.toString(),
  title: 'A title',
  description: 'A description',
  siteName: 'Example',
);

void main() {
  testWidgets('the card is absent while the setting is off', (tester) async {
    final asked = await _pumpCard(
      tester,
      settings: LinkPreviewSettings.off,
      answer: _found,
    );

    expect(find.text('A title'), findsNothing);
    // Not merely hidden: nothing was asked. A card that fetched and then
    // declined to draw would have already made the disclosure.
    expect(asked, 0);
  });

  testWidgets('the card appears once the setting is on', (tester) async {
    final asked = await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      answer: _found,
    );

    expect(find.text('A title'), findsOneWidget);
    expect(find.text('A description'), findsOneWidget);
    expect(asked, 1);
  });

  testWidgets('an excluded network is not previewed', (tester) async {
    final asked = await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(
        enabled: true,
        excludedNetworks: {'signal'},
      ),
      answer: _found,
    );

    expect(find.text('A title'), findsNothing);
    expect(asked, 0);
  });

  testWidgets('a fetch that finds nothing leaves no trace', (tester) async {
    await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      answer: (_) => null,
    );

    expect(find.byType(LinkPreviewCardBody), findsNothing);
    // Same on screen as the gate being off, which is the point: the reader
    // cannot tell a refused request from a setting they chose.
    expect(find.text('A title'), findsNothing);
  });

  testWidgets('an answer with no content is not a card', (tester) async {
    await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      answer: (url) => LinkPreview(url: url.toString()),
    );

    expect(find.byType(LinkPreviewCardBody), findsNothing);
  });

  testWidgets('nothing is drawn with no homeserver to ask', (tester) async {
    await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      withFetcher: false,
    );

    expect(find.byType(LinkPreviewCardBody), findsNothing);
  });

  testWidgets('a message with no link asks nothing', (tester) async {
    final asked = await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      message: _message(body: 'no links in here at all'),
      answer: _found,
    );

    expect(asked, 0);
  });

  testWidgets('a deleted message is not previewed', (tester) async {
    // The body survives redaction in the mapped event; the curiosity should
    // not.
    final asked = await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      message: _message(redacted: true),
      answer: _found,
    );

    expect(asked, 0);
  });

  testWidgets('a mailto: link is never asked about', (tester) async {
    final asked = await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      message: _message(body: 'write to mailto:anna@example.org'),
      answer: _found,
    );

    expect(asked, 0);
  });

  group('the card body', () {
    Future<void> pumpBody(
      WidgetTester tester,
      LinkPreview preview, {
      bool own = false,
    }) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: Scaffold(
            body: LinkPreviewCardBody(
              preview: preview,
              own: own,
              network: ChatNetwork.signal,
            ),
          ),
        ),
      ),
    );

    testWidgets('shows the site, the title, the words and the host', (
      tester,
    ) async {
      await pumpBody(
        tester,
        const LinkPreview(
          url: 'https://www.example.org/a',
          title: 'A title',
          description: 'A description',
          siteName: 'Example',
        ),
      );

      expect(find.text('Example'), findsOneWidget);
      expect(find.text('A title'), findsOneWidget);
      expect(find.text('A description'), findsOneWidget);
      // Stripped of www., because that is the same promise.
      expect(find.text('example.org'), findsOneWidget);
    });

    testWidgets('falls back to the host when the site did not name itself', (
      tester,
    ) async {
      await pumpBody(
        tester,
        const LinkPreview(url: 'https://example.org/a', title: 'A title'),
      );

      // Once, not twice: the header line is the host when there is no site
      // name, and repeating it underneath would be a card of one fact.
      expect(find.text('example.org'), findsOneWidget);
    });

    testWidgets('renders a hostile title as text, never as markup', (
      tester,
    ) async {
      const hostile = '<script>alert(1)</script> Free money';
      await pumpBody(
        tester,
        const LinkPreview(url: 'https://evil.test/a', title: hostile),
      );

      // The page chose these words. They go through a Text and nothing else —
      // never through parseFormattedBody, which is for message bodies.
      expect(find.text(hostile), findsOneWidget);
    });

    testWidgets('a remote og:image cannot reach the card at all', (
      tester,
    ) async {
      // Sanitised on construction: a card that resolved a remote image would
      // load a tracking pixel from the reader's own address and undo the whole
      // homeserver-proxied design.
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:title': 'A title',
        'og:image': 'https://tracker.example/px.gif',
      });

      await pumpBody(tester, preview);
      expect(find.byType(Image), findsNothing);
    });
  });
}
