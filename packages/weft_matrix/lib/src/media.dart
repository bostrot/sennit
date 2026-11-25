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

/// The same avatar as [url], asked for at [size] pixels and uncropped.
///
/// A chat's avatar is held as the 96-pixel square crop the lists draw, and
/// the original `mxc://` URI is gone by the time a screen sees it. Opening the
/// picture full screen needs more pixels than that, and the whole picture
/// rather than its middle: `scale` keeps the aspect ratio, `crop` does not.
///
/// A thumbnail rather than [mxcToDownloadUrl]'s original, because an avatar's
/// original can be a 4000-pixel photo straight off a camera, and a thumbnail
/// is still the homeserver's own media API, which is all Sennit Web's phone
/// will fetch for a browser.
///
/// Anything that is not a Matrix thumbnail URL comes back unchanged: there is
/// no larger version of it to ask for.
String largerThumbnailUrl(String url, {int size = 800}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final segments = uri.pathSegments;
  // `/_matrix/client/v1/media/thumbnail/…` or `/_matrix/media/v3/thumbnail/…`,
  // followed by the server and the media id.
  final at = segments.indexOf('thumbnail');
  if (at < 2 ||
      segments.first != '_matrix' ||
      !segments.take(at).contains('media') ||
      segments.length != at + 3) {
    return url;
  }
  return uri
      .replace(
        queryParameters: {
          ...uri.queryParameters,
          'width': '$size',
          'height': '$size',
          'method': 'scale',
        },
      )
      .toString();
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

/// Whether the attachment itself is a usable stand-in for a thumbnail the event
/// never carried.
///
/// The SDK answers a thumbnail request for an event with no thumbnail by
/// handing back the *attachment*. For a picture that is a sensible preview. For
/// a video it means downloading the whole film to give to `Image.memory`, which
/// cannot decode an MP4 — megabytes spent to arrive at a broken-image glyph, so
/// nothing is the better answer and the caller draws a poster instead.
///
/// Stickers are why this is more than "is it an `m.image`". WhatsApp, Signal and
/// Telegram all relay them as `m.sticker` with the picture inline and no
/// `thumbnail_url` beside it — there is nothing to make a preview of a
/// 512-pixel WebP *from*, and none of them bothers. Refusing the fallback for
/// those drew a broken-image glyph over every sticker in the timeline.
///
/// It still reads the mimetype because Telegram's animated stickers arrive as
/// `m.sticker` carrying `video/webm`, which is an MP4 by another name and fails
/// in exactly the way the video rule exists to prevent. A sticker that declares
/// no mimetype at all is allowed through: `info.mimetype` is optional on the
/// wire, near enough every sticker is a still image, and one that is not costs
/// a few hundred kilobytes to find out.
bool attachmentServesAsThumbnail({
  required String messageType,
  required String mimetype,
}) {
  final mime = mimetype.toLowerCase();
  return switch (messageType) {
    sdk.MessageTypes.Image => true,
    sdk.MessageTypes.Sticker => mime.isEmpty || mime.startsWith('image/'),
    _ => false,
  };
}
