import 'package:test/test.dart';
import 'package:weft_richtext/weft_richtext.dart';

/// Everything a renderer would show, as one string, so a test can assert on
/// what the reader ends up seeing without walking the tree by hand.
String visible(RichDocument document) => document.plainText;

/// Flattens the tree so a test can look for a node type anywhere in it.
List<RichSpan> flatten(List<RichSpan> spans) => [
  for (final span in spans)
    ...switch (span) {
      RichBlock() => [span, ...flatten(span.children)],
      RichLink() => [span, ...flatten(span.children)],
      _ => [span],
    },
];

void main() {
  group('plain bodies', () {
    test('an absent formatted body renders the plain body', () {
      final doc = parseFormattedBody(null, 'hello there');
      expect(visible(doc), 'hello there');
      expect(doc.children.single, isA<RichBlock>());
    });

    test(
      'an empty formatted body falls back rather than rendering nothing',
      () {
        expect(visible(parseFormattedBody('   ', 'hello')), 'hello');
      },
    );

    test('line breaks in a plain body survive', () {
      expect(visible(parseFormattedBody(null, 'one\ntwo')), 'one\ntwo');
    });

    test('an empty body is an empty document, not a blank paragraph', () {
      expect(parseFormattedBody(null, ''), RichDocument.empty);
    });
  });

  group('permitted tags', () {
    test('emphasis tags become style flags', () {
      RichStyle styleOf(String tag) {
        final doc = parseFormattedBody('<$tag>x</$tag>', 'x');
        return flatten(doc.children).whereType<RichTextRun>().single.style;
      }

      expect(styleOf('b'), const RichStyle(bold: true));
      expect(styleOf('strong'), const RichStyle(bold: true));
      expect(styleOf('i'), const RichStyle(italic: true));
      expect(styleOf('em'), const RichStyle(italic: true));
      expect(styleOf('u'), const RichStyle(underline: true));
      expect(styleOf('del'), const RichStyle(strikethrough: true));
      expect(styleOf('s'), const RichStyle(strikethrough: true));
      expect(styleOf('code'), const RichStyle(code: true));
    });

    test('adjacent runs of equal style merge into one', () {
      final doc = parseFormattedBody('<b>bo</b><strong>ld</strong>', 'bold');
      final run = flatten(doc.children).whereType<RichTextRun>().single;
      expect(run.text, 'bold');
      expect(run.style.bold, isTrue);
    });

    test('nested formatting merges into one run with both flags', () {
      final doc = parseFormattedBody('<b><i>both</i></b>', 'both');
      final run = flatten(doc.children).whereType<RichTextRun>().single;
      expect(run.text, 'both');
      expect(run.style.bold, isTrue);
      expect(run.style.italic, isTrue);
    });

    test('headings carry their level', () {
      final doc = parseFormattedBody('<h3>Title</h3>', 'Title');
      final block = doc.children.single as RichBlock;
      expect(block.kind, RichBlockKind.heading);
      expect(block.level, 3);
      expect(block.plainText, 'Title');
    });

    test('paragraphs are separated in the plain-text projection', () {
      final doc = parseFormattedBody('<p>one</p><p>two</p>', 'one\n\ntwo');
      expect(doc.children.length, 2);
      expect(visible(doc), 'one\ntwo');
    });

    test('blockquotes nest', () {
      final doc = parseFormattedBody(
        '<blockquote><blockquote>deep</blockquote></blockquote>',
        'deep',
      );
      final outer = doc.children.single as RichBlock;
      expect(outer.kind, RichBlockKind.blockquote);
      final inner = outer.children.single as RichBlock;
      expect(inner.kind, RichBlockKind.blockquote);
      expect(inner.plainText, 'deep');
    });

    test('lists keep their kind, items and ordered start', () {
      final doc = parseFormattedBody(
        '<ol start="3"><li>a</li><li>b</li></ol>',
        'a b',
      );
      final list = doc.children.single as RichBlock;
      expect(list.kind, RichBlockKind.orderedList);
      expect(list.start, 3);
      expect(list.children.length, 2);
      expect((list.children.first as RichBlock).kind, RichBlockKind.listItem);
    });

    test('an unordered list defaults to start 1 and bullet kind', () {
      final list =
          parseFormattedBody('<ul><li>a</li></ul>', 'a').children.single
              as RichBlock;
      expect(list.kind, RichBlockKind.bulletList);
      expect(list.start, 1);
    });

    test('pre keeps whitespace and reads its language off the code class', () {
      final doc = parseFormattedBody(
        '<pre><code class="language-dart">void main() {\n  a();\n}\n</code></pre>',
        'void main',
      );
      final block = doc.children.single as RichBlock;
      expect(block.kind, RichBlockKind.codeBlock);
      expect(block.language, 'dart');
      expect(block.plainText, 'void main() {\n  a();\n}');
    });

    test('br and hr become their own nodes', () {
      final doc = parseFormattedBody('a<br>b<hr>c', 'a b c');
      final kinds = flatten(doc.children).map((s) => s.runtimeType).toList();
      expect(kinds, contains(RichLineBreak));
      expect(kinds, contains(RichRule));
    });

    test('data-mx-spoiler marks the run as a spoiler', () {
      final doc = parseFormattedBody(
        '<span data-mx-spoiler>surprise</span>',
        'surprise',
      );
      final run = flatten(doc.children).whereType<RichTextRun>().single;
      expect(run.style.spoiler, isTrue);
    });

    test('an mxc image survives with its alt and size', () {
      final doc = parseFormattedBody(
        '<img src="mxc://example.org/abc" alt="wave" width="32" height="32">',
        '',
      );
      final image = flatten(doc.children).whereType<RichImage>().single;
      expect(image.src, 'mxc://example.org/abc');
      expect(image.alt, 'wave');
      expect(image.width, 32);
      expect(image.height, 32);
    });

    test('source indentation between tags is not rendered', () {
      final doc = parseFormattedBody(
        '<p>\n    one\n  </p>\n  <p>\n    two\n  </p>',
        'one two',
      );
      expect(visible(doc), 'one\ntwo');
    });

    test('tables are flattened to their text rather than dropped', () {
      final doc = parseFormattedBody(
        '<table><tr><td>a</td><td>b</td></tr></table>',
        'a b',
      );
      expect(visible(doc).replaceAll(RegExp(r'\s+'), ' ').trim(), 'a b');
    });

    test('unmodelled but permitted tags are unwrapped, keeping their text', () {
      final doc = parseFormattedBody(
        '<details><summary>more</summary><sup>2</sup></details>',
        'more 2',
      );
      expect(visible(doc), contains('more'));
      expect(visible(doc), contains('2'));
    });
  });

  group('links', () {
    test('an http link is tappable and keeps its text', () {
      final doc = parseFormattedBody(
        '<a href="https://example.org/x">click</a>',
        'click',
      );
      final link = flatten(doc.children).whereType<RichLink>().single;
      expect(link.url, 'https://example.org/x');
      expect(link.plainText, 'click');
    });

    test('mailto and matrix schemes are allowed', () {
      for (final url in const [
        'mailto:a@example.org',
        'matrix:r/room:example.org',
      ]) {
        expect(sanitizeUrl(url), url, reason: url);
      }
    });

    test('an empty anchor falls back to showing its url', () {
      final doc = parseFormattedBody('<a href="https://example.org"></a>', '');
      final link = flatten(doc.children).whereType<RichLink>().single;
      expect(link.plainText, 'https://example.org');
    });
  });

  group('malformed html', () {
    test('unclosed tags still produce the text', () {
      final doc = parseFormattedBody(
        '<b>bold <i>and italic',
        'bold and italic',
      );
      expect(visible(doc), 'bold and italic');
    });

    test('stray closing tags are ignored', () {
      expect(visible(parseFormattedBody('</p>text</b>', 'text')), 'text');
    });

    test('a bare angle bracket is text, not a tag', () {
      expect(visible(parseFormattedBody('3 < 4', '3 < 4')), '3 < 4');
    });

    test('entities are decoded once, not twice', () {
      expect(
        visible(parseFormattedBody('&lt;script&gt;', '<script>')),
        '<script>',
      );
    });
  });

  group('injection attempts', () {
    test('script content never reaches the document', () {
      final doc = parseFormattedBody(
        '<p>hi</p><script>alert(1)</script>',
        'hi',
      );
      expect(visible(doc), 'hi');
      expect(visible(doc), isNot(contains('alert')));
    });

    test('style content never reaches the document', () {
      final doc = parseFormattedBody(
        '<style>body{display:none}</style><p>hi</p>',
        'hi',
      );
      expect(visible(doc), 'hi');
    });

    test('a javascript: href is stripped of its tap but keeps its text', () {
      final doc = parseFormattedBody(
        '<a href="javascript:alert(1)">click me</a>',
        'click me',
      );
      expect(flatten(doc.children).whereType<RichLink>(), isEmpty);
      expect(visible(doc), 'click me');
      expect(doc.linkUrls, isEmpty);
    });

    test('scheme casing and padding do not smuggle javascript through', () {
      for (final href in const [
        'JaVaScRiPt:alert(1)',
        '  javascript:alert(1)',
        'java\tscript:alert(1)',
        'java\nscript:alert(1)',
        'jav ascript:alert(1)',
      ]) {
        expect(sanitizeUrl(href), isNull, reason: href);
      }
    });

    test('data and vbscript uris are refused', () {
      expect(sanitizeUrl('data:text/html;base64,PHNjcmlwdD4='), isNull);
      expect(sanitizeUrl('vbscript:msgbox(1)'), isNull);
      expect(sanitizeUrl('file:///etc/passwd'), isNull);
    });

    test('relative and protocol-relative urls are refused', () {
      expect(sanitizeUrl('/local/path'), isNull);
      expect(sanitizeUrl('//evil.example/x'), isNull);
      expect(sanitizeUrl('example.org/x'), isNull);
    });

    test('img with an onerror handler and a remote src is dropped whole', () {
      final doc = parseFormattedBody(
        '<img src="https://evil.example/x.png" onerror="alert(1)">after',
        'after',
      );
      expect(flatten(doc.children).whereType<RichImage>(), isEmpty);
      expect(visible(doc), 'after');
    });

    test('a data: image src is refused', () {
      expect(sanitizeMxcUrl('data:image/png;base64,iVBOR'), isNull);
      expect(sanitizeMxcUrl('mxc://'), isNull);
      expect(sanitizeMxcUrl('mxc://example.org/a'), 'mxc://example.org/a');
    });

    test('event handlers and style attributes have nowhere to land', () {
      final doc = parseFormattedBody(
        '<p onclick="alert(1)" style="position:fixed;top:0">text</p>',
        'text',
      );
      expect(visible(doc), 'text');
      expect(doc.toString(), isNot(contains('alert')));
      expect(doc.toString(), isNot(contains('position')));
    });

    test('an iframe and its srcdoc are dropped', () {
      final doc = parseFormattedBody(
        '<iframe srcdoc="<script>alert(1)</script>"></iframe><p>safe</p>',
        'safe',
      );
      expect(visible(doc), 'safe');
    });

    test('a wholly hostile body falls back to the plain body as text', () {
      final doc = parseFormattedBody(
        '<script>alert(1)</script>',
        'the real message',
      );
      expect(visible(doc), 'the real message');
    });

    test('an svg-wrapped script is dropped with its container', () {
      final doc = parseFormattedBody(
        '<svg><script>alert(1)</script></svg><p>hi</p>',
        'hi',
      );
      expect(visible(doc), 'hi');
    });

    test('a form and its inputs are dropped', () {
      final doc = parseFormattedBody(
        '<form action="https://evil.example"><input name="password"></form>ok',
        'ok',
      );
      expect(visible(doc), 'ok');
    });
  });

  group('mentions', () {
    test(
      'a matrix.to anchor becomes a user mention keeping its display name',
      () {
        final doc = parseFormattedBody(
          '<a href="https://matrix.to/#/@alice:example.org">Alice</a> hi',
          'Alice hi',
        );
        final mention = doc.mentions.single;
        expect(mention.targetId, '@alice:example.org');
        expect(mention.display, 'Alice');
        expect(mention.kind, MentionKind.user);
        expect(visible(doc), 'Alice hi');
      },
    );

    test('percent-encoded permalinks resolve', () {
      expect(
        mentionTargetFromUrl('https://matrix.to/#/%40alice%3Aexample.org'),
        const MentionTarget('@alice:example.org', MentionKind.user),
      );
    });

    test('room aliases, room ids and event permalinks resolve to the room', () {
      expect(
        mentionTargetFromUrl('https://matrix.to/#/#weft:example.org'),
        const MentionTarget('#weft:example.org', MentionKind.roomAlias),
      );
      expect(
        mentionTargetFromUrl(r'https://matrix.to/#/!abc:example.org/$evt'),
        const MentionTarget('!abc:example.org', MentionKind.roomId),
      );
    });

    test('matrix: uris resolve', () {
      expect(
        mentionTargetFromUrl('matrix:u/alice:example.org'),
        const MentionTarget('@alice:example.org', MentionKind.user),
      );
      expect(
        mentionTargetFromUrl('matrix:r/weft:example.org'),
        const MentionTarget('#weft:example.org', MentionKind.roomAlias),
      );
      expect(
        mentionTargetFromUrl('matrix:roomid/abc:example.org/e/xyz'),
        const MentionTarget('!abc:example.org', MentionKind.roomId),
      );
    });

    test('an ordinary link is not a mention', () {
      expect(mentionTargetFromUrl('https://example.org/@alice'), isNull);
      expect(mentionTargetFromUrl('https://matrix.to/'), isNull);
    });

    test('@room in a plain body becomes a room-wide mention', () {
      final doc = parseFormattedBody(null, 'heads up @room please');
      final mention = doc.mentions.single;
      expect(mention.kind, MentionKind.roomWide);
      expect(mention.targetId, '@room');
      expect(visible(doc), 'heads up @room please');
    });

    test('@room inside a longer token is not a ping', () {
      expect(
        parseFormattedBody(null, 'mail me at bob@room.example').mentions,
        isEmpty,
      );
      expect(parseFormattedBody(null, 'the @rooms list').mentions, isEmpty);
    });

    test('@room inside a code span is not a ping', () {
      final doc = parseFormattedBody('<code>@room</code>', '@room');
      expect(doc.mentions, isEmpty);
    });

    test(
      'a bare permalink in text becomes a mention without its full stop',
      () {
        final doc = parseFormattedBody(
          null,
          'ask https://matrix.to/#/@bob:example.org.',
        );
        expect(doc.mentions.single.targetId, '@bob:example.org');
        expect(visible(doc), endsWith('.'));
      },
    );

    test('parseMentions is idempotent over an already-parsed document', () {
      final once = parseFormattedBody(
        '<a href="https://matrix.to/#/@alice:example.org">Alice</a>',
        'Alice',
      );
      expect(parseMentions(once), once);
    });
  });

  group('plain-text projection', () {
    test('markup never survives into the projection', () {
      final doc = parseFormattedBody(
        '<p>meet at <b>six</b></p><blockquote>near the <i>bridge</i></blockquote>',
        'meet at six',
      );
      expect(visible(doc), 'meet at six\nnear the bridge');
      expect(visible(doc), isNot(contains('<')));
    });

    test('links contribute their text, not their url', () {
      final doc = parseFormattedBody(
        'see <a href="https://example.org/a/very/long">the docs</a>',
        'see the docs',
      );
      expect(visible(doc), 'see the docs');
      expect(doc.linkUrls, ['https://example.org/a/very/long']);
    });

    test('runs of blank lines collapse to one', () {
      final doc = parseFormattedBody(null, 'a\n\n\n\nb');
      expect(visible(doc), 'a\n\nb');
    });
  });

  group('RichStyle', () {
    test('merge only ever adds flags', () {
      const bold = RichStyle(bold: true);
      expect(
        bold.merge(italic: true),
        const RichStyle(bold: true, italic: true),
      );
      expect(bold.merge(), bold);
      expect(RichStyle.plain.isPlain, isTrue);
    });
  });
}
