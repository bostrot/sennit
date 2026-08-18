import 'package:collection/collection.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'mentions.dart';
import 'span.dart';
import 'url_policy.dart';

/// Tags whose *content* is discarded along with the tag.
///
/// The difference between this set and everything else that is not permitted
/// matters. An unrecognised presentational tag — `<font>`, `<marquee>`, some
/// bridge's private wrapper — is unwrapped: the tag's meaning is dropped and
/// the text inside it survives, because that text is the message. These tags
/// are different: their content is not prose but a program, a stylesheet or a
/// nested document, and unwrapping `<script>alert(1)</script>` into the visible
/// body would show the reader source code the sender never meant them to read
/// and, worse, would make the payload survive into the search index.
const Set<String> _droppedSubtrees = {
  'applet',
  'area',
  'audio',
  'base',
  'button',
  'canvas',
  'dialog',
  'embed',
  'fieldset',
  'form',
  'frame',
  'frameset',
  'head',
  'iframe',
  'input',
  'legend',
  'link',
  'map',
  'math',
  'meta',
  'noscript',
  'object',
  'optgroup',
  'option',
  'param',
  'script',
  'select',
  'slot',
  'source',
  'style',
  'svg',
  'template',
  'textarea',
  'title',
  'track',
  'video',
  // Stripped here as well as in `stripReplyFallback`, so that a formatted body
  // parsed on its own never double-shows the quote.
  'mx-reply',
};

/// Parses a Matrix `formatted_body` into a document tree.
///
/// **This function is a security boundary.** Formatted bodies are untrusted:
/// they come from bridged networks, from clients Weft has never seen, and from
/// anyone who can get an event into a room. The defence is not a filter over
/// the output but the shape of the model — [RichSpan] has no field that can
/// hold an arbitrary attribute, so an `onerror=`, a `style=` or a `srcdoc=`
/// has nowhere to go even if the walk below overlooked it. On top of that:
///
/// * tags outside Matrix's permitted set are unwrapped, keeping their text;
/// * tags in [_droppedSubtrees] are removed with their contents;
/// * `href` goes through [sanitizeUrl], so no [RichLink] can ever carry a
///   `javascript:` or `data:` url — such an anchor becomes plain text;
/// * `<img src>` goes through [sanitizeMxcUrl], so a remote tracking pixel is
///   dropped rather than fetched when the timeline scrolls past it.
///
/// [plainBody] is the `body` field, and is the fallback: when [formattedBody]
/// is absent, or parses to nothing at all because everything in it was hostile,
/// the plain body is rendered instead. Rendering text as text is always safe,
/// and showing the reader *something* beats showing an empty bubble.
///
/// Tables and `<details>` are permitted by the spec but flattened to text here,
/// since the timeline has no renderer for them. That is lossy on purpose; a
/// half-invented table model nobody consumes would be worse.
RichDocument parseFormattedBody(String? formattedBody, String plainBody) {
  final source = formattedBody?.trim() ?? '';
  if (source.isEmpty) return parsePlainBody(plainBody);

  final dom.DocumentFragment fragment;
  try {
    fragment = html_parser.parseFragment(source);
  } on Exception {
    // html5 parsing is defined for every input, including unclosed and
    // malformed markup, so this is belt-and-braces — but a throw here would
    // take out the whole timeline for one bad event.
    return parsePlainBody(plainBody);
  }

  final spans = _normalise(
    _walkNodes(fragment.nodes, RichStyle.plain),
    trimEdges: true,
  );
  if (spans.isEmpty) return parsePlainBody(plainBody);
  return parseMentions(RichDocument(spans));
}

/// Wraps an unformatted body as a document, preserving its line breaks.
///
/// One paragraph rather than one per line: a plain body's blank lines are the
/// sender's own spacing, and re-deriving paragraphs from them would make
/// `\n\n` mean something structural that the sender never said.
RichDocument parsePlainBody(String plainBody) {
  if (plainBody.trim().isEmpty) return RichDocument.empty;

  final children = <RichSpan>[];
  final lines = plainBody.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) children.add(const RichLineBreak());
    if (lines[i].isNotEmpty) children.add(RichTextRun(lines[i]));
  }
  return parseMentions(
    RichDocument([
      RichBlock(kind: RichBlockKind.paragraph, children: children),
    ]),
  );
}

List<RichSpan> _walkNodes(List<dom.Node> nodes, RichStyle style) {
  final out = <RichSpan>[];
  for (final node in nodes) {
    out.addAll(_walkNode(node, style));
  }
  return out;
}

List<RichSpan> _walkNode(dom.Node node, RichStyle style) {
  if (node is dom.Text) {
    final text = _collapseWhitespace(node.data);
    return text.isEmpty ? const [] : [RichTextRun(text, style: style)];
  }
  if (node is! dom.Element) return const [];

  final tag = (node.localName ?? '').toLowerCase();
  if (_droppedSubtrees.contains(tag)) return const [];

  switch (tag) {
    case 'br':
      return const [RichLineBreak()];
    case 'hr':
      return const [RichRule()];

    case 'b':
    case 'strong':
      return _walkNodes(node.nodes, style.merge(bold: true));
    case 'i':
    case 'em':
      return _walkNodes(node.nodes, style.merge(italic: true));
    case 'u':
    case 'ins':
      return _walkNodes(node.nodes, style.merge(underline: true));
    case 's':
    case 'del':
    case 'strike':
      return _walkNodes(node.nodes, style.merge(strikethrough: true));
    case 'code':
      return _walkNodes(node.nodes, style.merge(code: true));

    case 'pre':
      return [_codeBlock(node)];
    case 'p':
    case 'div':
    case 'tr':
      return [_block(RichBlockKind.paragraph, node, style)];
    case 'blockquote':
      return [_block(RichBlockKind.blockquote, node, style)];
    case 'li':
      return [_block(RichBlockKind.listItem, node, style)];
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return [
        _block(
          RichBlockKind.heading,
          node,
          style,
          level: int.parse(tag.substring(1)),
        ),
      ];
    case 'ul':
      return [_list(node, style, ordered: false)];
    case 'ol':
      return [_list(node, style, ordered: true)];

    case 'a':
      return _anchor(node, style);
    case 'span':
      return _walkNodes(node.nodes, _spanStyle(node, style));
    case 'img':
      return _image(node);

    // Cells keep their text but lose their grid; a space stops two cells
    // running into one word.
    case 'td':
    case 'th':
      final cell = _walkNodes(node.nodes, style);
      return cell.isEmpty ? const [] : [...cell, const RichTextRun(' ')];

    default:
      // Permitted-but-unmodelled (`sup`, `sub`, `table`, `details`, `summary`,
      // `caption`) and anything unrecognised: unwrap, keeping the text.
      return _walkNodes(node.nodes, style);
  }
}

RichBlock _block(
  RichBlockKind kind,
  dom.Element element,
  RichStyle style, {
  int level = 0,
}) {
  return RichBlock(
    kind: kind,
    children: _normalise(_walkNodes(element.nodes, style), trimEdges: true),
    level: level,
  );
}

RichBlock _list(dom.Element element, RichStyle style, {required bool ordered}) {
  final items = <RichSpan>[];
  for (final span in _normalise(
    _walkNodes(element.nodes, style),
    trimEdges: true,
  )) {
    // Loose text directly inside a `<ul>` is malformed but common; give it an
    // item of its own rather than dropping the sender's words.
    if (span is RichBlock && span.kind == RichBlockKind.listItem) {
      items.add(span);
    } else {
      items.add(RichBlock(kind: RichBlockKind.listItem, children: [span]));
    }
  }
  return RichBlock(
    kind: ordered ? RichBlockKind.orderedList : RichBlockKind.bulletList,
    children: items,
    start: ordered ? _positiveInt(element.attributes['start']) ?? 1 : 1,
  );
}

RichBlock _codeBlock(dom.Element element) {
  final code = element.children.firstWhereOrNull(
    (child) => (child.localName ?? '').toLowerCase() == 'code',
  );
  final language = code == null ? null : _languageFromClass(code.className);
  final text = _verbatimText(element.nodes).replaceAll(RegExp(r'\n+$'), '');
  return RichBlock.codeBlock(text, language: language);
}

/// The text inside a `<pre>`, kept exactly as it was written.
///
/// Whitespace is content in a code block, so unlike the prose walk this does
/// not collapse it, and markup inside it is source the sender is quoting rather
/// than formatting to honour — a `<b>` in here is unwrapped without becoming
/// bold. What it does keep from the prose walk is [_droppedSubtrees]. The
/// obvious implementation, `element.text`, concatenates *every* descendant's
/// text and so would let `<pre><script>alert(1)</script></pre>` put the payload
/// straight into the bubble and the search index — through the one branch that
/// never asked the allowlist. A code block is where markup stops being honoured,
/// not where the allowlist stops applying.
String _verbatimText(List<dom.Node> nodes) {
  final buffer = StringBuffer();
  for (final node in nodes) {
    if (node is dom.Text) {
      buffer.write(node.data);
      continue;
    }
    if (node is! dom.Element) continue;
    final tag = (node.localName ?? '').toLowerCase();
    if (_droppedSubtrees.contains(tag)) continue;
    // Clients that build code blocks out of `<br>` rather than newlines are
    // rarer than the ones that don't, but joining their lines into one would
    // make the block unreadable.
    if (tag == 'br') {
      buffer.write('\n');
      continue;
    }
    buffer.write(_verbatimText(node.nodes));
  }
  return buffer.toString();
}

List<RichSpan> _anchor(dom.Element element, RichStyle style) {
  final children = _normalise(_walkNodes(element.nodes, style));
  final url = sanitizeUrl(element.attributes['href']);
  // A refused scheme costs the anchor its tap, not its text. Dropping the words
  // would hide what the sender wrote; keeping them un-tappable shows it and
  // makes it inert.
  if (url == null) return children;

  final target = mentionTargetFromUrl(url);
  if (target != null) {
    final display = joinPlainText(children).trim();
    return [
      RichMention(
        targetId: target.id,
        display: display.isEmpty ? target.id : display,
        kind: target.kind,
        style: style,
      ),
    ];
  }

  return [
    RichLink(
      url: url,
      children: children.isEmpty ? [RichTextRun(url, style: style)] : children,
    ),
  ];
}

List<RichSpan> _image(dom.Element element) {
  final src = sanitizeMxcUrl(element.attributes['src']);
  if (src == null) return const [];
  return [
    RichImage(
      src: src,
      alt: _collapseWhitespace(element.attributes['alt'] ?? '').trim(),
      width: _positiveInt(element.attributes['width']),
      height: _positiveInt(element.attributes['height']),
    ),
  ];
}

RichStyle _spanStyle(dom.Element element, RichStyle style) {
  // `data-mx-color` / `data-mx-bg-color` are permitted but not modelled: sender
  // -chosen colours are the one formatting instruction that can make text
  // unreadable against the reader's own theme, so Weft ignores them.
  return element.attributes.containsKey('data-mx-spoiler')
      ? style.merge(spoiler: true)
      : style;
}

/// Collapses HTML's insignificant whitespace.
///
/// Source indentation between tags is not content; without this a pretty
/// -printed formatted body renders with the sender's newlines and two-space
/// indents baked into the bubble.
String _collapseWhitespace(String text) => text.replaceAll(RegExp(r'\s+'), ' ');

/// Tidies a walked span list: merges adjacent runs of equal style, drops empty
/// runs and empty blocks, and removes the whitespace that only existed to
/// separate tags in the source.
List<RichSpan> _normalise(List<RichSpan> spans, {bool trimEdges = false}) {
  final merged = <RichSpan>[];
  for (final span in spans) {
    if (span is RichTextRun) {
      if (span.text.isEmpty) continue;
      final last = merged.lastOrNull;
      if (last is RichTextRun && last.style == span.style) {
        merged[merged.length - 1] = RichTextRun(
          last.text + span.text,
          style: last.style,
        );
        continue;
      }
    }
    if (span is RichBlock &&
        span.kind != RichBlockKind.codeBlock &&
        span.children.isEmpty) {
      continue;
    }
    merged.add(span);
  }

  final out = <RichSpan>[];
  for (var i = 0; i < merged.length; i++) {
    final span = merged[i];
    if (span is RichTextRun && span.text.trim().isEmpty) {
      final before = i == 0 ? null : merged[i - 1];
      final after = i == merged.length - 1 ? null : merged[i + 1];
      if (before == null || after == null) continue;
      if (before is RichBlock || after is RichBlock) continue;
    }
    out.add(span);
  }

  if (trimEdges && out.isNotEmpty) {
    final first = out.first;
    if (first is RichTextRun) {
      out[0] = RichTextRun(first.text.trimLeft(), style: first.style);
    }
    final last = out.last;
    if (last is RichTextRun) {
      out[out.length - 1] = RichTextRun(
        last.text.trimRight(),
        style: last.style,
      );
    }
    out.removeWhere((span) => span is RichTextRun && span.text.isEmpty);
  }

  return out;
}

/// Reads `language-dart` out of a `<code>` class list.
String? _languageFromClass(String className) {
  for (final name in className.split(RegExp(r'\s+'))) {
    if (name.startsWith('language-') && name.length > 'language-'.length) {
      return name.substring('language-'.length);
    }
  }
  return null;
}

int? _positiveInt(String? value) {
  if (value == null) return null;
  final parsed = int.tryParse(value.trim());
  return parsed != null && parsed > 0 ? parsed : null;
}
