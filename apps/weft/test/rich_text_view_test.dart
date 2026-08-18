import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

import 'support/seeded_repository.dart';

/// The renderer half of rich content: what a formatted body turns into on
/// screen, and — the part that matters most — what a hostile one does not.
///
/// The parser's own battery lives in `packages/weft_richtext/test/parse_test.dart`
/// and asserts the *document*. This asserts the widget: that a tappable link
/// exists only where the parser made a [RichLink], and that everything else a
/// sender can write arrives as inert text.
void main() {
  setUp(clearMessageDocumentCache);

  Future<void> pump(
    WidgetTester tester,
    RichDocument document, {
    void Function(String url, String label)? onTapLink,
    void Function(RichMention mention)? onTapMention,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(),
        home: Scaffold(
          body: Builder(
            builder: (context) => RichTextView(
              document: document,
              baseStyle: const TextStyle(fontSize: 14, color: Colors.black),
              accent: context.colors.primary,
              onTapLink: onTapLink,
              onTapMention: onTapMention,
            ),
          ),
        ),
      ),
    );
  }

  RichDocument html(String formatted, {String plain = 'fallback'}) =>
      parseMessageBody(body: plain, formattedBody: formatted);

  /// Every rendered [TextSpan] carrying [text], across every paragraph.
  List<TextSpan> spansFor(WidgetTester tester, String text) {
    final found = <TextSpan>[];
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == text) found.add(span);
        return true;
      });
    }
    return found;
  }

  /// Fires the recogniser on the span carrying exactly [text].
  ///
  /// Going through the recogniser rather than `tester.tap` is what makes the
  /// assertion about *that* span: a bubble is a paragraph of runs sitting on top
  /// of each other, and a tap at a widget's centre lands wherever the layout put
  /// it.
  Future<void> tapLink(WidgetTester tester, String text) async {
    final recognizer = spansFor(tester, text).single.recognizer;
    expect(recognizer, isA<TapGestureRecognizer>());
    (recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();
  }

  /// Whether anything on screen would respond to a tap as a link.
  bool hasTappableSpan(WidgetTester tester) {
    var tappable = false;
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.recognizer != null) tappable = true;
        return true;
      });
    }
    return tappable;
  }

  group('formatting', () {
    testWidgets('bold, italic and strikethrough reach the text style', (
      tester,
    ) async {
      await pump(tester, html('<b>bold</b> <i>italic</i> <del>gone</del>'));

      expect(
        spansFor(tester, 'bold').single.style?.fontWeight,
        FontWeight.w700,
      );
      expect(
        spansFor(tester, 'italic').single.style?.fontStyle,
        FontStyle.italic,
      );
      expect(
        spansFor(tester, 'gone').single.style?.decoration,
        TextDecoration.combine([TextDecoration.lineThrough]),
      );
    });

    testWidgets('inline code is monospaced and tinted', (tester) async {
      await pump(tester, html('run <code>weft --help</code> first'));

      final code = spansFor(tester, 'weft --help').single;
      expect(code.style?.fontFamily, 'monospace');
      expect(code.style?.backgroundColor, isNotNull);
    });

    testWidgets('a code block keeps its lines and stays unformatted', (
      tester,
    ) async {
      await pump(tester, html('<pre><code>one\ntwo <b>three</b></code></pre>'));

      // The `<b>` inside a code block is text the sender wrote as code, not
      // emphasis — it renders as one run with the markup already dropped.
      expect(find.textContaining('one\ntwo three'), findsOneWidget);
    });

    testWidgets('a blockquote renders its text, not its markup', (
      tester,
    ) async {
      await pump(tester, html('<blockquote>as I said</blockquote>'));
      expect(find.textContaining('as I said'), findsOneWidget);
    });

    testWidgets('lists render a marker per item', (tester) async {
      await pump(tester, html('<ul><li>milk</li><li>bread</li></ul>'));

      expect(find.text('•'), findsNWidgets(2));
      expect(find.textContaining('milk'), findsOneWidget);
      expect(find.textContaining('bread'), findsOneWidget);
    });

    testWidgets('an ordered list counts from its start attribute', (
      tester,
    ) async {
      await pump(
        tester,
        html('<ol start="3"><li>third</li><li>fourth</li></ol>'),
      );

      expect(find.text('3.'), findsOneWidget);
      expect(find.text('4.'), findsOneWidget);
    });

    testWidgets('a quote inside a quote renders as two levels', (tester) async {
      // Bridged mail-style bodies nest quotes several deep, and a renderer that
      // flattened them would attribute the inner sentence to whoever wrote the
      // outer one.
      await pump(
        tester,
        html(
          '<blockquote>she said <blockquote>he said</blockquote></blockquote>',
        ),
      );

      expect(find.textContaining('she said'), findsWidgets);
      expect(find.textContaining('he said'), findsWidgets);
      // Two rules down the left, one per level: two indents read as a margin,
      // where two rules read as two levels.
      final rules = tester.widgetList<Container>(find.byType(Container)).where((
        c,
      ) {
        final decoration = c.decoration;
        return decoration is BoxDecoration &&
            decoration.border is Border &&
            (decoration.border! as Border).left.width == 3;
      });
      expect(rules, hasLength(2));
    });

    testWidgets('an empty body draws nothing rather than a blank line', (
      tester,
    ) async {
      // Reachable: a body that was nothing but a dropped subtree, and a sticker
      // whose fallback text is empty. A stray paragraph would open a gap above
      // the timestamp row that nothing explains.
      await pump(tester, parseMessageBody(body: '', formattedBody: ''));

      expect(find.byType(RichText), findsNothing);
    });

    testWidgets('headings are larger than body text and bold', (tester) async {
      await pump(tester, html('<h1>Notice</h1>'));

      final heading = spansFor(tester, 'Notice').single;
      expect(heading.style!.fontSize, greaterThan(14));
      expect(heading.style!.fontWeight, FontWeight.w700);
    });
  });

  group('mentions', () {
    testWidgets('a permalink becomes a pill carrying the display name', (
      tester,
    ) async {
      await pump(
        tester,
        html('<a href="https://matrix.to/#/@anna:example.org">Anna</a> hi'),
      );

      expect(find.text('Anna'), findsOneWidget);
      // A pill, not a link: no recogniser was attached to a mention.
      expect(hasTappableSpan(tester), isFalse);
    });

    testWidgets('tapping a pill reports the id, not the display name', (
      tester,
    ) async {
      RichMention? tapped;
      await pump(
        tester,
        html('<a href="https://matrix.to/#/@anna:example.org">Anna</a>'),
        onTapMention: (mention) => tapped = mention,
      );

      await tester.tap(find.text('Anna'));
      await tester.pump();

      expect(tapped?.targetId, '@anna:example.org');
      expect(tapped?.kind, MentionKind.user);
    });

    testWidgets('@room in a plain body is a pill', (tester) async {
      await pump(tester, parseMessageBody(body: 'heads up @room'));

      expect(find.text('@room'), findsOneWidget);
    });

    testWidgets('tapping @room reports the room-wide kind', (tester) async {
      // The one mention with no id behind it: a handler that read `targetId`
      // to decide where to go would send the reader to a user page for a
      // person called `@room`.
      RichMention? tapped;
      await pump(
        tester,
        parseMessageBody(body: 'heads up @room'),
        onTapMention: (mention) => tapped = mention,
      );

      await tester.tap(find.text('@room'));
      await tester.pump();

      expect(tapped?.kind, MentionKind.roomWide);
    });

    testWidgets('a room permalink reports the alias it names', (tester) async {
      // The one mention kind the chat view can act on by itself: it looks the
      // alias up in the inbox and opens that conversation, so the *kind* is
      // what decides whether a tap navigates or merely names someone.
      RichMention? tapped;
      await pump(
        tester,
        html('see <a href="https://matrix.to/#/%23weft:example.org">#weft</a>'),
        onTapMention: (mention) => tapped = mention,
      );

      await tester.tap(find.text('#weft'));
      await tester.pump();

      expect(tapped?.kind, MentionKind.roomAlias);
      expect(tapped?.targetId, '#weft:example.org');
    });
  });

  group('links', () {
    testWidgets('an https link is tappable and reports its url', (
      tester,
    ) async {
      String? url;
      String? label;
      await pump(
        tester,
        html('<a href="https://example.org/notes">the notes</a>'),
        onTapLink: (u, l) {
          url = u;
          label = l;
        },
      );

      final span = spansFor(tester, 'the notes').single;
      expect(span.recognizer, isA<TapGestureRecognizer>());
      (span.recognizer! as TapGestureRecognizer).onTap!();

      expect(url, 'https://example.org/notes');
      expect(label, 'the notes');
    });

    testWidgets('a link whose label is bold is still tappable', (tester) async {
      // Regression shape: a recogniser on a `TextSpan` that only has children
      // never receives the tap, because hit testing resolves to the innermost
      // span carrying text. The link would be styled and inert.
      await pump(
        tester,
        html('<a href="https://example.org"><b>press</b></a>'),
      );

      expect(spansFor(tester, 'press').single.recognizer, isNotNull);
    });
  });

  group('spoilers', () {
    /// Fires whatever recogniser the span carrying [text] was given, which is
    /// what a tap on those exact words does. Going through the recogniser
    /// rather than `tester.tap` is the only way to be sure which span was hit:
    /// a covered link and the reveal sit on top of each other by design.
    Future<void> tapSpan(WidgetTester tester, String text) async {
      final recognizer = spansFor(tester, text).single.recognizer;
      expect(recognizer, isA<TapGestureRecognizer>());
      (recognizer! as TapGestureRecognizer).onTap!();
      await tester.pump();
    }

    testWidgets('spoiler text is covered until it is asked for', (
      tester,
    ) async {
      await pump(
        tester,
        html('the ending: <span data-mx-spoiler="">she leaves</span>'),
      );

      final covered = spansFor(tester, 'she leaves').single;
      expect(covered.style?.color, Colors.transparent);
      expect(covered.style?.backgroundColor, isNotNull);

      await tapSpan(tester, 'she leaves');

      expect(
        spansFor(tester, 'she leaves').single.style?.color,
        isNot(Colors.transparent),
      );
    });

    testWidgets('a link under a spoiler opens nothing until it is revealed', (
      tester,
    ) async {
      // The reason the reveal takes the tap rather than sharing it: a covered
      // link that opened on the first tap would send the reader to a
      // destination they were deliberately not shown.
      String? opened;
      await pump(
        tester,
        html(
          '<span data-mx-spoiler="">'
          '<a href="https://example.org/twist">the twist</a></span>',
        ),
        onTapLink: (url, _) => opened = url,
      );

      await tapSpan(tester, 'the twist');
      expect(opened, isNull);

      // Revealed, the same words are the link they always were.
      await tapSpan(tester, 'the twist');
      expect(opened, 'https://example.org/twist');
    });

    testWidgets('one tap reveals the whole message, not one fragment', (
      tester,
    ) async {
      // A sender who marks two halves of a sentence meant one secret, and
      // making the reader tap each fragment reads as the first tap failing.
      await pump(
        tester,
        html(
          '<span data-mx-spoiler="">she</span> and '
          '<span data-mx-spoiler="">him</span>',
        ),
      );

      await tapSpan(tester, 'she');

      expect(
        spansFor(tester, 'him').single.style?.color,
        isNot(Colors.transparent),
      );
    });
  });

  group('hostile bodies', () {
    /// The assertion this group exists for: a tappable link is a thing only the
    /// parser can create, and it creates one only for an allowlisted scheme. So
    /// "no `javascript:` link is reachable" is checked as "there is no link at
    /// all", which is a stronger and much harder statement to satisfy by
    /// accident.
    void expectNoLink(WidgetTester tester, RichDocument document) {
      expect(document.linkUrls, isEmpty);
      expect(hasTappableSpan(tester), isFalse);
    }

    testWidgets('a javascript: href never produces a tappable link', (
      tester,
    ) async {
      for (final href in [
        'javascript:alert(1)',
        'JavaScript:alert(1)',
        'java\tscript:alert(1)',
        '&#106;avascript:alert(1)',
        'data:text/html,<script>alert(1)</script>',
        'vbscript:msgbox(1)',
        'file:///etc/passwd',
      ]) {
        final document = html('<a href="$href">click here</a>');
        await pump(tester, document);

        // The anchor text survives — it is the message — but as inert prose.
        expect(find.textContaining('click here'), findsOneWidget);
        expectNoLink(tester, document);
      }
    });

    testWidgets('a script is not rendered and not reachable as text', (
      tester,
    ) async {
      final document = html('before<script>alert(1)</script>after');
      await pump(tester, document);

      expect(find.textContaining('alert(1)'), findsNothing);
      expect(document.plainText, isNot(contains('alert')));
      expectNoLink(tester, document);
    });

    testWidgets('a script hidden in a code block is not rendered either', (
      tester,
    ) async {
      // The one path that used to read descendant text wholesale, bypassing the
      // dropped-subtree rule the rest of the walk honours.
      final document = html(
        '<pre><code>safe();<script>alert(1)</script></code></pre>',
      );
      await pump(tester, document);

      expect(find.textContaining('alert(1)'), findsNothing);
      expect(find.textContaining('safe();'), findsOneWidget);
    });

    testWidgets('an onerror attribute has nowhere to land', (tester) async {
      final document = html('<img src="x" onerror="alert(1)">caption');
      await pump(tester, document);

      expect(find.textContaining('alert'), findsNothing);
      expectNoLink(tester, document);
    });

    testWidgets('a remote image src is dropped rather than fetched', (
      tester,
    ) async {
      // A remote `src` is a tracking pixel that fires the moment the timeline
      // scrolls past it, and the reader never chose to fetch it.
      final document = html(
        '<img src="https://tracker.test/p.gif" alt="pixel">text',
      );
      await pump(tester, document);

      expect(find.byType(Image), findsNothing);
      expect(find.byType(NetworkImage), findsNothing);
      expect(document.plainText, isNot(contains('tracker.test')));
    });

    testWidgets('an mxc image renders as its alt text, never as a request', (
      tester,
    ) async {
      await pump(
        tester,
        html('<img src="mxc://example.org/abc" alt=":partyparrot:">'),
      );

      expect(find.textContaining(':partyparrot:'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a body that is nothing but hostile falls back to the plain '
        'text', (tester) async {
      await pump(
        tester,
        parseMessageBody(
          body: 'the real message',
          formattedBody: '<script>alert(1)</script>',
        ),
      );

      expect(find.textContaining('the real message'), findsOneWidget);
    });
  });

  group('linkLabelMisleads', () {
    test('a label naming the destination host does not mislead', () {
      expect(
        linkLabelMisleads('example.org', Uri.parse('https://example.org/x')),
        isFalse,
      );
      expect(
        linkLabelMisleads(
          'https://example.org/x',
          Uri.parse('https://example.org/x'),
        ),
        isFalse,
      );
    });

    test('www. is the same promise as the bare host', () {
      expect(
        linkLabelMisleads(
          'www.example.org',
          Uri.parse('https://example.org/x'),
        ),
        isFalse,
      );
    });

    test('a label naming a different host misleads', () {
      expect(
        linkLabelMisleads(
          'bank.example',
          Uri.parse('https://bank.example.evil.test/login'),
        ),
        isTrue,
      );
    });

    test('a label that claims no host is not a claim', () {
      // Asking about every link would train the reader to dismiss the question,
      // which is how a confirmation stops working.
      expect(
        linkLabelMisleads('the agenda', Uri.parse('https://evil.test')),
        isFalse,
      );
      expect(
        linkLabelMisleads('here', Uri.parse('https://evil.test')),
        isFalse,
      );
      expect(linkLabelMisleads('', Uri.parse('https://evil.test')), isFalse);
    });
  });

  group('document cache', () {
    test('an edit re-parses rather than serving the old words', () {
      final original = WeftMessage(
        eventId: r'$one',
        roomId: '!room:example.org',
        network: ChatNetwork.matrix,
        senderId: '@a:example.org',
        senderName: 'A',
        timestamp: DateTime(2026, 8, 18, 9),
        kind: MessageKind.text,
        isOwn: false,
        body: 'before',
      );

      expect(messageDocument(original).plainText, 'before');
      expect(
        messageDocument(original.copyWith(body: 'after')).plainText,
        'after',
      );
    });

    test('the reply fallback is stripped, so the quote is not shown twice', () {
      final message = WeftMessage(
        eventId: r'$two',
        roomId: '!room:example.org',
        network: ChatNetwork.matrix,
        senderId: '@a:example.org',
        senderName: 'A',
        timestamp: DateTime(2026, 8, 18, 9),
        kind: MessageKind.text,
        isOwn: false,
        body: '> <@anna:example.org> where are we meeting\n\nthe usual place',
        replyToEventId: r'$one',
      );

      expect(messageDocument(message).plainText, 'the usual place');
    });

    testWidgets('an edit that only drops the markup still re-parses', (
      tester,
    ) async {
      // The half of the validation the body cannot cover: an edit whose plain
      // text is unchanged and whose formatting is gone is a real edit, and a
      // cache keyed on the body alone would keep rendering the bold.
      final formatted = WeftMessage(
        eventId: r'$three',
        roomId: '!room:example.org',
        network: ChatNetwork.matrix,
        senderId: '@a:example.org',
        senderName: 'A',
        timestamp: DateTime(2026, 8, 18, 9),
        kind: MessageKind.text,
        isOwn: false,
        body: 'six',
        formattedBody: '<b>six</b>',
      );

      await pump(tester, messageDocument(formatted));
      expect(spansFor(tester, 'six').single.style?.fontWeight, FontWeight.w700);

      await pump(
        tester,
        messageDocument(formatted.copyWith(formattedBody: null)),
      );
      expect(
        spansFor(tester, 'six').single.style?.fontWeight,
        isNot(FontWeight.w700),
      );
    });

    test('the same event id in two rooms is two documents', () {
      // Matrix event ids are globally unique in practice, but the cache key is
      // not a place to rely on that: a bridge that reuses an id across the two
      // legs of a merged chat would otherwise render one leg's words twice.
      final base = WeftMessage(
        eventId: r'$shared',
        roomId: '!one:example.org',
        network: ChatNetwork.matrix,
        senderId: '@a:example.org',
        senderName: 'A',
        timestamp: DateTime(2026, 8, 18, 9),
        kind: MessageKind.text,
        isOwn: false,
        body: 'from the first room',
      );

      expect(messageDocument(base).plainText, 'from the first room');
      expect(
        messageDocument(
          WeftMessage(
            eventId: r'$shared',
            roomId: '!two:example.org',
            network: ChatNetwork.matrix,
            senderId: '@a:example.org',
            senderName: 'A',
            timestamp: DateTime(2026, 8, 18, 9),
            kind: MessageKind.text,
            isOwn: false,
            body: 'from the second room',
          ),
        ).plainText,
        'from the second room',
      );
    });
  });

  /// The same assertions, one layer out: not what [RichTextView] does with a
  /// document, but what the *chat view* does with a message somebody sent it.
  ///
  /// Worth having separately because the parse is the security boundary and the
  /// bubble is the only caller in the app that reaches it from untrusted input.
  /// A regression that swapped `RichTextView.message` for a `Text(message.body)`
  /// would leave every test above passing.
  group('in a real bubble', () {
    late DemoChatRepository demo;

    /// Every url the app actually asked the platform to open.
    ///
    /// A mock handler rather than a fake `UrlLauncherPlatform`, and it is not
    /// optional: with nothing answering the channel, `launchUrl` never
    /// completes under `flutter test` — the launch neither succeeds nor throws,
    /// so "no snackbar" would be a passing assertion about a hung future rather
    /// than about a refusal.
    late List<String> launched;

    setUp(() {
      demo = DemoChatRepository(uploadTick: Duration.zero);
      launched = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
              if (call.method == 'launch') {
                launched.add((call.arguments as Map)['url']! as String);
              }
              return true;
            },
          );
    });

    tearDown(() {
      demo.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            null,
          );
    });

    Future<SeededChatRepository> pumpChat(
      WidgetTester tester, {
      required String body,
      String? formattedBody,
    }) async {
      final repository = SeededChatRepository(
        demo,
        messages: [
          seededMessage(
            eventId: r'$seeded1',
            body: body,
            formattedBody: formattedBody,
            minutesAgo: 2,
          ),
        ],
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
      return repository;
    }

    testWidgets('a formatted body arrives as text, not as markup', (
      tester,
    ) async {
      await pumpChat(
        tester,
        body: 'meet at six',
        formattedBody: 'meet at <b>six</b>',
      );

      expect(find.textContaining('meet at', findRichText: true), findsWidgets);
      expect(find.textContaining('<b>', findRichText: true), findsNothing);
    });

    testWidgets('copying a formatted message copies the words', (tester) async {
      // The clipboard gets the same projection the search index and the
      // notification bodies take. `<p>meet at <b>six</b></p>` pasted into
      // anything is not what the reader was looking at.
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await pumpChat(
        tester,
        body: 'meet at six',
        formattedBody: '<p>meet at <b>six</b></p>',
      );

      await tester.longPress(
        find.textContaining('meet at', findRichText: true).first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy text'));
      await tester.pumpAndSettle();

      expect(copied, 'meet at six');
    });

    testWidgets('a hostile formatted body is inert everywhere on the screen', (
      tester,
    ) async {
      await pumpChat(
        tester,
        body: 'Look at this click here',
        formattedBody:
            'Look at this <a href="javascript:alert(1)">click here</a>'
            '<script>alert(2)</script>',
      );

      // The words the sender wrote survive; the payload does not, and nothing
      // anywhere in the chat view would answer a tap as a link.
      expect(
        find.textContaining('click here', findRichText: true),
        findsWidgets,
      );
      expect(find.textContaining('alert', findRichText: true), findsNothing);
      expect(hasTappableSpan(tester), isFalse);
    });

    testWidgets('a link pretending to be another host asks before opening', (
      tester,
    ) async {
      // Well-formed HTML with a permitted scheme: the parser cannot refuse it
      // and is not supposed to. The confirmation is where a reader who was
      // shown one host and sent to another finds out.
      await pumpChat(
        tester,
        body: 'bank.example',
        formattedBody:
            '<a href="https://bank.example.evil.test/login">bank.example</a>',
      );

      await tapLink(tester, 'bank.example');
      expect(find.text('Open this link?'), findsOneWidget);
      expect(
        find.textContaining('bank.example.evil.test'),
        findsOneWidget,
        reason: 'the dialog has to show where the link actually goes',
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(launched, isEmpty);
    });

    testWidgets('confirming the same link does open it', (tester) async {
      // The other half of the question: a dialog that opened nothing whatever
      // the reader answered would pass the test above by doing nothing at all.
      await pumpChat(
        tester,
        body: 'bank.example',
        formattedBody:
            '<a href="https://bank.example.evil.test/login">bank.example</a>',
      );

      await tapLink(tester, 'bank.example');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(launched, ['https://bank.example.evil.test/login']);
    });

    testWidgets('an honest link opens without a question', (tester) async {
      // Asking about every link is how a confirmation stops working.
      await pumpChat(
        tester,
        body: 'the notes',
        formattedBody: '<a href="https://example.org/notes">the notes</a>',
      );

      await tapLink(tester, 'the notes');

      expect(find.text('Open this link?'), findsNothing);
      expect(launched, ['https://example.org/notes']);
    });
  });
}
