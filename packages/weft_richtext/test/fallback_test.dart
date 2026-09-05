import 'package:test/test.dart';
import 'package:weft_richtext/weft_richtext.dart';

/// The formatted half of a rich reply's fallback.
///
/// The text half — `> <@alice:example.org> …` — and its exhaustive cases moved
/// to `weft_domain` with the functions themselves, so that `weft_design` could
/// strip a fallback out of an inbox preview line without depending on an HTML
/// parser. What stays here is the half that needs one: `<mx-reply>` is removed
/// by the parser as well as by `stripReplyFallback`, and both have to hold or
/// the quote is rendered twice — once as Weft's own reply chip and once as the
/// blockquote inside the bubble.
void main() {
  test('the parser drops mx-reply, so a quote is never shown twice', () {
    final doc = parseFormattedBody(
      '<mx-reply><blockquote>quoted context</blockquote></mx-reply>my answer',
      'my answer',
    );
    expect(doc.plainText, 'my answer');
    expect(doc.plainText, isNot(contains('quoted context')));
  });

  test('the barrel still exports the strippers it used to own', () {
    // Every existing `package:weft_richtext/weft_richtext.dart` import of these
    // keeps working — see `src/fallback.dart`.
    expect(stripReplyFallback('> <@a:b.c> q\n\nanswer'), 'answer');
    expect(hasReplyFallback('> <@a:b.c> q\n\nanswer'), isTrue);
  });
}
