import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'span.dart';

/// What a permalink points at, once it has been unpicked.
@immutable
class MentionTarget {
  const MentionTarget(this.id, this.kind);

  /// `@alice:example.org`, `#room:example.org`, `!abc:example.org`, or the
  /// literal `@room`.
  final String id;

  final MentionKind kind;

  @override
  bool operator ==(Object other) =>
      other is MentionTarget && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);

  @override
  String toString() => 'MentionTarget($id, $kind)';
}

/// Matches the two shapes a mention takes inside plain text.
///
/// A permalink written out in full (which is what a client that cannot make
/// pills sends, and what every bridge sends) and the bare `@room`. The
/// lookbehind keeps `foo@room` and an email local part from becoming a
/// room-wide ping, which would be a notification the sender never asked for.
final RegExp _mentionInText = RegExp(
  r'https?://matrix\.to/#/[^\s<>"]+'
  r'|matrix:(?:u|r|roomid)/[^\s<>"]+'
  r'|(?<![A-Za-z0-9_@.+-])@room\b',
);

/// Trailing punctuation that belongs to the sentence, not the permalink.
final RegExp _trailingPunctuation = RegExp(r'[.,;:!?)\]}>]+$');

/// Resolves a matrix.to permalink or a `matrix:` uri to what it names.
///
/// Returns null for anything else, including a matrix.to url with an empty or
/// unrecognised fragment — a link that does not name a user or a room is an
/// ordinary link and stays one.
MentionTarget? mentionTargetFromUrl(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url.trim());
  } on FormatException {
    return null;
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'matrix') return _fromMatrixUri(uri);
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.toLowerCase() != 'matrix.to') return null;

  // Ids are percent-encoded by well-behaved clients (`%40alice%3Aexample.org`)
  // and written raw by everyone else, so decode and accept both.
  final fragment = uri.fragment;
  final first = fragment
      .split('/')
      .where((part) => part.isNotEmpty)
      .firstOrNull;
  if (first == null) return null;

  final decoded = _decode(first).split('?').first;
  return _fromId(decoded);
}

/// Rewrites [document] so every permalink and every `@room` is a mention span.
///
/// [parseFormattedBody] already does this for anchors as it walks, so running
/// this over a parsed document is idempotent. It earns its keep on the *plain*
/// path — a body with no `formatted_body` at all, which is what most bridges
/// send — where a permalink arrives as bare text and would otherwise render as
/// a wall of url that the reader has to decode by eye.
RichDocument parseMentions(RichDocument document) =>
    RichDocument(_resolveSpans(document.children));

List<RichSpan> _resolveSpans(List<RichSpan> spans) {
  final out = <RichSpan>[];
  for (final span in spans) {
    switch (span) {
      case RichTextRun():
        out.addAll(_resolveTextRun(span));
      case RichLink():
        final target = mentionTargetFromUrl(span.url);
        if (target != null) {
          final display = span.plainText.trim();
          out.add(
            RichMention(
              targetId: target.id,
              display: display.isEmpty ? target.id : display,
              kind: target.kind,
            ),
          );
        } else {
          out.add(
            RichLink(
              url: span.url,
              children: _resolveSpans(span.children),
              inferred: span.inferred,
            ),
          );
        }
      case RichBlock():
        // Code blocks are text the sender wrote as code; a permalink inside one
        // is a sample, not a ping.
        if (span.kind == RichBlockKind.codeBlock) {
          out.add(span);
        } else {
          out.add(
            RichBlock(
              kind: span.kind,
              children: _resolveSpans(span.children),
              level: span.level,
              language: span.language,
              start: span.start,
            ),
          );
        }
      case RichMention() || RichLineBreak() || RichRule() || RichImage():
        out.add(span);
    }
  }
  return out;
}

List<RichSpan> _resolveTextRun(RichTextRun run) {
  if (run.style.code) return [run];

  final matches = _mentionInText.allMatches(run.text).toList();
  if (matches.isEmpty) return [run];

  final out = <RichSpan>[];
  var cursor = 0;
  for (final match in matches) {
    var text = match[0]!;
    var end = match.end;
    // `…/@alice:example.org.` — the full stop ends the sentence, not the id.
    final tail = _trailingPunctuation.firstMatch(text);
    if (tail != null && text != '@room') {
      end -= tail[0]!.length;
      text = text.substring(0, tail.start);
    }

    final target = text == '@room'
        ? const MentionTarget('@room', MentionKind.roomWide)
        : mentionTargetFromUrl(text);
    if (target == null) continue;

    if (match.start > cursor) {
      out.add(
        RichTextRun(run.text.substring(cursor, match.start), style: run.style),
      );
    }
    out.add(
      RichMention(
        targetId: target.id,
        display: target.kind == MentionKind.roomWide ? '@room' : target.id,
        kind: target.kind,
        style: run.style,
      ),
    );
    cursor = end;
  }

  if (out.isEmpty) return [run];
  if (cursor < run.text.length) {
    out.add(RichTextRun(run.text.substring(cursor), style: run.style));
  }
  return out;
}

MentionTarget? _fromMatrixUri(Uri uri) {
  final parts = uri.path.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return null;
  final id = _decode(parts[1]);
  if (id.isEmpty) return null;
  return switch (parts[0]) {
    'u' => MentionTarget('@$id', MentionKind.user),
    'r' => MentionTarget('#$id', MentionKind.roomAlias),
    'roomid' => MentionTarget('!$id', MentionKind.roomId),
    _ => null,
  };
}

MentionTarget? _fromId(String id) {
  if (id.length < 2) return null;
  return switch (id[0]) {
    '@' => MentionTarget(id, MentionKind.user),
    '#' => MentionTarget(id, MentionKind.roomAlias),
    '!' => MentionTarget(id, MentionKind.roomId),
    _ => null,
  };
}

String _decode(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    // A stray `%` in an id is not worth losing the mention over.
    return value;
  }
}
