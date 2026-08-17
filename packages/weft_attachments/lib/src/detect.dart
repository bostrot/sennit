import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// A file the user is trying to send, described by everything that can be known
/// about it without reading the whole thing.
///
/// [header] is a prefix slice, not the file. A share intent can hand over a
/// 400 MB video, and nothing in this package needs more than the first few
/// kilobytes to decide what it is and how it will be sent — so the contract is
/// that only [sizeBytes] knows the real length.
@immutable
class AttachmentSource {
  const AttachmentSource({
    required this.filename,
    required this.sizeBytes,
    required this.header,
    this.declaredMimeType,
  });

  /// Display name including extension. May carry path separators when it came
  /// straight from a picker; [extension] handles that.
  final String filename;

  /// What the *sender* claims this is. Nullable because an Android share intent
  /// frequently supplies nothing at all — and when it does supply something it
  /// is often `*/*`, which is why [sniffMimeType] never trusts it over the
  /// bytes.
  final String? declaredMimeType;

  /// Full length of the file on disk, not of [header].
  final int sizeBytes;

  /// Leading bytes of the file. Anything from zero bytes upward is legal; every
  /// probe in this library degrades to null rather than assuming a minimum.
  final Uint8List header;

  /// [filename] with any leading path removed.
  ///
  /// A picker on one platform hands over a bare name and on another a full
  /// path, and it is the bare name that becomes the event's `body`.
  String get basename {
    final slash = filename.lastIndexOf('/');
    final backslash = filename.lastIndexOf(r'\');
    final cut = slash > backslash ? slash : backslash;
    return cut >= 0 ? filename.substring(cut + 1) : filename;
  }

  /// Lower-cased extension without the dot, or null when there is none.
  ///
  /// A leading-dot name like `.gitignore` has no extension, not an extension of
  /// `gitignore`.
  String? get extension {
    final name = basename;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  /// Nothing to send. Kept here rather than in the caller because a zero-byte
  /// file is the one input every stage below has to special-case.
  bool get isEmpty => sizeBytes <= 0;

  @override
  String toString() => 'AttachmentSource($filename, $sizeBytes bytes)';
}

/// Pixel dimensions of an image or a video track.
@immutable
class MediaDimensions {
  const MediaDimensions(this.width, this.height);

  final int width;
  final int height;

  /// Longest edge, which is what thumbnail sizing is expressed in.
  int get longestEdge => width > height ? width : height;

  @override
  bool operator ==(Object other) =>
      other is MediaDimensions &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// The type every unrecognised file falls back to.
const String kFallbackMimeType = 'application/octet-stream';

/// Best guess at what [source] actually is.
///
/// Resolution order is bytes, then the declared type, then the filename
/// extension, then [kFallbackMimeType]. **The sniffed type wins over the
/// declared one when they conflict**: share intents routinely declare `*/*` or
/// `application/octet-stream` for a JPEG, and sending that as `m.file` shows a
/// paperclip instead of a picture on every other client.
///
/// Total by construction — a truncated, empty or garbage [AttachmentSource.header]
/// simply falls through to the next source of truth.
String sniffMimeType(AttachmentSource source) {
  final declared = _meaningfulMimeType(source.declaredMimeType);
  final fromExtension = _mimeTypeForExtension(source.extension);
  final sniffed = _sniffFromBytes(source.header);

  if (sniffed != null) {
    // A ZIP container is a real answer and a useless one at once: docx, xlsx,
    // epub, apk and jar are all `PK\x03\x04`. Here the declared type refines
    // the sniff rather than contradicting it, so the specific type wins.
    if (sniffed == 'application/zip') {
      if (declared != null && _zipBasedMimeTypes.contains(declared)) {
        return declared;
      }
      if (fromExtension != null && _zipBasedMimeTypes.contains(fromExtension)) {
        return fromExtension;
      }
    }
    return sniffed;
  }

  return declared ?? fromExtension ?? kFallbackMimeType;
}

/// Maps a mime type onto the existing [MessageKind] vocabulary.
///
/// [isVoiceNote] is the caller's assertion that this was *recorded in the app*,
/// not merely an audio file — the two are already distinct in `weft_domain`
/// (only they satisfy `canTranscribe`) and only the recorder knows which it is.
/// It is ignored for non-audio types, so a mislabelled flag cannot turn a PDF
/// into a voice message.
MessageKind messageKindFor(String mimeType, {bool isVoiceNote = false}) {
  final type = _meaningfulMimeType(mimeType);
  if (type == null) return MessageKind.file;
  if (type.startsWith('image/')) return MessageKind.image;
  if (type.startsWith('video/')) return MessageKind.video;
  if (type.startsWith('audio/')) {
    return isVoiceNote ? MessageKind.voice : MessageKind.audio;
  }
  return MessageKind.file;
}

/// Width and height of a still image, read from [header] alone.
///
/// Understands PNG, JPEG, GIF and all three WebP chunk flavours. Returns null —
/// never throws — for an unrecognised format, a truncated header, or a
/// structurally broken file. HEIC dimensions live in an `ispe` box behind a
/// full item-properties tree and are deliberately not attempted.
MediaDimensions? probeImageDimensions(Uint8List header) {
  if (_startsWith(header, _pngSignature)) return _probePng(header);
  if (_startsWith(header, const [0xFF, 0xD8])) return _probeJpeg(header);
  if (_startsWithAscii(header, 'GIF8')) return _probeGif(header);
  if (_isRiff(header, 'WEBP')) return _probeWebp(header);
  return null;
}

/// Width and height of a video's first visual track, read from [header] alone.
///
/// Walks the ISO-BMFF box tree (MP4, M4V, QuickTime) to the first `tkhd` with
/// non-zero dimensions — audio tracks carry 0x0 and must be skipped. Returns
/// null when `moov` sits at the end of the file, which is the normal layout for
/// anything not written for streaming, as well as for WebM and for garbage.
MediaDimensions? probeVideoDimensions(Uint8List header) {
  if (!_hasFtyp(header)) return null;
  final top = _childBoxes(header, 0, header.length);
  final moov = top.firstWhereOrNull((box) => box.type == 'moov');
  if (moov == null) return null;

  for (final trak in _childBoxes(header, moov.start, moov.end)) {
    if (trak.type != 'trak') continue;
    for (final tkhd in _childBoxes(header, trak.start, trak.end)) {
      if (tkhd.type != 'tkhd') continue;
      final dimensions = _parseTkhd(header, tkhd);
      if (dimensions != null) return dimensions;
    }
  }
  return null;
}

// --- Magic bytes -----------------------------------------------------------

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Mime types whose container is a ZIP, and which therefore sniff identically.
const Set<String> _zipBasedMimeTypes = {
  'application/epub+zip',
  'application/java-archive',
  'application/vnd.android.package-archive',
  'application/vnd.oasis.opendocument.presentation',
  'application/vnd.oasis.opendocument.spreadsheet',
  'application/vnd.oasis.opendocument.text',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
};

/// `ftyp` brand to mime type. The brand is the only thing separating a photo
/// from a movie in the ISO-BMFF family, so getting this table wrong files an
/// iPhone photo as `m.video`.
const Map<String, String> _ftypBrands = {
  'heic': 'image/heic',
  'heix': 'image/heic',
  'heim': 'image/heic',
  'heis': 'image/heic',
  'hevc': 'image/heic',
  'hevx': 'image/heic',
  'hevm': 'image/heic',
  'hevs': 'image/heic',
  'mif1': 'image/heif',
  'msf1': 'image/heif',
  'avif': 'image/avif',
  'avis': 'image/avif',
  'qt  ': 'video/quicktime',
  'M4A ': 'audio/mp4',
  'M4B ': 'audio/mp4',
  'M4V ': 'video/mp4',
  '3gp4': 'video/3gpp',
  '3gp5': 'video/3gpp',
  '3g2a': 'video/3gpp2',
};

String? _sniffFromBytes(Uint8List b) {
  if (b.isEmpty) return null;

  if (_startsWith(b, _pngSignature)) return 'image/png';
  if (_startsWith(b, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (_startsWithAscii(b, 'GIF87a') || _startsWithAscii(b, 'GIF89a')) {
    return 'image/gif';
  }
  if (_startsWithAscii(b, '%PDF-')) return 'application/pdf';
  if (_startsWith(b, const [0x50, 0x4B, 0x03, 0x04]) ||
      _startsWith(b, const [0x50, 0x4B, 0x05, 0x06]) ||
      _startsWith(b, const [0x50, 0x4B, 0x07, 0x08])) {
    return 'application/zip';
  }

  // RIFF containers share a header and diverge at byte 8.
  if (_isRiff(b, 'WEBP')) return 'image/webp';
  if (_isRiff(b, 'WAVE')) return 'audio/wav';

  // EBML. Doctype decides webm vs generic matroska, and it sits within the
  // first few dozen bytes of the header element.
  if (_startsWith(b, const [0x1A, 0x45, 0xDF, 0xA3])) {
    if (_containsAscii(b, 'webm', limit: 64)) return 'video/webm';
    if (_containsAscii(b, 'matroska', limit: 64)) return 'video/x-matroska';
    return 'video/webm';
  }

  if (_startsWithAscii(b, 'OggS')) {
    // Ogg is a container; the codec name in the first page's header packet is
    // what says whether this is a voice note or a movie.
    if (_containsAscii(b, 'theora', limit: 128)) return 'video/ogg';
    return 'audio/ogg';
  }

  if (_hasFtyp(b)) {
    final brand = _ascii(b, 8, 4);
    final mapped = brand == null ? null : _ftypBrands[brand];
    if (mapped != null) return mapped;
    return 'video/mp4';
  }

  if (_startsWithAscii(b, 'ID3')) return 'audio/mpeg';

  // Bare MPEG frame sync, checked last: eleven set bits are weak evidence, so
  // the version and layer fields must also be non-reserved before believing it.
  if (b.length >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) {
    final version = (b[1] >> 3) & 0x03;
    final layer = (b[1] >> 1) & 0x03;
    if (version != 0x01 && layer != 0x00) return 'audio/mpeg';
  }

  return null;
}

/// True when the bytes look like an ISO base media file — a `ftyp` box at the
/// very start.
bool _hasFtyp(Uint8List b) => _asciiAt(b, 4, 'ftyp');

// --- Extension fallback ----------------------------------------------------

const Map<String, String> _mimeTypesByExtension = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'avif': 'image/avif',
  'bmp': 'image/bmp',
  'svg': 'image/svg+xml',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  'ogv': 'video/ogg',
  '3gp': 'video/3gpp',
  'avi': 'video/x-msvideo',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'flac': 'audio/flac',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'opus': 'audio/ogg',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
  '7z': 'application/x-7z-compressed',
  'rar': 'application/vnd.rar',
  'apk': 'application/vnd.android.package-archive',
  'jar': 'application/java-archive',
  'epub': 'application/epub+zip',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'odt': 'application/vnd.oasis.opendocument.text',
  'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  'odp': 'application/vnd.oasis.opendocument.presentation',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'html': 'text/html',
  'htm': 'text/html',
  'json': 'application/json',
  'xml': 'application/xml',
};

String? _mimeTypeForExtension(String? extension) =>
    extension == null ? null : _mimeTypesByExtension[extension];

/// Normalises a claimed mime type, treating the wildcards and the universal
/// fallback as "no claim at all" — they carry no more information than null.
String? _meaningfulMimeType(String? raw) {
  if (raw == null) return null;
  final value = raw.trim().toLowerCase();
  // Strip any `; charset=utf-8` style parameters before comparing.
  final base = value.split(';').first.trim();
  if (base.isEmpty ||
      base == '*/*' ||
      base.endsWith('/*') ||
      base == kFallbackMimeType ||
      base == 'binary/octet-stream' ||
      !base.contains('/')) {
    return null;
  }
  return base;
}

// --- Image dimension probes ------------------------------------------------

MediaDimensions? _probePng(Uint8List b) {
  // Signature (8), chunk length (4), 'IHDR' (4), width (4), height (4).
  if (!_asciiAt(b, 12, 'IHDR')) return null;
  final width = _u32be(b, 16);
  final height = _u32be(b, 20);
  return _dimensionsOrNull(width, height);
}

MediaDimensions? _probeJpeg(Uint8List b) {
  var offset = 2;
  while (offset + 3 < b.length) {
    // Segments are 0xFF-prefixed, with any number of 0xFF fill bytes allowed
    // between them.
    if (b[offset] != 0xFF) {
      offset++;
      continue;
    }
    final marker = b[offset + 1];
    if (marker == 0xFF) {
      offset++;
      continue;
    }
    // Standalone markers carry no length field.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
      offset += 2;
      continue;
    }
    final length = _u16be(b, offset + 2);
    if (length == null || length < 2) return null;

    final isStartOfFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isStartOfFrame) {
      // length (2), sample precision (1), height (2), width (2).
      final height = _u16be(b, offset + 5);
      final width = _u16be(b, offset + 7);
      return _dimensionsOrNull(width, height);
    }
    // 0xDA is the start of scan: past here it is entropy-coded data, not
    // segments, and no SOFn will follow.
    if (marker == 0xDA) return null;
    offset += 2 + length;
  }
  return null;
}

MediaDimensions? _probeGif(Uint8List b) {
  // The logical screen descriptor follows the six-byte signature, little-endian.
  final width = _u16le(b, 6);
  final height = _u16le(b, 8);
  return _dimensionsOrNull(width, height);
}

MediaDimensions? _probeWebp(Uint8List b) {
  final chunk = _ascii(b, 12, 4);
  switch (chunk) {
    case 'VP8 ':
      // Lossy: 3-byte frame tag, a fixed start code, then two 14-bit fields.
      if (b.length < 30) return null;
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
      final width = _u16le(b, 26);
      final height = _u16le(b, 28);
      if (width == null || height == null) return null;
      return _dimensionsOrNull(width & 0x3FFF, height & 0x3FFF);
    case 'VP8L':
      // Lossless: signature byte, then 14 bits of width-1 and 14 of height-1
      // packed little-endian across four bytes.
      if (b.length < 25 || b[20] != 0x2F) return null;
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return _dimensionsOrNull(
        (bits & 0x3FFF) + 1,
        ((bits >> 14) & 0x3FFF) + 1,
      );
    case 'VP8X':
      // Extended: flags (4), then canvas width-1 and height-1 as 24-bit
      // little-endian values.
      final width = _u24le(b, 24);
      final height = _u24le(b, 27);
      if (width == null || height == null) return null;
      return _dimensionsOrNull(width + 1, height + 1);
    default:
      return null;
  }
}

// --- ISO-BMFF box walking --------------------------------------------------

@immutable
class _Box {
  const _Box(this.type, this.start, this.end);

  final String type;

  /// First byte of the box's content, past its header.
  final int start;

  /// One past the box's last content byte, clamped to what is actually
  /// available — a header slice routinely ends mid-box.
  final int end;
}

/// Children of a box, read from the range `[from, to)`.
///
/// Stops at the first malformed or truncated entry instead of throwing, and
/// caps the count because a corrupt size field should not turn into a long loop.
List<_Box> _childBoxes(Uint8List b, int from, int to) {
  final boxes = <_Box>[];
  var offset = from;
  while (offset + 8 <= to && boxes.length < 64) {
    final declaredSize = _u32be(b, offset);
    final type = _ascii(b, offset + 4, 4);
    if (declaredSize == null || type == null) break;

    var size = declaredSize;
    var contentStart = offset + 8;
    if (declaredSize == 1) {
      // A size of 1 means the real 64-bit size follows the type.
      final high = _u32be(b, offset + 8);
      final low = _u32be(b, offset + 12);
      if (high == null || low == null) break;
      size = (high << 32) | low;
      contentStart = offset + 16;
    } else if (declaredSize == 0) {
      // A size of 0 means the box runs to the end of the file.
      size = to - offset;
    }
    if (size < contentStart - offset) break;

    final declaredEnd = offset + size;
    boxes.add(_Box(type, contentStart, declaredEnd < to ? declaredEnd : to));
    offset = declaredEnd;
  }
  return boxes;
}

MediaDimensions? _parseTkhd(Uint8List b, _Box box) {
  final version = box.start < b.length ? b[box.start] : null;
  if (version == null) return null;
  // version/flags (4), then the timing block, then reserved (8), layer (2),
  // alternate_group (2), volume (2), reserved (2) and the 36-byte matrix.
  final timingBytes = version == 1 ? 32 : 20;
  final offset = box.start + 4 + timingBytes + 52;
  if (offset + 8 > box.end) return null;

  final width = _u32be(b, offset);
  final height = _u32be(b, offset + 4);
  if (width == null || height == null) return null;

  // Both are 16.16 fixed-point. An audio track stores 0x0, which is how a
  // soundtrack gets skipped in favour of the real visual track.
  return _dimensionsOrNull(width >> 16, height >> 16);
}

// --- Byte helpers ----------------------------------------------------------

MediaDimensions? _dimensionsOrNull(int? width, int? height) {
  if (width == null || height == null) return null;
  if (width <= 0 || height <= 0) return null;
  return MediaDimensions(width, height);
}

int? _u16be(Uint8List b, int i) =>
    i + 2 <= b.length ? (b[i] << 8) | b[i + 1] : null;

int? _u16le(Uint8List b, int i) =>
    i + 2 <= b.length ? b[i] | (b[i + 1] << 8) : null;

int? _u24le(Uint8List b, int i) =>
    i + 3 <= b.length ? b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) : null;

int? _u32be(Uint8List b, int i) => i + 4 <= b.length
    ? (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]
    : null;

/// The [length] bytes at [offset] as ASCII, or null if they run past the end or
/// are not printable — a four-character code that is not printable is a sign the
/// bytes are not what they claim, not a box type.
String? _ascii(Uint8List b, int offset, int length) {
  if (offset < 0 || offset + length > b.length) return null;
  final buffer = StringBuffer();
  for (var i = offset; i < offset + length; i++) {
    if (b[i] < 0x20 || b[i] > 0x7E) return null;
    buffer.writeCharCode(b[i]);
  }
  return buffer.toString();
}

bool _asciiAt(Uint8List b, int offset, String expected) =>
    _ascii(b, offset, expected.length) == expected;

bool _startsWith(Uint8List b, List<int> prefix) {
  if (b.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (b[i] != prefix[i]) return false;
  }
  return true;
}

bool _startsWithAscii(Uint8List b, String prefix) => _asciiAt(b, 0, prefix);

/// Whether [needle] appears in the first [limit] bytes. Used only for codec and
/// doctype names, which always sit near the front of their container.
bool _containsAscii(Uint8List b, String needle, {required int limit}) {
  final end = b.length < limit ? b.length : limit;
  final codes = needle.codeUnits;
  for (var i = 0; i + codes.length <= end; i++) {
    var matched = true;
    for (var j = 0; j < codes.length; j++) {
      if (b[i + j] != codes[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

/// A RIFF container whose form type at byte 8 is [form].
bool _isRiff(Uint8List b, String form) =>
    _asciiAt(b, 0, 'RIFF') && _asciiAt(b, 8, form);
