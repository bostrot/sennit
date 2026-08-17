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
  return _mediaUrl(
    client,
    url,
    endpoint: 'thumbnail',
    authenticatedMedia: authenticatedMedia,
    query: {
      'width': '$size',
      'height': '$size',
      'method': 'crop',
      'animated': 'false',
    },
  );
}

/// Turns an `mxc://` URI into an HTTP URL for the media *itself*, full size.
///
/// The download counterpart of [mxcToThumbnailUrl], and it exists for exactly
/// one caller: saving or sharing a picture out of the viewer, where the file
/// the user asked for is the original and not a 96-pixel crop.
///
/// **Only ever correct for an unencrypted room.** The bytes behind an encrypted
/// attachment's mxc URI are ciphertext, and a client that fetched them would
/// write an unopenable file to the user's Downloads folder with no sign that
/// anything went wrong. Callers must check the room and fall back to
/// `downloadAndDecryptAttachment` instead — this function cannot see the room
/// and therefore cannot make that check for them.
String? mxcToDownloadUrl(
  sdk.Client client,
  String? url, {
  required bool authenticatedMedia,
}) {
  return _mediaUrl(
    client,
    url,
    endpoint: 'download',
    authenticatedMedia: authenticatedMedia,
  );
}

/// The shared half of both: parse the mxc URI, pick the endpoint generation,
/// and rebuild it against the homeserver this client is actually talking to.
String? _mediaUrl(
  sdk.Client client,
  String? url, {
  required String endpoint,
  required bool authenticatedMedia,
  Map<String, String>? query,
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
      ? '/_matrix/client/v1/media/$endpoint/$server/$mediaId'
      : '/_matrix/media/v3/$endpoint/$server/$mediaId';

  return Uri(
    scheme: homeserver.scheme,
    host: homeserver.host,
    port: homeserver.hasPort ? homeserver.port : null,
    path: path,
    queryParameters: query,
  ).toString();
}

/// Headers required by authenticated media endpoints.
Map<String, String>? mediaAuthHeaders(sdk.Client client) {
  final token = client.accessToken;
  if (token == null || token.isEmpty) return null;
  return {'authorization': 'Bearer $token'};
}
