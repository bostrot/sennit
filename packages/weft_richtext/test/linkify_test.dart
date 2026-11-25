import 'package:test/test.dart';
import 'package:weft_richtext/weft_richtext.dart';

/// Every link in [document], as `(text, url)`, in reading order.
List<(String, String)> _links(RichDocument document) {
  final out = <(String, String)>[];
  void visit(List<RichSpan> spans) {
    for (final span in spans) {
      switch (span) {
        case RichLink():
          out.add((span.plainText, span.url));
        case RichBlock():
          visit(span.children);
        default:
          break;
      }
    }
  }

  visit(document.children);
  return out;
}

List<(String, String)> _plain(String text) => _links(parsePlainBody(text));

void main() {
  group('linkify', () {
    test('a url with a query string is one link', () {
      expect(
        _plain(
          'Verfolgen Sie ihr Paket: https://www.ups.com/track?tracknum=1Z01R3W86898843141',
        ),
        [
          (
            'https://www.ups.com/track?tracknum=1Z01R3W86898843141',
            'https://www.ups.com/track?tracknum=1Z01R3W86898843141',
          ),
        ],
      );
    });

    test('a domain without a scheme is tappable, as https', () {
      expect(_plain('see ups.com/track?n=1.'), [
        ('ups.com/track?n=1', 'https://ups.com/track?n=1'),
      ]);
      expect(_plain('or www.example.dev'), [
        ('www.example.dev', 'https://www.example.dev'),
      ]);
    });

    test('things that only look like a domain are not links', () {
      expect(
        _plain('open notes.txt, e.g. Sennit 1.0.27 or the plan.Then'),
        isEmpty,
      );
    });

    test('an e-mail address becomes a mailto link', () {
      expect(_plain('write to service@ups.com.'), [
        ('service@ups.com', 'mailto:service@ups.com'),
      ]);
    });

    test('a Matrix id is not an e-mail address', () {
      expect(_plain('ping @alice:example.org'), isEmpty);
    });

    test('phone numbers become tel links', () {
      expect(_plain('call +49 171 2345678 now'), [
        ('+49 171 2345678', 'tel:+491712345678'),
      ]);
      expect(_plain('Hotline (0221) 123-456.'), [
        ('(0221) 123-456', 'tel:0221123456'),
      ]);
      expect(_plain('US: 555-123-4567'), [('555-123-4567', 'tel:5551234567')]);
    });

    test('tracking numbers, postcodes and dates are not phone numbers', () {
      expect(
        _plain('Trackingnummer: 1Z01R3W86898843141, 50259 PULHEIM, 06/12/2026'),
        isEmpty,
      );
      expect(_plain('order 12345678'), isEmpty);
    });

    test('inferred links are never previewed', () {
      final document = parsePlainBody(
        'ups.com, service@ups.com, +49 171 2345678 and https://example.org/a',
      );
      expect(extractLinkUrls(document), ['https://example.org/a']);
    });

    test('a formatted body from a bridge gets its bare url linked', () {
      final document = parseFormattedBody(
        'Verfolgen Sie ihr Paket: https://www.ups.com/track?tracknum=1Z<br>'
            '<strong>Hotline +49 221 1234567</strong>',
        '',
      );
      expect(_links(document), [
        (
          'https://www.ups.com/track?tracknum=1Z',
          'https://www.ups.com/track?tracknum=1Z',
        ),
        ('+49 221 1234567', 'tel:+492211234567'),
      ]);
    });

    test('a formatted link keeps its anchor; code stays text', () {
      final document = parseFormattedBody(
        '<a href="https://a.example/">see https://b.example/</a> '
            '<code>curl https://c.example/</code>',
        '',
      );
      expect(_links(document), [
        ('see https://b.example/', 'https://a.example/'),
      ]);
    });

    test('a tel: anchor survives the allowlist', () {
      final document = parseFormattedBody(
        '<a href="tel:+4922112345">Call</a>',
        '',
      );
      expect(_links(document), [('Call', 'tel:+4922112345')]);
    });
  });

  group('trimming', () {
    test('leading and trailing blank lines are dropped from a plain body', () {
      final document = parsePlainBody(
        '\n\n  Ihre Sendung\n\nist unterwegs \n\n',
      );
      expect(document.plainText, 'Ihre Sendung\n\nist unterwegs');
    });

    test('leading and trailing breaks are dropped from a formatted body', () {
      final document = parseFormattedBody(
        '<br><br>Ihre Sendung<br><br>ist unterwegs<br>',
        '',
      );
      expect(document.plainText, 'Ihre Sendung\n\nist unterwegs');
    });
  });

  group('bridge buttons', () {
    const fallback =
        '\n\nIhre Sendung ist unterwegs.\n\n'
        '<UPS Access Point Abholung> - <An ursprüngliche Adresse> - <Abmelden>\n'
        'Use the WhatsApp app to click buttons';

    String html(String body) => body
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('\n', '<br>');

    test('quick replies come out of a plain body as buttons', () {
      final content = parseMessageContent(body: fallback);
      expect(content.document.plainText, 'Ihre Sendung ist unterwegs.');
      expect(content.buttons, const [
        BridgeButton(label: 'UPS Access Point Abholung'),
        BridgeButton(label: 'An ursprüngliche Adresse'),
        BridgeButton(label: 'Abmelden'),
      ]);
      expect(content.buttons.every((b) => b.answersInApp), isTrue);
    });

    test('and out of the formatted body the bridge actually sends', () {
      final content = parseMessageContent(
        body: fallback,
        formattedBody: html(fallback),
      );
      expect(content.document.plainText, 'Ihre Sendung ist unterwegs.');
      expect(content.buttons.map((b) => b.label), [
        'UPS Access Point Abholung',
        'An ursprüngliche Adresse',
        'Abmelden',
      ]);
    });

    test('link and call buttons keep where they go; a footer stays', () {
      const body =
          'Hallo\n\n<Ja> - Track - Call\n'
          'Use the WhatsApp app to click buttons\n\nUPS Footer';
      final content = parseMessageContent(
        body: body,
        formattedBody:
            'Hallo<br><br>&lt;Ja&gt; - <a href="https://ups.com/t">Track</a> - '
            '<a href="tel:+4922112345">Call</a><br>'
            'Use the WhatsApp app to click buttons<br><br>UPS Footer',
      );
      expect(content.buttons, const [
        BridgeButton(label: 'Ja'),
        BridgeButton(label: 'Track', url: 'https://ups.com/t'),
        BridgeButton(label: 'Call', url: 'tel:+4922112345'),
      ]);
      expect(content.document.plainText, 'Hallo\n\nUPS Footer');
    });

    test('a message that only quotes the sentence keeps it', () {
      const body = 'it said\nUse the WhatsApp app to click buttons';
      final content = parseMessageContent(body: body);
      expect(content.buttons, isEmpty);
      expect(content.document.plainText, body);
    });

    test('notifications and search do not see the stand-in', () {
      expect(plainMessageText(body: fallback), 'Ihre Sendung ist unterwegs.');
    });
  });
}
