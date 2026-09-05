/// Matches the first line of a rich-reply fallback.
///
/// The shape is fixed by the spec: `> <@alice:example.org> …`, or
/// `> * <@alice:example.org> …` when the quoted message was an emote. Requiring
/// the angle-bracketed *user id* — not merely a leading `>` — is what keeps a
/// message that genuinely opens with a quotation from being eaten.
final RegExp _fallbackHeader = RegExp(r'^>\s\*?\s?<@[^>\s]+>');

/// Matches an `<mx-reply>` block, however it was cased or spaced.
final RegExp _mxReplyBlock = RegExp(
  r'<mx-reply\b[^>]*>.*?</mx-reply\s*>',
  caseSensitive: false,
  dotAll: true,
);

/// Removes the quoted-context fallback a rich reply carries.
///
/// Matrix replies duplicate their context: the body opens with the quoted
/// message as `>` lines and the formatted body wraps the same thing in
/// `<mx-reply>`, so that a client which knows nothing about replies still shows
/// the reader what is being answered. Weft renders a real reply chip from
/// `m.in_reply_to`, so leaving the fallback in place shows the quote twice —
/// once as a chip and once as literal `> <@alice:example.org> …` text at the
/// top of the bubble.
///
/// Handles both forms, because the same message carries both: the `<mx-reply>`
/// block is stripped wherever it appears, and the leading run of `>` lines is
/// stripped only when the *first* of them names a sender. A body that merely
/// opens with a quotation — `> to be or not to be` — is returned untouched.
///
/// Nested quotes come for free: when the quoted message was itself an unstripped
/// reply, its own fallback arrives as deeper `> > ` lines *within* the leading
/// run, and the whole run goes.
String stripReplyFallback(String body) {
  final withoutBlock = body.replaceAll(_mxReplyBlock, '');
  if (!_fallbackHeader.hasMatch(withoutBlock)) {
    // Nothing to strip textually — but the `<mx-reply>` removal may have left a
    // leading newline behind.
    return withoutBlock == body ? body : withoutBlock.trimLeft();
  }

  final lines = withoutBlock.split('\n');
  var index = 0;
  while (index < lines.length && lines[index].startsWith('>')) {
    index++;
  }
  // The spec puts a single blank line between the fallback and the reply.
  if (index < lines.length && lines[index].trim().isEmpty) {
    index++;
  }
  return lines.sublist(index).join('\n').trimLeft();
}

/// Whether [body] opens with a rich-reply fallback.
///
/// Exposed because the mapper needs to answer "was this already stripped?"
/// without paying for the strip, and because a body that *is* nothing but a
/// fallback is a distinguishable case from an empty body.
bool hasReplyFallback(String body) =>
    _fallbackHeader.hasMatch(body) || _mxReplyBlock.hasMatch(body);
