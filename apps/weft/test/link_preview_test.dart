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
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/link_preview_card.dart';
import 'package:weft/features/settings/link_previews_screen.dart';
import 'package:weft/features/settings/settings_section.dart';
import 'package:weft/services/links/link_preview_service.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

WeftMessage _message({
  String body = 'look at https://example.org/a',
  String? formattedBody,
  ChatNetwork network = ChatNetwork.signal,
  bool redacted = false,
}) => WeftMessage(
  eventId: r'$m1',
  roomId: '!r:example.org',
  network: network,
  senderId: '@anna:example.org',
  senderName: 'Anna',
  body: body,
  formattedBody: formattedBody,
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

  testWidgets('a url quoted in a code block is not a link the reader shared', (
    tester,
  ) async {
    // Pasting a snippet is not sharing what is in it, and turning a line of
    // someone else's config into a homeserver request is a disclosure the
    // reader never made. `links_test.dart` pins the extraction; this pins that
    // the card asks the same question the extractor answers.
    final asked = await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      message: _message(
        body: 'curl https://internal.example/health',
        formattedBody:
            '<pre><code>curl https://internal.example/health</code></pre>',
      ),
      answer: _found,
    );

    expect(asked, 0);
  });

  testWidgets('a link under a spoiler is not asked about', (tester) async {
    // Found while auditing this file: the extractor skipped code and not
    // spoilers, so a covered link was fetched and its title, description and
    // host were printed on a card under the very bubble that was hiding it —
    // before the reader touched anything. The card is where the failure is
    // visible, which is why the assertion lives here as well as in
    // `links_test.dart`.
    final asked = await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      message: _message(
        body: 'the ending: https://example.org/twist',
        formattedBody:
            'the ending: <span data-mx-spoiler="">'
            '<a href="https://example.org/twist">here</a></span>',
      ),
      answer: _found,
    );

    expect(asked, 0);
    expect(find.byType(LinkPreviewCardBody), findsNothing);
  });

  testWidgets('a message full of links asks about the first one only', (
    tester,
  ) async {
    // Five cards under a message of five links bury the words the sender wrote,
    // and each one is its own request.
    final asked = await _pumpCard(
      tester,
      settings: const LinkPreviewSettings(enabled: true),
      message: _message(
        body:
            'https://example.org/one https://example.org/two '
            'https://example.org/three',
      ),
      answer: _found,
    );

    expect(asked, 1);
    expect(find.byType(LinkPreviewCardBody), findsOneWidget);
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

  /// The switch itself. Everything above assumes a setting that got there
  /// somehow, and this is the screen that puts it there — the one place in the
  /// feature where the user is told what they are agreeing to.
  group('the opt-in', () {
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

    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesBootstrapProvider.overrideWith((ref) async => stores),
            chatRepositoryProvider.overrideWithValue(demo),
          ],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: const LinkPreviewsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says what the homeserver learns before it can be turned on', (
      tester,
    ) async {
      await pumpScreen(tester);

      // The cost, in the words the user would use, next to the switch rather
      // than behind a link — the same shape as the endpoints screen's notices.
      expect(find.byType(PrivacyNotice), findsOneWidget);
      expect(
        find.textContaining('your homeserver learns every link'),
        findsOneWidget,
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
        isFalse,
        reason: 'a gate that starts open is not a gate',
      );
    });

    testWidgets('turning it on is what writes the setting', (tester) async {
      await pumpScreen(tester);
      await tester.tap(find.text('Show link previews'));
      await tester.pumpAndSettle();

      expect(LinkPreviewSettings.fromStore(stores.settings).enabled, isTrue);
      // The per-network escape hatch only exists once there is something to
      // escape from.
      expect(find.text('Networks'), findsOneWidget);
    });

    testWidgets('excluding a network keeps the rest previewable', (
      tester,
    ) async {
      const LinkPreviewSettings(enabled: true).writeTo(stores.settings);
      await pumpScreen(tester);

      await tester.tap(find.text(ChatNetwork.signal.label));
      await tester.pumpAndSettle();

      final settings = LinkPreviewSettings.fromStore(stores.settings);
      expect(settings.allows(ChatNetwork.signal), isFalse);
      expect(settings.allows(ChatNetwork.telegram), isTrue);
    });

    testWidgets('turning it off forgets the answers already given', (
      tester,
    ) async {
      // Rows left behind would keep drawing cards from lookups the user has
      // this moment withdrawn their consent for — the card cannot tell a cached
      // answer from a fresh one, and should not have to.
      const LinkPreviewSettings(enabled: true).writeTo(stores.settings);
      stores.linkPreviews.write('https://example.org/a', {'title': 'A title'});
      await pumpScreen(tester);

      await tester.tap(find.text('Show link previews'));
      await tester.pumpAndSettle();

      expect(LinkPreviewSettings.fromStore(stores.settings).enabled, isFalse);
      expect(stores.linkPreviews.count, 0);
    });

    testWidgets('clearing the cache says how much it forgot', (tester) async {
      const LinkPreviewSettings(enabled: true).writeTo(stores.settings);
      stores.linkPreviews.write('https://example.org/a', {'title': 'A title'});
      await pumpScreen(tester);

      // Below the fold on a short screen, which is fine for a button on a
      // scrolling settings page — unlike the action sheet, there is a whole
      // list above it saying more is there.
      await tester.scrollUntilVisible(
        find.text('Clear cached previews'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Clear cached previews'));
      await tester.pumpAndSettle();

      expect(find.text('Forgot 1 preview.'), findsOneWidget);
      expect(stores.linkPreviews.count, 0);
    });
  });
}
