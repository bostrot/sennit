import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';

void main() {
  group('text fallback', () {
    test('a single-line quote and its blank separator go', () {
      const body =
          '> <@alice:example.org> are we still on for six?\n\nyes, see you then';
      expect(stripReplyFallback(body), 'yes, see you then');
    });

    test('a multi-line quote goes entirely', () {
      const body =
          '> <@alice:example.org> line one\n'
          '> line two\n'
          '> line three\n'
          '\n'
          'the reply';
      expect(stripReplyFallback(body), 'the reply');
    });

    test('a nested quote goes with the run it belongs to', () {
      const body =
          '> <@alice:example.org> > <@bob:example.org> the original\n'
          '> > and its second line\n'
          '> what alice said back\n'
          '\n'
          'what i am saying now';
      expect(stripReplyFallback(body), 'what i am saying now');
    });

    test('an emote fallback is recognised', () {
      const body = '> * <@alice:example.org> waves\n\nhi back';
      expect(stripReplyFallback(body), 'hi back');
    });

    test('a missing blank separator still strips the quote', () {
      const body = '> <@alice:example.org> quoted\nreply on the next line';
      expect(stripReplyFallback(body), 'reply on the next line');
    });

    test('a reply that is only a fallback comes back empty', () {
      expect(stripReplyFallback('> <@alice:example.org> quoted\n'), '');
    });

    test('the reply keeps its own internal blank lines', () {
      const body = '> <@alice:example.org> q\n\nfirst\n\nsecond';
      expect(stripReplyFallback(body), 'first\n\nsecond');
    });

    test('a reply that itself starts with a quotation keeps it', () {
      const body = '> <@alice:example.org> q\n\n> nested quoting of my own';
      expect(stripReplyFallback(body), '> nested quoting of my own');
    });

    test('windows line endings do not save the fallback', () {
      // Some bridges relay CRLF verbatim; splitting on \n leaves a stray \r on
      // every line, and the blank separator becomes "\r" rather than "".
      const body = '> <@alice:example.org> quoted\r\n\r\nthe reply';
      expect(stripReplyFallback(body), 'the reply');
    });

    test('a user id carrying a port is still a fallback header', () {
      const body = '> <@alice:example.org:8448> quoted\n\nthe reply';
      expect(stripReplyFallback(body), 'the reply');
    });

    test('an emote fallback without the inner space is recognised', () {
      expect(stripReplyFallback('> *<@alice:example.org> waves\n\nhi'), 'hi');
    });
  });

  group('bodies that only look like fallbacks', () {
    test('a plain quotation is untouched', () {
      const body = '> to be or not to be\n\nis the question';
      expect(stripReplyFallback(body), body);
    });

    test('a quote naming a person without a user id is untouched', () {
      const body = '> <Alice> said something\n\nreply';
      expect(stripReplyFallback(body), body);
    });

    test('a body with no leading quote at all is untouched', () {
      const body = 'no quoting here\n> but a quote later';
      expect(stripReplyFallback(body), body);
    });

    test('an empty body is untouched', () {
      expect(stripReplyFallback(''), '');
    });

    test('markdown-style greater-than in prose is untouched', () {
      const body = '>5 people showed up';
      expect(stripReplyFallback(body), body);
    });
  });

  group('mx-reply block', () {
    test('the block and only the block is removed', () {
      const body =
          '<mx-reply><blockquote>quoted</blockquote></mx-reply>my answer';
      expect(stripReplyFallback(body), 'my answer');
    });

    test('casing and attributes on the tag do not save it', () {
      const body = '<MX-REPLY data-x="1"><p>q</p></MX-REPLY >answer';
      expect(stripReplyFallback(body), 'answer');
    });

    test('a block spanning newlines is removed', () {
      const body =
          '<mx-reply>\n  <blockquote>q</blockquote>\n</mx-reply>\nanswer';
      expect(stripReplyFallback(body), 'answer');
    });

    test('every block goes, not just the first', () {
      const body =
          '<mx-reply><p>a</p></mx-reply>mid<mx-reply><p>b</p></mx-reply>end';
      expect(stripReplyFallback(body), 'midend');
    });

    test('hostile content inside the block goes with it', () {
      const body = '<mx-reply><script>alert(1)</script></mx-reply>my answer';
      expect(stripReplyFallback(body), 'my answer');
      expect(stripReplyFallback(body), isNot(contains('alert')));
    });

    test('both forms in one body are both removed', () {
      // A rich reply carries the fallback twice, and a body that has had its
      // formatted half spliced in carries both at once.
      const body =
          '<mx-reply><blockquote>q</blockquote></mx-reply>'
          '> <@alice:example.org> q\n'
          '\n'
          'my answer';
      expect(stripReplyFallback(body), 'my answer');
    });
  });

  group('hasReplyFallback', () {
    test('detects both forms and rejects a plain quotation', () {
      expect(hasReplyFallback('> <@a:b.c> q\n\nr'), isTrue);
      expect(
        hasReplyFallback('<mx-reply><blockquote>q</blockquote></mx-reply>'),
        isTrue,
      );
      expect(hasReplyFallback('> just quoting'), isFalse);
      expect(hasReplyFallback('ordinary message'), isFalse);
      expect(hasReplyFallback(''), isFalse);
    });

    test('it agrees with stripReplyFallback on every body in this file', () {
      // The mapper uses it to skip the strip; the two disagreeing would mean
      // either a quote shown twice or a body silently truncated.
      const bodies = [
        '> <@alice:example.org> q\n\nreply',
        '> * <@alice:example.org> waves\n\nhi',
        '<mx-reply><blockquote>q</blockquote></mx-reply>answer',
        '> to be or not to be\n\nis the question',
        '> <Alice> said something\n\nreply',
        '>5 people showed up',
        'ordinary message',
        '',
      ];
      for (final body in bodies) {
        expect(
          hasReplyFallback(body),
          stripReplyFallback(body) != body,
          reason: body,
        );
      }
    });
  });
}
