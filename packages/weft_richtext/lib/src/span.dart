import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Inline attributes a run of text carries.
///
/// Flags rather than a style object with colours and sizes: everything here is
/// a *semantic* the sender expressed, and how bold or how monospaced it looks
/// is the renderer's business. Keeping it to booleans is also what lets the
/// parser merge nested tags — `<b><i>x</i></b>` is one run with two flags, not
/// two nested nodes for a renderer to unpick.
@immutable
class RichStyle {
  const RichStyle({
    this.bold = false,
    this.italic = false,
    this.strikethrough = false,
    this.underline = false,
    this.code = false,
    this.spoiler = false,
  });

  /// No attributes at all. The starting point of every walk.
  static const RichStyle plain = RichStyle();

  final bool bold;
  final bool italic;
  final bool strikethrough;
  final bool underline;

  /// Inline `<code>`, not a code block — see [RichBlockKind.codeBlock].
  final bool code;

  /// `data-mx-spoiler`: content the reader has to reveal deliberately.
  final bool spoiler;

  bool get isPlain => this == plain;

  /// Adds attributes without ever removing them.
  ///
  /// Union rather than override because HTML nesting only ever *adds* emphasis:
  /// there is no tag inside `<b>` that means "not bold", so a merge that could
  /// clear a flag would only ever be a bug.
  RichStyle merge({
    bool bold = false,
    bool italic = false,
    bool strikethrough = false,
    bool underline = false,
    bool code = false,
    bool spoiler = false,
  }) {
    return RichStyle(
      bold: this.bold || bold,
      italic: this.italic || italic,
      strikethrough: this.strikethrough || strikethrough,
      underline: this.underline || underline,
      code: this.code || code,
      spoiler: this.spoiler || spoiler,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RichStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.strikethrough == strikethrough &&
      other.underline == underline &&
      other.code == code &&
      other.spoiler == spoiler;

  @override
  int get hashCode =>
      Object.hash(bold, italic, strikethrough, underline, code, spoiler);

  @override
  String toString() {
    final flags = <String>[
      if (bold) 'bold',
      if (italic) 'italic',
      if (strikethrough) 'strike',
      if (underline) 'underline',
      if (code) 'code',
      if (spoiler) 'spoiler',
    ];
    return flags.isEmpty ? 'RichStyle.plain' : 'RichStyle(${flags.join('+')})';
  }
}

/// The block-level shapes the parser produces.
///
/// Deliberately short. Matrix permits tables and `<details>` too, but the
/// timeline has no table renderer and inventing one here would mean a model
/// nobody consumes; those tags are flattened into text by the parser instead,
/// which is lossy and documented rather than silent and structural.
enum RichBlockKind {
  paragraph,
  heading,
  blockquote,
  bulletList,
  orderedList,
  listItem,
  codeBlock,
}

/// One node of a parsed message body.
///
/// Pointedly *not* Flutter's `TextSpan`. Three consumers need this tree and
/// only one of them has a widget layer: the chat bubble renders it, the MCP
/// server serialises it, and notification bodies take its [plainText]
/// projection. A model that could only be built inside a `MaterialApp` would
/// force the other two to re-parse the HTML themselves — three allowlists to
/// keep in step instead of one.
@immutable
sealed class RichSpan {
  const RichSpan();

  /// What this node contributes to a plain-text rendering of the document.
  ///
  /// This is the projection that goes to the search index and to notification
  /// bodies, which is why it must never contain markup: a message formatted as
  /// `<b>fire</b>` has to be findable by "fire" and has to notify as "fire".
  String get plainText;
}

/// A run of text carrying [style].
final class RichTextRun extends RichSpan {
  const RichTextRun(this.text, {this.style = RichStyle.plain});

  final String text;
  final RichStyle style;

  @override
  String get plainText => text;

  @override
  bool operator ==(Object other) =>
      other is RichTextRun && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => 'RichTextRun(${_quote(text)}, $style)';
}

/// An explicit `<br>`.
final class RichLineBreak extends RichSpan {
  const RichLineBreak();

  @override
  String get plainText => '\n';

  @override
  bool operator ==(Object other) => other is RichLineBreak;

  @override
  int get hashCode => (RichLineBreak).hashCode;

  @override
  String toString() => 'RichLineBreak()';
}

/// An `<hr>`.
final class RichRule extends RichSpan {
  const RichRule();

  @override
  String get plainText => '\n';

  @override
  bool operator ==(Object other) => other is RichRule;

  @override
  int get hashCode => (RichRule).hashCode;

  @override
  String toString() => 'RichRule()';
}

/// An inline image — in practice a custom emoji or a sticker fragment.
///
/// [src] is always an `mxc://` URI: the parser drops any `<img>` pointing
/// somewhere else, because a remote `src` is a tracking pixel that fires the
/// moment the timeline scrolls past it, and the reader never chose to fetch it.
final class RichImage extends RichSpan {
  const RichImage({required this.src, this.alt = '', this.width, this.height});

  final String src;
  final String alt;
  final int? width;
  final int? height;

  @override
  String get plainText => alt;

  @override
  bool operator ==(Object other) =>
      other is RichImage &&
      other.src == src &&
      other.alt == alt &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(src, alt, width, height);

  @override
  String toString() => 'RichImage($src, alt: ${_quote(alt)})';
}

/// What a mention points at.
enum MentionKind {
  user,
  roomAlias,
  roomId,

  /// `@room` — everyone in this conversation. Has no id of its own, which is
  /// why it is a kind rather than a specially-shaped [RichMention.targetId].
  roomWide,
}

/// A mention, carrying the id it resolves to.
///
/// The id is the point. A renderer showing a pill needs somewhere to send a
/// tap, and the notification layer needs to know whether the local user was
/// named — neither can work backwards from the display text, because the
/// display text is whatever the sender's client happened to write.
final class RichMention extends RichSpan {
  const RichMention({
    required this.targetId,
    required this.display,
    required this.kind,
    this.style = RichStyle.plain,
  });

  /// `@alice:example.org`, `#room:example.org`, `!abc:example.org`, or the
  /// literal `@room` for [MentionKind.roomWide].
  final String targetId;

  /// What the sender wrote. Falls back to [targetId] when the sender wrote
  /// nothing better — a bare permalink in a plain body, for instance.
  final String display;

  final MentionKind kind;
  final RichStyle style;

  @override
  String get plainText => display;

  @override
  bool operator ==(Object other) =>
      other is RichMention &&
      other.targetId == targetId &&
      other.display == display &&
      other.kind == kind &&
      other.style == style;

  @override
  int get hashCode => Object.hash(targetId, display, kind, style);

  @override
  String toString() => 'RichMention($targetId, ${_quote(display)}, $kind)';
}

/// A hyperlink whose [url] has already passed the scheme allowlist.
///
/// The existence of this node is the guarantee: the parser never constructs one
/// for a `javascript:`, `data:` or otherwise unapproved href — such an anchor
/// is unwrapped to its text instead. A renderer can therefore make every
/// [RichLink] tappable without re-checking, and there is exactly one place in
/// the codebase where that check can be got wrong.
final class RichLink extends RichSpan {
  const RichLink({
    required this.url,
    required this.children,
    this.inferred = false,
  });

  final String url;
  final List<RichSpan> children;

  /// Whether [url] was worked out rather than written: a bare `example.org`
  /// given an `https://`, an address given a `mailto:`, a number a `tel:`.
  ///
  /// Tappable all the same, but never previewed. A sender who types a domain
  /// in passing is naming a site, not sharing a page, and asking the homeserver
  /// to fetch it would be a request nobody made.
  final bool inferred;

  @override
  String get plainText => children.map((c) => c.plainText).join();

  @override
  bool operator ==(Object other) =>
      other is RichLink &&
      other.url == url &&
      other.inferred == inferred &&
      const ListEquality<RichSpan>().equals(other.children, children);

  @override
  int get hashCode =>
      Object.hash(url, inferred, const ListEquality<RichSpan>().hash(children));

  @override
  String toString() =>
      'RichLink($url${inferred ? ', inferred' : ''}, $children)';
}

/// A block container: paragraph, heading, quote, list, list item, code block.
final class RichBlock extends RichSpan {
  const RichBlock({
    required this.kind,
    required this.children,
    this.level = 0,
    this.language,
    this.start = 1,
  });

  /// A `<pre>` block, whose content is text and stays text.
  factory RichBlock.codeBlock(String code, {String? language}) => RichBlock(
    kind: RichBlockKind.codeBlock,
    children: [RichTextRun(code)],
    language: language,
  );

  final RichBlockKind kind;
  final List<RichSpan> children;

  /// Heading level, 1–6. Zero for every other kind.
  final int level;

  /// Language hint off `<code class="language-dart">`, for code blocks only.
  final String? language;

  /// `<ol start>`, for ordered lists only.
  final int start;

  @override
  String get plainText => joinPlainText(children);

  @override
  bool operator ==(Object other) =>
      other is RichBlock &&
      other.kind == kind &&
      other.level == level &&
      other.language == language &&
      other.start == start &&
      const ListEquality<RichSpan>().equals(other.children, children);

  @override
  int get hashCode => Object.hash(
    kind,
    level,
    language,
    start,
    const ListEquality<RichSpan>().hash(children),
  );

  @override
  String toString() =>
      'RichBlock($kind${level > 0 ? ' h$level' : ''}, $children)';
}

/// A whole parsed message body.
@immutable
class RichDocument {
  const RichDocument(this.children);

  static const RichDocument empty = RichDocument(<RichSpan>[]);

  final List<RichSpan> children;

  bool get isEmpty => children.isEmpty;
  bool get isNotEmpty => children.isNotEmpty;

  /// The document as plain text, with block boundaries as newlines.
  ///
  /// The search index and notification bodies both take this rather than the
  /// raw formatted body, so that a message written as `<p>meet at <b>six</b></p>`
  /// is findable by "six" and notifies as "meet at six" — never as markup.
  String get plainText {
    final text = joinPlainText(children);
    // Blocks each contribute a separator and empty ones are common in bodies
    // pasted out of other clients; more than one blank line carries nothing.
    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Every mention in the tree, in document order.
  List<RichMention> get mentions {
    final found = <RichMention>[];
    void visit(List<RichSpan> spans) {
      for (final span in spans) {
        switch (span) {
          case RichMention():
            found.add(span);
          case RichLink():
            visit(span.children);
          case RichBlock():
            visit(span.children);
          case RichTextRun() || RichLineBreak() || RichRule() || RichImage():
            break;
        }
      }
    }

    visit(children);
    return found;
  }

  /// Every allowlisted link url in the tree, in document order.
  List<String> get linkUrls {
    final found = <String>[];
    void visit(List<RichSpan> spans) {
      for (final span in spans) {
        switch (span) {
          case RichLink():
            found.add(span.url);
            visit(span.children);
          case RichBlock():
            visit(span.children);
          case RichTextRun() ||
              RichLineBreak() ||
              RichRule() ||
              RichImage() ||
              RichMention():
            break;
        }
      }
    }

    visit(children);
    return found;
  }

  @override
  bool operator ==(Object other) =>
      other is RichDocument &&
      const ListEquality<RichSpan>().equals(other.children, children);

  @override
  int get hashCode => const ListEquality<RichSpan>().hash(children);

  @override
  String toString() => 'RichDocument($children)';
}

/// Concatenates [spans] as plain text, separating adjacent blocks with a
/// newline so that two paragraphs do not run into one word.
String joinPlainText(List<RichSpan> spans) {
  final buffer = StringBuffer();
  var previousWasBlock = false;
  for (final span in spans) {
    final isBlock = span is RichBlock;
    if ((isBlock || previousWasBlock) && buffer.isNotEmpty) {
      buffer.write('\n');
    }
    buffer.write(span.plainText);
    previousWasBlock = isBlock;
  }
  return buffer.toString();
}

String _quote(String text) =>
    "'${text.replaceAll('\n', r'\n').replaceAll("'", r"\'")}'";
