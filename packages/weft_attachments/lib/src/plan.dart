import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'detect.dart';

/// Longest edge of a generated thumbnail, in pixels.
///
/// 800 is the largest size that still looks right on a 3x phone bubble while
/// staying small enough that a share of twenty photos does not upload twenty
/// full-resolution previews alongside twenty originals.
const int kThumbnailLongestEdge = 800;

/// Below this, generating a thumbnail costs more than it saves.
///
/// A 40 KB photo *is* its own thumbnail: re-encoding it produces a second blob
/// of roughly the same size, doubling the upload for no gain in the timeline.
const int kThumbnailMinSourceBytes = 64 * 1024;

/// Thumbnails are always JPEG, whatever the original was.
///
/// Every Matrix client can decode it, it has no alpha channel to lose on a
/// preview, and it keeps one code path rather than one per source format.
const String kThumbnailMimeType = 'image/jpeg';

/// Matrix msgtype for a file with no better classification.
const String kFileMsgtype = 'm.file';

/// What, if anything, to rasterise as a preview for one attachment.
///
/// This is a *decision*, not an image — nothing in this package can decode
/// pixels. The renderer in Phase 02 reads [shouldGenerate] and, when true,
/// scales the original down to fit [width] x [height].
@immutable
class ThumbnailSpec {
  const ThumbnailSpec({
    required this.width,
    required this.height,
    required this.shouldGenerate,
    this.mimeType = kThumbnailMimeType,
  });

  /// No preview for this attachment.
  ///
  /// [width] and [height] carry no meaning when [shouldGenerate] is false;
  /// they are zero rather than nullable so callers never have to unwrap a
  /// dimension they have already been told not to use.
  const ThumbnailSpec.suppressed()
    : width = 0,
      height = 0,
      shouldGenerate = false,
      mimeType = kThumbnailMimeType;

  /// The decision for a source of [sizeBytes] holding a [kind] of [dimensions].
  ///
  /// [dimensions] may be null and routinely is: a video whose `moov` box sits
  /// at the end of the file cannot be probed from a header slice. That is not a
  /// reason to skip the preview — it is a reason to fall back to a square
  /// bounding box and let the rasteriser preserve the real aspect ratio once it
  /// has the whole file.
  factory ThumbnailSpec.forSource({
    required MessageKind kind,
    required int sizeBytes,
    MediaDimensions? dimensions,
  }) {
    final isVisual = kind == MessageKind.image || kind == MessageKind.video;
    if (!isVisual || sizeBytes < kThumbnailMinSourceBytes) {
      return const ThumbnailSpec.suppressed();
    }

    final target = _scaleToLongestEdge(dimensions);
    return ThumbnailSpec(
      width: target.width,
      height: target.height,
      shouldGenerate: true,
    );
  }

  /// Target width in pixels.
  final int width;

  /// Target height in pixels.
  final int height;

  /// Always [kThumbnailMimeType]; a field rather than a constant so the value
  /// travels with the spec into `thumbnail_info`.
  final String mimeType;

  /// Whether a preview is worth producing at all.
  final bool shouldGenerate;

  @override
  bool operator ==(Object other) =>
      other is ThumbnailSpec &&
      other.width == width &&
      other.height == height &&
      other.mimeType == mimeType &&
      other.shouldGenerate == shouldGenerate;

  @override
  int get hashCode => Object.hash(width, height, mimeType, shouldGenerate);

  @override
  String toString() => shouldGenerate
      ? 'ThumbnailSpec(${width}x$height $mimeType)'
      : 'ThumbnailSpec(none)';
}

/// Fits [dimensions] inside a [kThumbnailLongestEdge] box without upscaling.
MediaDimensions _scaleToLongestEdge(MediaDimensions? dimensions) {
  if (dimensions == null) {
    // Unknown aspect ratio, so the only honest answer is the bounding box.
    return const MediaDimensions(kThumbnailLongestEdge, kThumbnailLongestEdge);
  }
  if (dimensions.longestEdge <= kThumbnailLongestEdge) {
    // Already small enough. Blowing a 200px image up to 800 wastes bytes and
    // makes it blurrier than sending it untouched.
    return dimensions;
  }

  final scale = kThumbnailLongestEdge / dimensions.longestEdge;
  // Round rather than truncate, then floor at 1: a 4000x9 panorama must not
  // scale to a zero-height thumbnail.
  final width = (dimensions.width * scale).round();
  final height = (dimensions.height * scale).round();
  return MediaDimensions(width < 1 ? 1 : width, height < 1 ? 1 : height);
}

/// The key material for an `m.encrypted` attachment.
///
/// Deliberately does **not** carry the mxc URI. Attachments are encrypted
/// *before* they are uploaded, so at the moment this value exists there is no
/// URI to put in it; [UploadPlan.toEventContent] injects one afterwards. Keeping
/// the two apart is also what makes it impossible to accidentally emit key
/// material for a plain-room event.
///
/// Shape per the Matrix `EncryptedFile` schema — the JWK envelope around [key]
/// is fixed for Matrix media, so only the parts that vary are stored.
@immutable
class EncryptedFileInfo {
  const EncryptedFileInfo({
    required this.key,
    required this.iv,
    required this.sha256,
    this.algorithm = 'A256CTR',
    this.version = 'v2',
  });

  /// Parses a `file` block, tolerating a missing or reshaped JWK.
  ///
  /// A shape change should surface as empty fields the caller can check, not as
  /// a cast exception in the middle of rendering a timeline.
  factory EncryptedFileInfo.fromJson(Map<String, Object?> json) {
    final jwk = json['key'];
    final hashes = json['hashes'];
    return EncryptedFileInfo(
      key: jwk is Map ? jwk['k'] as String? ?? '' : '',
      iv: json['iv'] as String? ?? '',
      sha256: hashes is Map ? hashes['sha256'] as String? ?? '' : '',
      algorithm: (jwk is Map ? jwk['alg'] as String? : null) ?? 'A256CTR',
      version: json['v'] as String? ?? 'v2',
    );
  }

  /// The JWK's `k`: the AES key, unpadded URL-safe base64.
  final String key;

  /// Initialisation vector, unpadded base64.
  final String iv;

  /// SHA-256 of the *ciphertext*, unpadded base64. Checked before decryption,
  /// so a tampered blob is rejected without ever being fed to the cipher.
  final String sha256;

  /// JWK `alg`. Matrix media is AES-CTR and nothing else, but the field is
  /// carried through so an unexpected value round-trips instead of being
  /// silently rewritten.
  final String algorithm;

  /// Version of the attachment encryption scheme.
  final String version;

  /// The `file` block *without* `url` — see the class doc.
  Map<String, Object?> toJson() => {
    'key': {
      'kty': 'oct',
      'alg': algorithm,
      'ext': true,
      'k': key,
      'key_ops': const ['encrypt', 'decrypt'],
    },
    'iv': iv,
    'hashes': {'sha256': sha256},
    'v': version,
  };

  @override
  bool operator ==(Object other) =>
      other is EncryptedFileInfo &&
      other.key == key &&
      other.iv == iv &&
      other.sha256 == sha256 &&
      other.algorithm == algorithm &&
      other.version == version;

  @override
  int get hashCode => Object.hash(key, iv, sha256, algorithm, version);

  @override
  String toString() => 'EncryptedFileInfo($algorithm, $version)';
}

/// The outcome of planning one attachment: either an [UploadPlan] or an
/// [UploadRejection].
///
/// Sealed so a caller that forgets the rejection branch fails to compile rather
/// than uploading a zero-byte file.
@immutable
sealed class UploadDecision {
  const UploadDecision();
}

/// Why an attachment cannot be sent.
enum UploadRejectionReason {
  /// Nothing to upload — a zero-byte file, or a size the picker never filled in.
  empty,

  /// Larger than the homeserver will accept.
  tooLarge,

  /// Structurally unsendable for a reason that is not about size.
  unsupported,
}

/// A file that will not be sent, with a reason fit to show the user.
@immutable
final class UploadRejection extends UploadDecision {
  const UploadRejection({
    required this.reason,
    required this.message,
    this.sizeBytes,
    this.limitBytes,
  });

  final UploadRejectionReason reason;

  /// An English sentence, kept for logs and for a caller with no translations
  /// of its own. The app words [reason] instead, using [sizeBytes] and
  /// [limitBytes] where it needs the numbers — see
  /// `docs/architecture/l10n-pipeline.md`, "Packages and their words".
  final String message;

  /// The file's size, for the sentence the app writes about it.
  final int? sizeBytes;

  /// What the server would have accepted, for the same sentence.
  final int? limitBytes;

  @override
  String toString() => 'UploadRejection(${reason.name}: $message)';
}

/// Everything decided about one attachment before a single byte is uploaded.
///
/// Holding the whole decision as a value is what makes the interesting parts
/// testable: the msgtype, the thumbnail call, and — the one that renders as a
/// broken attachment on every other client when it is wrong — whether the mxc
/// URI belongs under `url` or under `file.url`.
@immutable
final class UploadPlan extends UploadDecision {
  const UploadPlan({
    required this.source,
    required this.mimeType,
    required this.kind,
    required this.msgtype,
    required this.thumbnail,
    required this.encrypted,
    this.dimensions,
    this.durationMs,
    this.caption,
  });

  /// The file this plan is about.
  final AttachmentSource source;

  /// The sniffed type, which is not necessarily the declared one.
  final String mimeType;

  final MessageKind kind;

  /// `m.image`, `m.video`, `m.audio` or `m.file`. Spelled literally because this
  /// package cannot import the Matrix SDK; `weft_matrix`'s
  /// `messageKindFromMsgtype` reads the same table the other way round.
  final String msgtype;

  /// Pixel dimensions, when they could be read from the header. Null is normal
  /// for video and for any format without a probe, and is not an error.
  final MediaDimensions? dimensions;

  /// Playback length in milliseconds, supplied by the caller — no duration is
  /// derivable from a header slice.
  final int? durationMs;

  final ThumbnailSpec thumbnail;

  /// Whether the destination room requires encryption. Decided once, here, so
  /// nothing downstream has to ask the room again.
  final bool encrypted;

  /// What the user typed under the picture before sending it, or null when they
  /// typed nothing — which is the overwhelming majority of attachments.
  ///
  /// Held on the plan rather than passed to [toEventContent] at dispatch time
  /// because of where the two moments are. The plan is what `UploadQueue` keeps
  /// for the whole life of a task — through `hashing`, through three attempts
  /// and sixteen seconds of backoff, through a failure the user retries an hour
  /// later — and the event is written from it at the far end. A caption passed
  /// in at the end would have to be carried alongside the plan by every layer
  /// in between, and the one that forgot would drop the user's words silently:
  /// the photo still arrives, so nothing looks broken.
  ///
  /// Empty and whitespace-only strings are normalised to null by [planUpload],
  /// so `caption != null` means there is really something to say.
  final String? caption;

  /// Size of the original file in bytes.
  int get sizeBytes => source.sizeBytes;

  /// Filename without any leading path, which is what `body` carries.
  String get filename => source.basename;

  /// Whether this was recorded in the app rather than picked from disk.
  ///
  /// Derived, not stored: `weft_domain` already draws the line between
  /// [MessageKind.voice] and [MessageKind.audio], and a second flag saying the
  /// same thing could disagree with it.
  bool get isVoiceNote => kind == MessageKind.voice;

  /// The `m.room.message` content for this attachment, once uploaded.
  ///
  /// [uri] is the mxc URI the homeserver returned. Where it lands is the whole
  /// point of this method: **plain rooms carry it at the top level under `url`,
  /// encrypted rooms carry it inside the `file` block under `file.url`**, and a
  /// client that finds neither renders a paperclip with no content. `weft_matrix`
  /// reads exactly this back — its `_hasAttachment` is
  /// `content['url'] is String || content['file'] is Map`.
  ///
  /// [file] is required when [encrypted] and forbidden otherwise; the same rule
  /// applies to [thumbnailFile] whenever [thumbnailUri] is given. Mixing the two
  /// shapes is a programming error rather than bad user input, so it throws
  /// [ArgumentError] instead of degrading — an event that carries both a plain
  /// `url` and a `file` block is ambiguous to every receiving client.
  ///
  /// A [caption] replaces `body` with the user's text and moves the filename to
  /// `filename`, per MSC2530. Without one, `body` is the filename, which is what
  /// clients that predate captions expect — and which is why the two keys are
  /// never both the name: a receiving client that falls back to `body` would
  /// then print `IMG_4021.jpg` under the photo instead of the caption.
  Map<String, Object?> toEventContent({
    required String uri,
    EncryptedFileInfo? file,
    String? thumbnailUri,
    EncryptedFileInfo? thumbnailFile,
    int? thumbnailSizeBytes,
    MediaDimensions? thumbnailDimensions,
  }) {
    if (encrypted && file == null) {
      throw ArgumentError.notNull('file');
    }
    if (!encrypted && file != null) {
      throw ArgumentError.value(
        file,
        'file',
        'An unencrypted room takes the URI under `url`; sending key material '
            'alongside it makes the event ambiguous.',
      );
    }
    if (thumbnailUri == null &&
        (thumbnailFile != null ||
            thumbnailSizeBytes != null ||
            thumbnailDimensions != null)) {
      throw ArgumentError.notNull('thumbnailUri');
    }
    if (thumbnailUri != null) {
      if (encrypted && thumbnailFile == null) {
        throw ArgumentError.notNull('thumbnailFile');
      }
      if (!encrypted && thumbnailFile != null) {
        throw ArgumentError.value(
          thumbnailFile,
          'thumbnailFile',
          'An unencrypted room takes the thumbnail under `info.thumbnail_url`.',
        );
      }
    }

    final info = <String, Object?>{'mimetype': mimeType, 'size': sizeBytes};
    if (dimensions != null) {
      info['w'] = dimensions!.width;
      info['h'] = dimensions!.height;
    }
    if (durationMs != null) info['duration'] = durationMs;

    if (thumbnailUri != null) {
      // Same split as the attachment itself, one level down. Getting this half
      // right — a `file` block for the attachment and a plain `thumbnail_url`
      // beside it — leaks an unencrypted preview out of an encrypted room.
      if (encrypted) {
        info['thumbnail_file'] = {
          ...thumbnailFile!.toJson(),
          'url': thumbnailUri,
        };
      } else {
        info['thumbnail_url'] = thumbnailUri;
      }
      final size = thumbnailDimensions ?? _specDimensions;
      info['thumbnail_info'] = <String, Object?>{
        'mimetype': thumbnail.mimeType,
        if (size != null) 'w': size.width,
        if (size != null) 'h': size.height,
        'size': ?thumbnailSizeBytes,
      };
    }

    return <String, Object?>{
      'msgtype': msgtype,
      'body': caption ?? filename,
      if (caption != null) 'filename': filename,
      'info': info,
      if (encrypted) 'file': {...file!.toJson(), 'url': uri} else 'url': uri,
      // MSC3245 marks the event as a recorded voice note, and the MSC1767
      // extension is the secondary signal most bridges read. `weft_matrix`'s
      // `isVoiceMessage` accepts either, so both are written — an event that
      // round-trips back through `mapEvent` must come out as
      // `MessageKind.voice`, not `.audio`.
      if (isVoiceNote) ...{
        'org.matrix.msc3245.voice': const <String, Object?>{},
        'org.matrix.msc1767.audio': <String, Object?>{
          if (durationMs != null) 'duration': durationMs,
        },
      },
    };
  }

  /// The spec's target size, or null when it decided against a preview.
  MediaDimensions? get _specDimensions => thumbnail.shouldGenerate
      ? MediaDimensions(thumbnail.width, thumbnail.height)
      : null;

  @override
  String toString() =>
      'UploadPlan(${source.filename}, $mimeType, $msgtype, '
      '${encrypted ? 'encrypted' : 'plain'})';
}

/// Decides what Weft will do with [source], or why it will not.
///
/// [maxUploadBytes] is the homeserver's `m.upload.size`. A non-positive value
/// means the homeserver never advertised one — the limit is then unknown rather
/// than zero, so the check is skipped instead of rejecting everything.
///
/// [isVoiceNote] is the recorder's assertion, and only meaningful for audio;
/// [messageKindFor] ignores it for everything else. [durationMs] likewise comes
/// from the caller: no playback length is readable from a header slice.
///
/// [caption] is the user's own words, trimmed here and normalised to null when
/// nothing is left. Doing it once, at the only door into the pipeline, is what
/// stops a composer that submitted a field holding two spaces from producing an
/// event whose `body` is `"  "` and whose `filename` is the name the body should
/// have carried — a message that renders as a blank line on every client.
///
/// Total — every input produces a decision, never an exception.
UploadDecision planUpload(
  AttachmentSource source, {
  required bool encrypted,
  required int maxUploadBytes,
  bool isVoiceNote = false,
  int? durationMs,
  String? caption,
}) {
  if (source.isEmpty) {
    return const UploadRejection(
      reason: UploadRejectionReason.empty,
      message: 'This file is empty, so there is nothing to send.',
    );
  }
  if (maxUploadBytes > 0 && source.sizeBytes > maxUploadBytes) {
    return UploadRejection(
      reason: UploadRejectionReason.tooLarge,
      message:
          'This file is ${_megabytes(source.sizeBytes)} MB, and the server '
          'accepts at most ${_megabytes(maxUploadBytes)} MB.',
      sizeBytes: source.sizeBytes,
      limitBytes: maxUploadBytes,
    );
  }

  final mimeType = sniffMimeType(source);
  final kind = messageKindFor(mimeType, isVoiceNote: isVoiceNote);

  // `body` is the filename, and Matrix has no way to describe a file with no
  // name. This is the only non-size reason a real file is turned away.
  if (source.basename.trim().isEmpty) {
    return const UploadRejection(
      reason: UploadRejectionReason.unsupported,
      message: 'This file has no name, so it cannot be sent.',
    );
  }

  final dimensions = switch (kind) {
    MessageKind.image => probeImageDimensions(source.header),
    MessageKind.video => probeVideoDimensions(source.header),
    _ => null,
  };

  final trimmed = caption?.trim();

  return UploadPlan(
    source: source,
    mimeType: mimeType,
    kind: kind,
    msgtype: _msgtypeFor(kind),
    dimensions: dimensions,
    durationMs: durationMs,
    caption: trimmed == null || trimmed.isEmpty ? null : trimmed,
    thumbnail: ThumbnailSpec.forSource(
      kind: kind,
      sizeBytes: source.sizeBytes,
      dimensions: dimensions,
    ),
    encrypted: encrypted,
  );
}

/// The inverse of `weft_matrix`'s `messageKindFromMsgtype`.
///
/// Voice notes are `m.audio` like any other sound; what makes them voice notes
/// is the MSC3245 key, not the msgtype.
String _msgtypeFor(MessageKind kind) => switch (kind) {
  MessageKind.image => 'm.image',
  MessageKind.video => 'm.video',
  MessageKind.audio || MessageKind.voice => 'm.audio',
  _ => kFileMsgtype,
};

/// Bytes as megabytes, at one decimal place, for a user-facing sentence.
String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
