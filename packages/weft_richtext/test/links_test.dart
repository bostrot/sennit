import 'package:test/test.dart';
import 'package:weft_richtext/weft_richtext.dart';

/// Parses [html] the way a bubble does, so extraction is tested against the
/// document the renderer actually sees rather than one built by hand.
RichDocument _doc(String html, {String plain = ''}) =>
    parseFormattedBody(html, plain);

void main() {
  group('extractLinkUrls', () {
    test('finds an anchor the sender\'s client made', () {
      final urls = extractLinkUrls(
        _doc('<a href="https://example.org/a">the article</a>'),
      );
      expect(urls, ['https://example.org/a']);
    });

    test('finds a bare url in plain text, which is all a bridge sends', () {
      final urls = extractLinkUrls(
        parsePlainBody('have a look at https://example.org/a today'),
      );
      expect(urls, ['https://example.org/a']);
    });

    test('a bare url in plain text renders as a tappable link', () {
      final block =
          parsePlainBody(
                'have a look at https://example.org/a today',
              ).children.single
              as RichBlock;
      final link = block.children.whereType<RichLink>().single;
      expect(link.url, 'https://example.org/a');
      expect(block.children.first, const RichTextRun('have a look at '));
      expect(block.children.last, const RichTextRun(' today'));
    });

    test('trailing sentence punctuation stays out of the tappable link', () {
      final block =
          parsePlainBody('see https://example.org/a.').children.single
              as RichBlock;
      final link = block.children.whereType<RichLink>().single;
      expect(link.url, 'https://example.org/a');
      expect(block.children.last, const RichTextRun('.'));
    });

    test('keeps reading order and drops repeats', () {
      final urls = extractLinkUrls(
        _doc(
          '<a href="https://a.example/1">one</a> then '
          '<a href="https://b.example/2">two</a> then '
          '<a href="https://a.example/1">one again</a>',
        ),
      );
      expect(urls, ['https://a.example/1', 'https://b.example/2']);
    });

    test('reads an anchor href rather than its text', () {
      // The anchor text is a url too, and a scan that visited link children
      // would find the label as well as the destination. The href is the
      // honest one of the pair.
      final urls = extractLinkUrls(
        _doc('<a href="https://real.example/x">https://claimed.example/x</a>'),
      );
      expect(urls, ['https://real.example/x']);
    });

    test('skips a url inside inline code', () {
      final urls = extractLinkUrls(
        _doc('run <code>curl https://example.org/api</code>'),
      );
      expect(urls, isEmpty);
    });

    test('skips a url inside a code block', () {
      final urls = extractLinkUrls(
        _doc('<pre><code>GET https://example.org/api</code></pre>'),
      );
      expect(urls, isEmpty);
    });

    test('skips a link the sender put under a spoiler', () {
      // The card is drawn under the bubble and says the page's title, its
      // description and its host — so previewing a covered link publishes the
      // thing the cover exists to withhold, in the frame the message arrives,
      // without the reader tapping anything.
      final urls = extractLinkUrls(
        _doc(
          'the ending: <span data-mx-spoiler="">'
          '<a href="https://example.org/twist">here</a></span>',
        ),
      );
      expect(urls, isEmpty);
    });

    test('skips a bare url under a spoiler too', () {
      // A bridge sends no anchors, so this is the spelling that actually
      // arrives from one.
      final urls = extractLinkUrls(
        _doc('<span data-mx-spoiler="">read https://example.org/twist</span>'),
      );
      expect(urls, isEmpty);
    });

    test('a spoiler covers itself, not the rest of the message', () {
      final urls = extractLinkUrls(
        _doc(
          'the review is at https://example.org/review and the ending is '
          '<span data-mx-spoiler="">https://example.org/twist</span>',
        ),
      );
      expect(urls, ['https://example.org/review']);
    });

    test('still finds prose links in a message that also has code', () {
      final urls = extractLinkUrls(
        _doc(
          '<p>see https://example.org/docs</p>'
          '<pre><code>https://internal.example/secret</code></pre>',
        ),
      );
      expect(urls, ['https://example.org/docs']);
    });

    test('finds a bare url nested inside formatting', () {
      final urls = extractLinkUrls(
        _doc('<blockquote><b>https://example.org/deep</b></blockquote>'),
      );
      expect(urls, ['https://example.org/deep']);
    });

    test('a mention is never a preview candidate', () {
      // The parser has already turned the permalink into a RichMention, which
      // carries no url at all — so pinging someone cannot make the homeserver
      // fetch matrix.to.
      final urls = extractLinkUrls(
        parsePlainBody('https://matrix.to/#/@anna:example.org said so'),
      );
      expect(urls, isEmpty);
    });

    test('refuses every scheme that is not http or https', () {
      for (final href in [
        'mailto:anna@example.org',
        'matrix:u/anna:example.org',
        'javascript:alert(1)',
        'data:text/html,<b>x</b>',
        'file:///etc/passwd',
        'ftp://example.org/pub',
      ]) {
        expect(
          extractLinkUrls(_doc('<a href="$href">link</a>')),
          isEmpty,
          reason: '$href must not be previewable',
        );
      }
    });

    test('a refused href leaves no candidate even though its text renders', () {
      final document = _doc('<a href="javascript:alert(1)">click here</a>');
      // The parser keeps the words as an inert run — see parse_test — but there
      // is nothing here for the homeserver to be asked about.
      expect(document.plainText, contains('click here'));
      expect(extractLinkUrls(document), isEmpty);
    });

    test('a protocol-relative or relative url is not a candidate', () {
      expect(extractLinkUrls(_doc('<a href="//example.org/a">x</a>')), isEmpty);
      expect(extractLinkUrls(_doc('<a href="/local/path">x</a>')), isEmpty);
    });

    test('a url with no host is refused', () {
      expect(extractLinkUrls(_doc('<a href="https://">x</a>')), isEmpty);
    });
  });

  group('bare-url boundaries', () {
    List<String> found(String text) => extractLinkUrls(parsePlainBody(text));

    test('drops the full stop that ended the sentence', () {
      expect(found('read https://example.org/a.'), ['https://example.org/a']);
    });

    test('keeps a full stop that is part of the path', () {
      expect(found('read https://example.org/a.html'), [
        'https://example.org/a.html',
      ]);
    });

    test('keeps balanced brackets, drops an unmatched closer', () {
      expect(found('en.wikipedia.org aside: https://e.example/W_(weaving)'), [
        'https://e.example/W_(weaving)',
      ]);
      expect(found('(see https://example.org/a)'), ['https://example.org/a']);
    });

    test('stops at a quote and at a comma', () {
      expect(found('"https://example.org/a", he said'), [
        'https://example.org/a',
      ]);
    });

    test('stops at a zero-width character rather than swallowing it', () {
      // The General Punctuation block is where a url that reads as one host and
      // resolves to another hides; stopping there means the preview is asked
      // about the visible url or about nothing.
      expect(found('https://example.org/a​evil'), ['https://example.org/a']);
    });

    test('two urls on one line are two candidates', () {
      expect(found('https://a.example/1 and https://b.example/2'), [
        'https://a.example/1',
        'https://b.example/2',
      ]);
    });
  });

  group('firstPreviewableUrl', () {
    test('is the first, so a list of links is not a wall of cards', () {
      final url = firstPreviewableUrl(
        parsePlainBody('https://a.example/1 https://b.example/2'),
      );
      expect(url, 'https://a.example/1');
    });

    test('is null for a message with nothing to preview', () {
      expect(firstPreviewableUrl(parsePlainBody('no links here')), isNull);
    });
  });

  group('previewableUrl', () {
    test('passes an ordinary https url through unchanged', () {
      expect(previewableUrl('https://example.org/a'), 'https://example.org/a');
    });

    test('refuses null, empty and control characters', () {
      expect(previewableUrl(null), isNull);
      expect(previewableUrl(''), isNull);
      expect(previewableUrl('https://exa\nmple.org'), isNull);
    });

    test('refuses the schemes a rendered link is allowed to use', () {
      // Narrower than the render allowlist on purpose: mailto: and matrix: have
      // no page behind them, so asking would disclose an address for nothing.
      expect(previewableUrl('mailto:anna@example.org'), isNull);
      expect(previewableUrl('matrix:u/anna:example.org'), isNull);
    });
  });

  group('LinkPreview', () {
    test('reads the OpenGraph keys a homeserver answers with', () {
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:title': 'A title',
        'og:description': 'A description',
        'og:site_name': 'Example',
        'og:image': 'mxc://example.org/abc',
        'og:image:width': 800,
        'og:image:height': 400,
      });

      expect(preview.title, 'A title');
      expect(preview.description, 'A description');
      expect(preview.siteName, 'Example');
      expect(preview.imageUrl, 'mxc://example.org/abc');
      expect(preview.imageWidth, 800);
      expect(preview.imageHeight, 400);
      expect(preview.hasContent, isTrue);
    });

    test('an empty answer has nothing worth drawing a card around', () {
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {});
      expect(preview.hasContent, isFalse);
    });

    test('refuses a remote og:image, which is the tracking pixel', () {
      // The whole homeserver-proxied design is undone by a card that loads an
      // image straight from the site.
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:title': 'A title',
        'og:image': 'https://tracker.example/px.gif',
      });
      expect(preview.imageUrl, isNull);
      expect(preview.hasContent, isTrue);
    });

    test('collapses whitespace and control characters in a title', () {
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:title': '  A\n\ttitle​  with   gaps ',
      });
      expect(preview.title, 'A title with gaps');
    });

    test('a title of nothing but whitespace is no title', () {
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:title': '   \n\n  ',
      });
      expect(preview.title, isNull);
      expect(preview.hasContent, isFalse);
    });

    test('clamps a title that is longer than a title', () {
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:title': 'word ' * 200,
      });
      expect(preview.title!.length, lessThanOrEqualTo(141));
      expect(preview.title, endsWith('…'));
    });

    test('ignores a non-positive or unparseable image dimension', () {
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:title': 'x',
        'og:image:width': 0,
        'og:image:height': 'tall',
      });
      expect(preview.imageWidth, isNull);
      expect(preview.imageHeight, isNull);
    });

    test('reads a string dimension, which is what some servers send', () {
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:image:width': '640',
      });
      expect(preview.imageWidth, 640);
    });

    test('ignores keys nothing renders', () {
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:title': 'x',
        'og:video': 'https://example.org/v.mp4',
        'matrix:image:size': 12345,
      });
      expect(preview.toJson().keys, ['title']);
    });

    test('round-trips through json', () {
      final preview = LinkPreview.fromOpenGraph('https://example.org/a', {
        'og:title': 'A title',
        'og:description': 'A description',
        'og:site_name': 'Example',
        'og:image': 'mxc://example.org/abc',
        'og:image:width': 800,
        'og:image:height': 400,
      });
      final back = LinkPreview.fromJson(preview.url, preview.toJson());
      expect(back, preview);
      expect(back.hashCode, preview.hashCode);
    });

    test('cleans a cache row rather than trusting it', () {
      // A row written by a build with a wider clamp — or none — must not get a
      // free pass on the way back out, or the limits are advisory.
      final back = LinkPreview.fromJson('https://example.org/a', {
        'title': 'x' * 500,
        'image': 'https://tracker.example/px.gif',
      });
      expect(back.title!.length, lessThanOrEqualTo(141));
      expect(back.imageUrl, isNull);
    });

    test('host drops a leading www and lowercases', () {
      expect(
        const LinkPreview(url: 'https://WWW.Example.ORG/a').host,
        'example.org',
      );
    });

    test('host is null for a url with none', () {
      expect(const LinkPreview(url: 'not a url').host, isNull);
    });
  });

  group('preview_url answers', () {
    test('reads what tuwunel and Synapse return', () {
      // The shape of `GET /_matrix/client/v1/media/preview_url`: OpenGraph keys
      // as the page wrote them, the image already re-hosted as an mxc.
      final preview = LinkPreview.fromOpenGraph('https://github.com/a/b', {
        'og:title': 'GitHub - a/b: A thing',
        'og:description': 'A thing.\n\n  Contribute on GitHub.',
        'og:site_name': 'GitHub',
        'og:type': 'object',
        'og:url': 'https://github.com/a/b',
        'og:image': 'mxc://example.org/abcdef',
        'og:image:width': 1200,
        'og:image:height': '600',
        'og:image:type': 'image/png',
        'matrix:image:size': 41200,
      });

      expect(preview.title, 'GitHub - a/b: A thing');
      expect(preview.description, 'A thing. Contribute on GitHub.');
      expect(preview.siteName, 'GitHub');
      expect(preview.imageUrl, 'mxc://example.org/abcdef');
      expect(preview.imageWidth, 1200);
      expect(preview.imageHeight, 600);
      expect(preview.hasContent, isTrue);
    });

    test('an empty answer is no content', () {
      expect(
        LinkPreview.fromOpenGraph('https://a.example', {}).hasContent,
        isFalse,
      );
    });

    test('a long title is clamped on a word', () {
      final preview = LinkPreview.fromOpenGraph('https://a.example', {
        'og:title': List.filled(60, 'word').join(' '),
      });
      expect(preview.title!.length, lessThanOrEqualTo(141));
      expect(preview.title, endsWith('word…'));
    });

    test('survives a round trip through the cache', () {
      final preview = LinkPreview.fromOpenGraph('https://a.example', {
        'og:title': 'T',
        'og:image': 'mxc://example.org/x',
        'og:image:width': 10,
      });
      expect(
        LinkPreview.fromJson('https://a.example', preview.toJson()),
        preview,
      );
    });
  });

  group('previews the sender attached', () {
    Map<String, Object?> entry(String url, String title) => {
      'matched_url': url,
      'og:title': title,
    };

    test('reads a com.beeper.linkpreviews entry', () {
      final preview = LinkPreview.fromEmbedded({
        'matched_url': 'https://example.org/a',
        'og:title': 'A',
        'og:description': 'What WhatsApp showed',
        'og:image': 'mxc://bridge.example/img',
        'matrix:image:size': 3000,
      });
      expect(preview?.url, 'https://example.org/a');
      expect(preview?.title, 'A');
      expect(preview?.imageUrl, 'mxc://bridge.example/img');
    });

    test('drops an end-to-end encrypted image but keeps the words', () {
      final preview = LinkPreview.fromEmbedded({
        'matched_url': 'https://example.org/a',
        'og:title': 'A',
        'og:image': 'mxc://bridge.example/ciphertext',
        'beeper:image:encryption': {'url': 'mxc://bridge.example/ciphertext'},
      });
      expect(preview?.title, 'A');
      expect(preview?.imageUrl, isNull);
    });

    test('a remote image never survives', () {
      final preview = LinkPreview.fromEmbedded({
        'matched_url': 'https://example.org/a',
        'og:title': 'A',
        'og:image': 'https://tracker.example/px.gif',
      });
      expect(preview?.imageUrl, isNull);
    });

    test('falls back to og:url, then to the link in the body', () {
      expect(
        LinkPreview.fromEmbedded({
          'og:url': 'https://example.org/b',
          'og:title': 'B',
        })?.url,
        'https://example.org/b',
      );
      expect(
        LinkPreview.fromEmbedded({
          'og:title': 'C',
        }, fallbackUrl: 'https://example.org/c')?.url,
        'https://example.org/c',
      );
    });

    test('an entry naming an unsafe url is refused', () {
      expect(
        LinkPreview.fromEmbedded({
          'matched_url': 'javascript:alert(1)',
          'og:title': 'x',
        }),
        isNull,
      );
    });

    test('an entry with nothing to show is no preview', () {
      expect(
        LinkPreview.fromEmbedded({'matched_url': 'https://example.org/a'}),
        isNull,
      );
    });

    test('the entry for the first link wins', () {
      final preview = embeddedLinkPreview([
        entry('https://example.org/second', 'Second'),
        entry('https://example.org/first', 'First'),
      ], firstUrl: 'https://example.org/first');
      expect(preview?.title, 'First');
    });

    test('a bridge that rewrote the url still describes the link', () {
      final preview = embeddedLinkPreview([
        entry('https://example.org/a?utm_source=x', 'A'),
      ], firstUrl: 'https://example.org/a');
      expect(preview?.title, 'A');
    });

    test('an empty list is no preview', () {
      expect(embeddedLinkPreview(const []), isNull);
    });
  });
}
