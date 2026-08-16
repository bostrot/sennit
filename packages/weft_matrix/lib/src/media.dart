import 'package:matrix/matrix.dart' as sdk;

/// Turns an `mxc://` URI into an HTTP thumbnail URL the image widget can load.
///
/// Bridged contacts' avatars arrive as `mxc://server/mediaId`, which
/// `NetworkImage` cannot fetch — so every avatar rendered as initials even
/// when the bridge supplied a picture.
///
/// **Which endpoint is not a detail.** Matrix v1.11 moved media behind
/// authentication at `/_matrix/client/v1/media/...`; servers older than that
/// only serve `/_matrix/media/v3/...`. Guessing wrong 404s every avatar, which
/// looks exactly like having no avatar at all. [authenticatedMedia] must
/// therefore come from `client.authenticatedMediaSupported()`, resolved once
/// and reused.
///
/// Already-HTTP URLs pass through untouched; anything unparseable returns null
/// so the caller falls back to initials rather than a broken image.
String? mxcToThumbnailUrl(
  sdk.Client client,
  String? url, {
  required bool authenticatedMedia,
  int size = 96,
}) {
  if (url == null || url.isEmpty) return null;

  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.scheme == 'http' || uri.scheme == 'https') return url;
  if (uri.scheme != 'mxc' || uri.host.isEmpty || uri.pathSegments.isEmpty) {
    return null;
  }

  final homeserver = client.homeserver;
  if (homeserver == null) return null;

  final server = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  final mediaId = uri.pathSegments.first;

  final path = authenticatedMedia
      ? '/_matrix/client/v1/media/thumbnail/$server/$mediaId'
      : '/_matrix/media/v3/thumbnail/$server/$mediaId';

  return Uri(
    scheme: homeserver.scheme,
    host: homeserver.host,
    port: homeserver.hasPort ? homeserver.port : null,
    path: path,
    queryParameters: {
      'width': '$size',
      'height': '$size',
      'method': 'crop',
      'animated': 'false',
    },
  ).toString();
}

/// Headers required by authenticated media endpoints.
Map<String, String>? mediaAuthHeaders(sdk.Client client) {
  final token = client.accessToken;
  if (token == null || token.isEmpty) return null;
  return {'authorization': 'Bearer $token'};
}
