/// Matrix's rich content as values: parsed formatted bodies, stripped reply
/// fallbacks, resolved mentions, and the relations — reactions, edits, replies —
/// folded into what a bubble renders.
///
/// Pure Dart, and pointedly so. The formatted-body subset has more sharp edges
/// than its size suggests — untrusted HTML arriving from bridged networks,
/// reply fallbacks that must be removed or the quote shows twice, permalinks in
/// four spellings — and every one of them is a decision, not a platform call.
/// Testing those decisions against a widget tree would mean testing them badly.
///
/// The other reason is that the renderer is not the only consumer.
/// [RichDocument.plainText] is the projection the search index and the
/// notification layer take, so that a message written as `<b>fire</b>` is
/// findable by "fire" and notifies as "fire" rather than as markup. A model
/// that only existed inside a `MaterialApp` would force those two to re-parse
/// the HTML themselves, leaving three allowlists to keep in step instead of
/// one.
///
/// [parseFormattedBody] is a security boundary — see its doc comment for what
/// it guarantees and why the guarantee lives in the shape of [RichSpan] rather
/// than in a filter over the output.
library;

// Consumers import this barrel, never src/.
export 'src/bridge_buttons.dart';
export 'src/fallback.dart';
export 'src/links.dart';
export 'src/mentions.dart';
export 'src/parse.dart';
export 'src/relations.dart';
export 'src/span.dart';
export 'src/url_policy.dart';
