import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

// Brings `Uint8List`, `@immutable` and `compute` in one import; the analyzer
// flags `dart:typed_data` and `package:meta` alongside it as redundant.
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_attachments/weft_attachments.dart';

import 'api_session.dart';

/// Matrix's media upload endpoint.
///
/// Unchanged by the v1.11 authenticated-media work, which moved *downloads* to
/// `/_matrix/client/v1/media/...` and left uploads exactly where they were.
const String kMatrixUploadPath = '_matrix/media/v3/upload';

/// How much is written to the socket between progress callbacks.
///
/// 64 KiB is small enough that a photo on a domestic upstream reports a dozen
/// times on its way up, and large enough that a 200 MB video does not spend its
/// life in callback overhead.
const int kUploadChunkBytes = 64 * 1024;

/// Quality of a generated thumbnail.
///
/// 80 is where JPEG stops being visibly lossy at preview size; the difference
/// between 80 and 95 is invisible in a bubble and roughly doubles the second
/// upload.
const int kThumbnailJpegQuality = 80;

/// Encrypts one attachment, returning the ciphertext and its key material.
///
/// Injected so tests do not have to bring up vodozemac: the SDK's [sdk.encryptFile]
/// is AES-CTR in Rust behind FFI, which a `flutter test` process has no
/// initialised binding for. Production always uses the SDK's own helper — Weft
/// hand-rolls no attachment crypto.
typedef AttachmentEncryptor =
    Future<sdk.EncryptedFile> Function(Uint8List plaintext);

/// Scales [bytes] down to fit [spec], or returns null when they cannot be
/// decoded as an image at all.
typedef ThumbnailRasteriser =
    Future<RasterisedThumbnail?> Function(Uint8List bytes, ThumbnailSpec spec);

/// A generated preview: the JPEG bytes and the size they actually came out at.
///
/// The *actual* size matters and is not the spec's. `ThumbnailSpec` falls back
/// to an 800x800 bounding box whenever the header slice could not be probed, and
/// writing that square into `thumbnail_info` when the real preview is 800x450
/// makes every receiving client lay out a gap and then reflow it.
@immutable
class RasterisedThumbnail {
  const RasterisedThumbnail({required this.bytes, required this.dimensions});

  final Uint8List bytes;
  final MediaDimensions dimensions;

  @override
  String toString() =>
      'RasterisedThumbnail($dimensions, ${bytes.length} bytes)';
}

/// Everything `UploadPlan.toEventContent` needs about a thumbnail that has
/// already been uploaded.
///
/// [file] is non-null exactly when the room is encrypted, mirroring the rule the
/// attachment itself follows — a plain preview beside an encrypted attachment is
/// the one mistake in this area that actually leaks.
@immutable
class MatrixThumbnailUpload {
  const MatrixThumbnailUpload({
    required this.uri,
    required this.sizeBytes,
    required this.dimensions,
    this.file,
  });

  /// The `mxc://` URI of the second upload.
  final String uri;

  final EncryptedFileInfo? file;

  /// Size of the uploaded preview, for `thumbnail_info.size`.
  final int sizeBytes;

  /// What the preview actually came out at, for `thumbnail_info.w`/`h`.
  final MediaDimensions dimensions;

  @override
  String toString() => 'MatrixThumbnailUpload($uri, $dimensions)';
}

/// Puts attachment bytes on a Matrix homeserver.
///
/// This is the Phase 01 [AttachmentTransport] seam finally filled in. It stays
/// deliberately thin: it knows how to move bytes, how big the server will let
/// them be, and how to turn plaintext into the ciphertext an encrypted room
/// requires — and nothing at all about msgtypes, captions or which key the URI
/// belongs under. Those are `weft_attachments`' decisions and stay there.
///
/// **Progress is reported by streaming the body rather than posting it.** The
/// SDK's `uploadContent` assigns `request.bodyBytes` and hands the whole blob to
/// `http`, which can only report "sent" or "not sent" — a 200 MB video would sit
/// at 0% for two minutes and then jump to done. Feeding the request a chunked
/// stream costs one small class and gives a real bar. What it measures is bytes
/// handed to the socket, not bytes acknowledged by the homeserver, so on a fast
/// LAN the first megabyte appears to send instantly; that is the honest limit of
/// measuring from this side of the connection.
///
/// **Nothing identifying goes up with the bytes.** The upload endpoint takes an
/// optional `?filename=`, and this never sends one: for an encrypted room the
/// body is ciphertext but `holiday-with-sam.jpg` in the query string is not, and
/// the filename is already carried inside the event where it belongs.
class MatrixAttachmentTransport implements AttachmentTransport {
  MatrixAttachmentTransport({
    required MatrixApiSession session,
    AttachmentEncryptor encryptor = sdk.encryptFile,
    ThumbnailRasteriser rasteriser = rasteriseThumbnail,
  }) : _session = session,
       _encryptor = encryptor,
       _rasteriser = rasteriser;

  /// Convenience for the common case: transport over a live SDK client.
  factory MatrixAttachmentTransport.forClient(sdk.Client client) =>
      MatrixAttachmentTransport(session: MatrixApiSession.forClient(client));

  final MatrixApiSession _session;
  final AttachmentEncryptor _encryptor;
  final ThumbnailRasteriser _rasteriser;

  /// Ids the user has abandoned. Checked between chunks, which is what makes a
  /// cancel during a 200 MB video actually stop the upstream rather than merely
  /// stop rendering it.
  final Set<String> _cancelled = {};

  /// The resolved `m.upload.size`, once known. Zero is a real answer — "the
  /// server advertises no limit" — and is cached like any other.
  int? _maxUploadBytes;

  /// In flight limit probe, shared so two uploads starting together ask once.
  Future<int?>? _pendingLimit;

  @override
  String get id => 'matrix';

  @override
  String get displayName => 'Matrix';

  /// The homeserver's `m.upload.size`, or 0 when it does not advertise one.
  ///
  /// Resolution follows the spec's two-step: `/_matrix/client/versions` says
  /// whether this server has authenticated media (v1.11, or the MSC3916 unstable
  /// flag), and that decides whether the limit is read from
  /// `/_matrix/client/v1/media/config` or the legacy `/_matrix/media/v3/config`.
  /// Asking the wrong one 404s on exactly the servers Weft is aimed at.
  ///
  /// Cached for the life of the transport, because it is a per-server constant
  /// and a twenty-photo share must not open forty extra round trips to learn it
  /// twenty more times.
  ///
  /// **A failed probe is not cached; a missing limit is.** An unreachable server
  /// gives 0 for this call and then re-probes on the next one, so a limit that
  /// existed all along is not written off for the rest of the session. Zero
  /// means "unknown" to `planUpload`, which skips the size check rather than
  /// rejecting everything — refusing a file because the *limit* could not be
  /// fetched would be worse than letting the server refuse it.
  Future<int> maxUploadBytes() async {
    final cached = _maxUploadBytes;
    if (cached != null) return cached;

    final pending = _pendingLimit ??= _resolveMaxUploadBytes();
    try {
      final resolved = await pending;
      if (resolved != null) _maxUploadBytes = resolved;
      return resolved ?? 0;
    } finally {
      _pendingLimit = null;
    }
  }

  /// Produces what actually goes on the wire for [bytes].
  ///
  /// This is the body of an [UploadPayloadLoader]: plaintext straight through
  /// for a plain room, ciphertext plus key material for an encrypted one. It
  /// lives on the transport rather than in the repository because the pairing of
  /// bytes with the `sha256` *of those bytes* is the part that must not drift,
  /// and encryption is the step that creates both at once.
  Future<UploadPayload> preparePayload(
    Uint8List bytes, {
    required bool encrypted,
  }) async {
    if (!encrypted) return UploadPayload(bytes: bytes);

    final encryptedFile = await _encryptor(bytes);
    return UploadPayload(
      bytes: encryptedFile.data,
      file: EncryptedFileInfo(
        key: encryptedFile.k,
        iv: encryptedFile.iv,
        sha256: encryptedFile.sha256,
      ),
    );
  }

  /// Rasterises the plan's preview, uploads it, and returns everything
  /// `toEventContent` needs to reference it.
  ///
  /// [sourceBytes] is the image to scale down: the file itself for a photo, or a
  /// poster frame for a video. `package:image` is a still-image codec and cannot
  /// open an MP4 — so a video with no poster supplied gets no preview here
  /// rather than a wrong one, and the frame extraction that would fix that is a
  /// platform capability, not a pure-Dart one.
  ///
  /// Returns null, rather than throwing, whenever a preview cannot be produced —
  /// the spec suppressed it, the bytes would not decode, or the second upload
  /// failed. **A missing thumbnail costs a slower first render; a failed send
  /// costs the user their photo.** Anything genuinely wrong with the session or
  /// the server surfaces on the attachment's own upload, which is not swallowed.
  Future<MatrixThumbnailUpload?> uploadThumbnail(
    UploadPlan plan, {
    required Uint8List sourceBytes,
    required String uploadId,
  }) async {
    if (!plan.thumbnail.shouldGenerate) return null;

    final raster = await _rasteriser(sourceBytes, plan.thumbnail);
    if (raster == null || raster.bytes.isEmpty) return null;

    try {
      final payload = await preparePayload(
        raster.bytes,
        encrypted: plan.encrypted,
      );
      final uri = await upload(
        payload.bytes,
        // The preview of an encrypted attachment is encrypted too, so it goes up
        // as opaque bytes; announcing `image/jpeg` over ciphertext tells the
        // media repo what it is holding for no gain.
        mimeType: plan.encrypted ? kFallbackMimeType : plan.thumbnail.mimeType,
        uploadId: thumbnailUploadId(uploadId),
      );
      return MatrixThumbnailUpload(
        uri: uri,
        file: payload.file,
        sizeBytes: raster.bytes.length,
        dimensions: raster.dimensions,
      );
    } on AttachmentTransportException {
      return null;
    }
  }

  /// The id a thumbnail's upload runs under: the attachment's, suffixed.
  ///
  /// Derived rather than allocated so [cancel] on the attachment reaches the
  /// preview too — two ids with no relationship would leave a cancelled photo
  /// still pushing its thumbnail up.
  static String thumbnailUploadId(String uploadId) =>
      '$uploadId$_thumbnailSuffix';

  @override
  Future<String> upload(
    List<int> bytes, {
    required String mimeType,
    required String uploadId,
    void Function(int sent, int total)? onProgress,
  }) async {
    // A retry reuses the task id, so a stale cancellation from the previous
    // attempt would abort the new one before it started.
    _cancelled.remove(uploadId);

    final baseUrl = _session.baseUrl;
    final token = _session.accessToken;
    if (baseUrl == null || token == null || token.isEmpty) {
      throw const AttachmentTransportException(
        'You are not signed in, so this file cannot be sent.',
        retryable: false,
      );
    }

    final request =
        _ProgressRequest(
            'POST',
            baseUrl.resolveUri(Uri(path: kMatrixUploadPath)),
            bytes,
            onChunk: onProgress == null
                ? null
                : (sent) => onProgress(sent, bytes.length),
            isCancelled: () => _isCancelled(uploadId),
          )
          ..headers['authorization'] = 'Bearer $token'
          ..headers['content-type'] = mimeType;

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _session.httpClient.send(request),
      );
    } on _UploadCancelled {
      // The queue has already moved the task to `cancelled` and discards
      // whatever this call does; the message is for the transport's own logs.
      throw const AttachmentTransportException(
        'This upload was cancelled.',
        retryable: false,
      );
    } on Object catch (error) {
      // A dropped connection, a DNS failure, a timeout. On a home connection
      // this is the most common failure by a wide margin, and it is exactly the
      // kind worth spending a retry on.
      throw AttachmentTransportException(
        'Could not reach the server: $error',
        retryable: true,
      );
    }

    if (response.statusCode != 200) {
      throw _failureFor(response);
    }
    return _contentUriFrom(response);
  }

  /// Marks [uploadId] abandoned. The body stream notices before its next chunk.
  ///
  /// Best-effort by contract: bytes already in the socket buffer are gone
  /// whatever happens here.
  @override
  void cancel(String uploadId) => _cancelled.add(uploadId);

  @override
  void dispose() {
    _cancelled.clear();
    // The http client belongs to the session — closing it here would take the
    // whole SDK's connection pool down with the composer.
  }

  bool _isCancelled(String uploadId) {
    if (_cancelled.contains(uploadId)) return true;
    return uploadId.endsWith(_thumbnailSuffix) &&
        _cancelled.contains(
          uploadId.substring(0, uploadId.length - _thumbnailSuffix.length),
        );
  }

  /// Null when the probe itself failed, so the caller knows not to cache it.
  Future<int?> _resolveMaxUploadBytes() async {
    final baseUrl = _session.baseUrl;
    if (baseUrl == null) return null;

    try {
      final authenticated = await _authenticatedMediaSupported(baseUrl);
      final config = await _get(
        baseUrl.resolveUri(
          Uri(
            path: authenticated
                ? '_matrix/client/v1/media/config'
                : '_matrix/media/v3/config',
          ),
        ),
      );
      if (config.statusCode != 200) return null;

      final body = _decodeJson(config.body);
      final limit = body?['m.upload.size'];
      // A server that advertises no limit is answering, not failing: 0 is
      // "unknown" downstream and is worth caching so nothing asks again.
      return limit is num ? limit.toInt() : 0;
    } on Object {
      return null;
    }
  }

  Future<bool> _authenticatedMediaSupported(Uri baseUrl) async {
    final response = await _get(
      baseUrl.resolveUri(Uri(path: '_matrix/client/versions')),
    );
    if (response.statusCode != 200) return false;

    final body = _decodeJson(response.body);
    if (body == null) return false;

    final versions = body['versions'];
    if (versions is List && versions.whereType<String>().any(_isAtLeastV1_11)) {
      return true;
    }
    final unstable = body['unstable_features'];
    return unstable is Map && unstable['org.matrix.msc3916.stable'] == true;
  }

  Future<http.Response> _get(Uri url) {
    final token = _session.accessToken;
    return _session.httpClient.get(
      url,
      headers: {
        // `/versions` needs no auth and the authenticated config endpoint
        // requires it; sending it to both is simpler than tracking which is which.
        if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
      },
    );
  }

  AttachmentTransportException _failureFor(http.Response response) {
    final body = _decodeJson(response.body);
    final serverMessage = body?['error'];
    final errcode = body?['errcode'];

    return switch (response.statusCode) {
      // The server has looked at the size and said no. Three attempts produce
      // three identical refusals and five seconds of the user watching a bar
      // that was never going to move.
      413 => AttachmentTransportException(
        'This file is larger than the server accepts.',
        statusCode: 413,
        retryable: false,
      ),
      401 => AttachmentTransportException(
        'Your session has expired. Sign in again to send this file.',
        statusCode: 401,
        retryable: false,
      ),
      403 => AttachmentTransportException(
        errcode == 'M_FORBIDDEN' && serverMessage is String
            ? serverMessage
            : 'The server refused this upload.',
        statusCode: 403,
        retryable: false,
      ),
      // Rate limiting is the one 4xx that is purely a matter of waiting, which
      // is what the queue's backoff already does.
      429 => AttachmentTransportException(
        'The server is busy. This will try again shortly.',
        statusCode: 429,
        retryable: true,
      ),
      >= 500 => AttachmentTransportException(
        'The server had a problem storing this file.',
        statusCode: response.statusCode,
        retryable: true,
      ),
      _ => AttachmentTransportException(
        serverMessage is String && serverMessage.isNotEmpty
            ? serverMessage
            : 'The server rejected this file (${response.statusCode}).',
        statusCode: response.statusCode,
        retryable: false,
      ),
    };
  }

  String _contentUriFrom(http.Response response) {
    final uri = _decodeJson(response.body)?['content_uri'];
    if (uri is! String || !uri.startsWith('mxc://')) {
      // The bytes are on the server but there is no way to reference them, so
      // the send cannot proceed. Retrying uploads them a second time to the same
      // effect, which is why this is terminal.
      throw const AttachmentTransportException(
        'The server accepted this file but did not say where it went.',
        retryable: false,
      );
    }
    return uri;
  }
}

/// Suffix distinguishing a thumbnail's upload from its attachment's.
const String _thumbnailSuffix = '#thumbnail';

/// Whether a `/versions` entry is v1.11 or later — the release that moved media
/// behind authentication.
bool _isAtLeastV1_11(String version) {
  final match = RegExp(r'^v(\d+)\.(\d+)$').firstMatch(version.trim());
  if (match == null) return false;

  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  return major > 1 || (major == 1 && minor >= 11);
}

Map<String, Object?>? _decodeJson(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    // An HTML error page from a reverse proxy is a normal thing to receive.
    return null;
  }
}

/// A POST whose body is fed to the socket in chunks so it can be measured and
/// abandoned partway.
///
/// `http.Request` holds its body as bytes and offers no hook between "handed
/// over" and "sent". `http.StreamedRequest` offers the hook but needs the caller
/// to drive a sink; a `BaseRequest` that builds its own byte stream in
/// [finalize] is the smaller of the two, and is how `MultipartRequest` does the
/// same job.
class _ProgressRequest extends http.BaseRequest {
  _ProgressRequest(
    super.method,
    super.url,
    this._body, {
    required this.isCancelled,
    void Function(int sent)? onChunk,
  }) : _onChunk = onChunk {
    // Set explicitly: without it `http` reads the length off the stream, which
    // it cannot do, and falls back to chunked transfer encoding — which several
    // reverse proxies in front of home Synapses reject outright.
    contentLength = _body.length;
  }

  final List<int> _body;
  final void Function(int sent)? _onChunk;
  final bool Function() isCancelled;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_chunks());
  }

  Stream<List<int>> _chunks() async* {
    var sent = 0;
    while (sent < _body.length) {
      if (isCancelled()) throw const _UploadCancelled();

      final end = math.min(sent + kUploadChunkBytes, _body.length);
      yield _body.sublist(sent, end);
      sent = end;
      _onChunk?.call(sent);
    }
    // A zero-byte body never enters the loop; `planUpload` rejects empty files
    // long before here, but a transport that silently reported no progress at
    // all for one would be a puzzle to debug.
    if (_body.isEmpty) _onChunk?.call(0);
  }
}

/// Thrown into the body stream to abort an upload the user has cancelled.
class _UploadCancelled implements Exception {
  const _UploadCancelled();
}

/// Scales [bytes] to fit [spec] and encodes the result as JPEG.
///
/// Runs the decode on a background isolate. A 12-megapixel photo takes a
/// noticeable fraction of a second to decode and resize, and doing that on the
/// UI isolate for each of twenty shared photos drops frames in the timeline
/// while it happens — which is precisely when the user is watching it.
///
/// Returns null when the bytes are not a still image `package:image` can decode.
/// That covers video (no pure-Dart frame extractor exists), HEIC on platforms
/// without a decoder, and truncated files; all three mean "no preview", not
/// "failed send".
Future<RasterisedThumbnail?> rasteriseThumbnail(
  Uint8List bytes,
  ThumbnailSpec spec,
) async {
  if (!spec.shouldGenerate) return null;
  return compute(_rasterise, (
    bytes: bytes,
    width: spec.width,
    height: spec.height,
  ));
}

/// The isolate body of [rasteriseThumbnail]. Top-level because `compute` cannot
/// send a closure.
RasterisedThumbnail? _rasterise(
  ({Uint8List bytes, int width, int height}) request,
) {
  final decoded = img.decodeImage(request.bytes);
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) return null;

  // Phone cameras store the sensor's orientation in EXIF rather than rotating
  // the pixels. Skipping this produces sideways thumbnails above right-way-up
  // full-screen images, which reads as a bug in the app rather than in the file.
  final upright = img.bakeOrientation(decoded);

  // Fit inside the box, never past 1:1. The spec's box is square whenever the
  // header could not be probed, so scaling to it directly would stretch a
  // panorama into a square.
  final scale = math.min(
    1.0,
    math.min(request.width / upright.width, request.height / upright.height),
  );
  final width = math.max(1, (upright.width * scale).round());
  final height = math.max(1, (upright.height * scale).round());

  final resized = scale < 1
      ? img.copyResize(
          upright,
          width: width,
          height: height,
          interpolation: img.Interpolation.average,
        )
      : upright;

  return RasterisedThumbnail(
    bytes: img.encodeJpg(resized, quality: kThumbnailJpegQuality),
    dimensions: MediaDimensions(resized.width, resized.height),
  );
}
