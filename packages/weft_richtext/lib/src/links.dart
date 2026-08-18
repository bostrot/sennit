import 'package:meta/meta.dart';

import 'span.dart';
import 'url_policy.dart';

/// Schemes a link *preview* may be asked for.
///
/// Narrower than [allowedUrlSchemes], and for a different reason. That set is
/// about what a reader may be sent to; this one is about what a homeserver can
/// be asked to fetch on their behalf. `mailto:` and `matrix:` have no page
/// behind them, so asking for a preview of one is a request that can only
/// answer nothing — after telling the homeserver an address the user was
/// written to.
const Set<String> previewableUrlSchemes = {'http', 'https'};

/// A bare url inside a run of plain text.
///
/// Deliberately greedy up to whitespace and the characters that end a url in
/// prose, with the trailing punctuation trimmed afterwards by
/// [_trimTrailingPunctuation] rather than excluded here — `example.org/a.` is a
/// sentence ending in a link, but `example.org/a.html` is not, and a regex
/// cannot tell the two apart without knowing where the sentence stops.
final RegExp _bareUrl = RegExp(
  // Stops at whitespace, at the characters that quote a url in prose, and at
  // General Punctuation — the block the zero-width and bidi characters live in,
  // which is where a url that reads as one host and resolves to another hides.
  r'https?://[^\s<>"'
  "'"
  r'`\u2000-\u206f]+',
  caseSensitive: false,
);

/// Punctuation a url in prose collects on its way out of a sentence.
const String _trailingPunctuation = '.,;:!?\'"\u00bb\u203a)]}';

/// Every previewable url in [document], in reading order, without repeats.
///
/// Both spellings are collected: an `<a href>` the sender's client made, and a
/// bare url sitting in the text — which is all a bridge ever sends, since
/// WhatsApp and Signal have no anchors to bridge.
///
/// **Two things are deliberately skipped.** Code — inline `<code>` and whole
/// `<pre>` blocks — because a url inside a code sample is being *quoted*, not
/// shared, and asking the homeserver to fetch it turns a snippet the sender
/// pasted into a request the reader never made. And a link's own anchor text,
/// which is usually the url again: scanning it would find the same address
/// twice by two routes, and the anchor's `href` is the honest one of the pair.
///
/// Mentions never appear here at all — the parser has already turned
/// `matrix.to` permalinks into [RichMention], which carries no url.
List<String> extractLinkUrls(RichDocument document) {
  final found = <String>[];
  final seen = <String>{};

  void add(String? url) {
    final safe = previewableUrl(url);
    if (safe == null || !seen.add(safe)) return;
    found.add(safe);
  }

  void visit(List<RichSpan> spans) {
    for (final span in spans) {
      switch (span) {
        case RichLink():
          add(span.url);
        // Children deliberately not visited: see the doc comment.
        case RichTextRun():
          if (span.style.code) break;
          for (final match in _bareUrl.allMatches(span.text)) {
            add(_trimTrailingPunctuation(match.group(0)!));
          }
        case RichBlock():
          if (span.kind == RichBlockKind.codeBlock) break;
          visit(span.children);
        case RichLineBreak() || RichRule() || RichImage() || RichMention():
          break;
      }
    }
  }

  visit(document.children);
  return found;
}

/// The one url a bubble shows a card for, or null when it has none.
///
/// One rather than all of them, and the first rather than the best. A message
/// carrying five links is a list, and five cards under it is a wall that buries
/// the words the sender actually wrote; picking the first is the only choice
/// that does not need the app to have an opinion about which link matters,
/// which it has no way to hold.
String? firstPreviewableUrl(RichDocument document) {
  final urls = extractLinkUrls(document);
  return urls.isEmpty ? null : urls.first;
}

/// Returns [url] if a preview may be requested for it, or null.
///
/// Runs the same [sanitizeUrl] gate every rendered link goes through — control
/// characters, relative urls, the scheme allowlist — and then narrows to the
/// two schemes that have a page behind them. A url that reaches here has been
/// through the security boundary twice, which is the intent: the preview path
/// is the one place in the app that sends something a stranger wrote to a
/// server on the user's behalf.
String? previewableUrl(String? url) {
  final safe = sanitizeUrl(url);
  if (safe == null) return null;

  final uri = Uri.tryParse(safe);
  if (uri == null || uri.host.isEmpty) return null;
  if (!previewableUrlSchemes.contains(uri.scheme.toLowerCase())) return null;
  return safe;
}

/// Drops the punctuation a url picked up from the sentence around it.
///
/// A closing bracket is only dropped when the url has no matching opener, so
/// `en.wikipedia.org/wiki/Weft_(weaving)` survives while `(see example.org)`
/// does not keep its bracket.
String _trimTrailingPunctuation(String url) {
  var end = url.length;
  while (end > 0) {
    final char = url[end - 1];
    if (!_trailingPunctuation.contains(char)) break;
    if (char == ')' &&
        _countOf(url.substring(0, end), '(') >=
            _countOf(url.substring(0, end), ')')) {
      break;
    }
    end--;
  }
  return url.substring(0, end);
}

int _countOf(String haystack, String needle) =>
    needle.allMatches(haystack).length;

/// What a homeserver knows about a link, as the card renders it.
///
/// Every field is *content from a page the sender chose*, which is the whole
/// reason this type exists rather than a raw map. It arrives having passed
/// through a stranger's web server and the user's homeserver, so it is cleaned
/// on the way in and again on the way out of the cache: whitespace collapsed,
/// control characters dropped, lengths clamped, and the image restricted to an
/// `mxc://` uri the homeserver is holding. A title that is four thousand
/// characters of newlines is not a title, and an `og:image` pointing at
/// `https://tracker.example/px.gif` is the tracking pixel the whole
/// homeserver-proxied design exists to avoid.
///
/// Nothing here is ever markup. The strings are rendered as text and must never
/// be handed to [parseFormattedBody] or to anything else that would read tags
/// in them — a preview is not a message body and has no formatting to express.
@immutable
class LinkPreview {
  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.siteName,
    this.imageUrl,
    this.imageWidth,
    this.imageHeight,
  });

  /// Builds a preview from the homeserver's `preview_url` answer.
  ///
  /// [og] is the response body as it arrives — OpenGraph keys plus whatever
  /// else the server chose to include. Unknown keys are ignored rather than
  /// carried: a value nothing renders is a value nothing has checked.
  factory LinkPreview.fromOpenGraph(String url, Map<String, Object?> og) {
    return LinkPreview(
      url: url,
      title: _clean(og['og:title'], max: _titleMax),
      description: _clean(og['og:description'], max: _descriptionMax),
      siteName: _clean(og['og:site_name'], max: _siteNameMax),
      imageUrl: sanitizeMxcUrl(_asString(og['og:image'])),
      imageWidth: _positiveInt(og['og:image:width']),
      imageHeight: _positiveInt(og['og:image:height']),
    );
  }

  /// Reads a preview back out of the cache.
  ///
  /// Runs the same cleaning as [LinkPreview.fromOpenGraph] rather than trusting
  /// the row: the cache is a file on disk that a build with a wider clamp — or
  /// with none — may have written, and a bypass here would make the limits
  /// above advisory.
  factory LinkPreview.fromJson(String url, Map<String, Object?> json) {
    return LinkPreview(
      url: url,
      title: _clean(json['title'], max: _titleMax),
      description: _clean(json['description'], max: _descriptionMax),
      siteName: _clean(json['site_name'], max: _siteNameMax),
      imageUrl: sanitizeMxcUrl(_asString(json['image'])),
      imageWidth: _positiveInt(json['image_width']),
      imageHeight: _positiveInt(json['image_height']),
    );
  }

  /// The url this describes, exactly as [previewableUrl] returned it.
  final String url;

  final String? title;
  final String? description;
  final String? siteName;

  /// `mxc://` uri of the preview image, already fetched and re-hosted by the
  /// homeserver. Never an `http` url — see the class doc.
  final String? imageUrl;

  final int? imageWidth;
  final int? imageHeight;

  /// Whether there is anything worth drawing a card around.
  ///
  /// A homeserver answers `{}` for a page with no OpenGraph tags at all, and a
  /// card carrying nothing but the url the reader can already see is noise
  /// under every bubble.
  bool get hasContent =>
      title != null || description != null || imageUrl != null;

  /// The host, for the card's footer line. Null only for a url that somehow got
  /// past [previewableUrl], which cannot happen through the normal path.
  String? get host {
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return null;
    return host.toLowerCase().startsWith('www.') ? host.substring(4) : host;
  }

  Map<String, Object?> toJson() => {
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (siteName != null) 'site_name': siteName,
    if (imageUrl != null) 'image': imageUrl,
    if (imageWidth != null) 'image_width': imageWidth,
    if (imageHeight != null) 'image_height': imageHeight,
  };

  @override
  bool operator ==(Object other) =>
      other is LinkPreview &&
      other.url == url &&
      other.title == title &&
      other.description == description &&
      other.siteName == siteName &&
      other.imageUrl == imageUrl &&
      other.imageWidth == imageWidth &&
      other.imageHeight == imageHeight;

  @override
  int get hashCode => Object.hash(
    url,
    title,
    description,
    siteName,
    imageUrl,
    imageWidth,
    imageHeight,
  );

  @override
  String toString() => 'LinkPreview($url, ${title ?? '—'})';
}

/// Asks something for a preview of [url].
///
/// A typedef rather than an interface, for the same reason
/// `MergedIdentityResolver` is one: the only implementation that matters talks
/// to a Matrix homeserver, and this package must not depend on the one that
/// knows how. The app passes the homeserver in; a test passes a function.
///
/// Returning null is the ordinary answer for "no preview" — the server had
/// nothing, the request failed, the page has no tags. Implementations must not
/// throw: a link in a message is not an error condition.
typedef LinkPreviewFetch = Future<LinkPreview?> Function(Uri url);

const int _titleMax = 140;
const int _descriptionMax = 300;
const int _siteNameMax = 60;

/// Control characters and every flavour of whitespace, collapsed to one space.
final RegExp _whitespaceRun = RegExp(
  r'[\s\u0000-\u001f\u007f\u200b-\u200f\u2028\u2029\u202a-\u202e\ufeff]+',
);

String? _asString(Object? value) => value is String ? value : null;

/// One untrusted string, made safe to put in a `Text`.
String? _clean(Object? value, {required int max}) {
  final raw = _asString(value);
  if (raw == null) return null;

  final collapsed = raw.replaceAll(_whitespaceRun, ' ').trim();
  if (collapsed.isEmpty) return null;
  if (collapsed.length <= max) return collapsed;
  // Cut on the ellipsis rather than mid-word where there is a space to cut on,
  // so a clamped title reads as shortened rather than as corrupt.
  final cut = collapsed.substring(0, max);
  final space = cut.lastIndexOf(' ');
  return '${space > max ~/ 2 ? cut.substring(0, space) : cut}…';
}

int? _positiveInt(Object? value) {
  final number = switch (value) {
    final int i => i,
    final String s => int.tryParse(s),
    _ => null,
  };
  return number != null && number > 0 ? number : null;
}
