import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_richtext/weft_richtext.dart';

/// Asks the homeserver what is behind [url].
///
/// **The homeserver fetches the page, not the app.** That is the entire point
/// of routing through `/_matrix/media/v3/preview_url` (or its authenticated
/// successor, which the SDK picks between) instead of issuing an HTTP GET here.
/// A client that fetched the url itself would hand every site named in every
/// message the reader's IP address, their user agent, and the moment the
/// message arrived — from a request they never made, triggered by a link a
/// stranger chose to send them. A link in a message is a thing *received*, and
/// receiving it must not be an action visible to the sender's server.
///
/// The cost is stated rather than hidden: the homeserver learns which links the
/// user is being sent, including ones in end-to-end encrypted rooms whose
/// contents it otherwise never sees. That is why the whole feature is off until
/// switched on, and why the switch says so.
///
/// Never throws. A homeserver with previews disabled answers 404, one under
/// load answers 429, and one that dislikes the url answers 502 — none of which
/// is an error condition for a chat bubble. Every one of them is "no card",
/// which is the same outcome as a page with no OpenGraph tags.
Future<LinkPreview?> fetchLinkPreview(sdk.Client client, Uri url) async {
  final safe = previewableUrl(url.toString());
  // Belt and braces: the caller has already been through the gate, and a
  // scheme that got past it must not reach the homeserver from here either.
  if (safe == null) return null;

  try {
    final response = await client.getUrlPreview(Uri.parse(safe));
    final preview = LinkPreview.fromOpenGraph(safe, response.toJson());
    return preview.hasContent ? preview : null;
  } on Object catch (_) {
    // Deliberately Object: the SDK throws `MatrixException` for a refusal but
    // the transport under it can fail with an Error, and a link that cannot be
    // previewed must never take a timeline down with it.
    return null;
  }
}

/// [fetchLinkPreview] bound to [client], in the shape the app's preview
/// service takes.
///
/// The service holds a [LinkPreviewFetch] rather than a `Client` so that the
/// gate, the cache and the in-flight bookkeeping can all be tested with a
/// function that returns fixtures — and so demo mode can pass nothing at all
/// and get an app whose cards are simply absent.
LinkPreviewFetch homeserverLinkPreviews(sdk.Client client) =>
    (url) => fetchLinkPreview(client, url);
