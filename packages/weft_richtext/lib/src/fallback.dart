/// The rich-reply fallback strippers, which now live in `weft_domain`.
///
/// They moved because a second consumer appeared that cannot depend on this
/// package: `weft_design`'s `ChatTile` builds the inbox preview line, and until
/// it could strip a fallback the conversation list rendered replies as
/// `> <@signal_1234:beeper.local> …` — the quoted mxid, in the row, where the
/// answer should have been. A design system has no business depending on an
/// HTML parser, and `weft_domain` is the package both already share.
///
/// Re-exported rather than left behind as a copy: `stripReplyFallback` is a
/// small function with a large number of cases, and two of it would drift
/// within a release. Every existing `package:weft_richtext/weft_richtext.dart`
/// import keeps working.
library;

export 'package:weft_domain/weft_domain.dart'
    show hasReplyFallback, stripReplyFallback;
