import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

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
  });
}
