/// Byte-level fixtures for the detection tests.
///
/// Every format below is built from literals rather than checked in as a real
/// file. That keeps the repo free of binaries, but more importantly it makes the
/// interesting cases — a zero-width GIF, a version 1 `tkhd`, a `moov` that never
/// arrives — constructible, which they would not be with sample media.
///
/// The formatter is switched off below: these are byte tables, and one byte per
/// line hides the very structure the tests are about.
library;

import 'package:weft_attachments/weft_attachments.dart';

// dart format off

List<int> _u16be(int v) => [(v >> 8) & 0xFF, v & 0xFF];

List<int> _u16le(int v) => [v & 0xFF, (v >> 8) & 0xFF];

List<int> _u24le(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF];

List<int> _u32be(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

List<int> _u32le(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

/// An ISO-BMFF box: 32-bit size, four-character type, content.
List<int> box(String type, List<int> content) =>
    [..._u32be(8 + content.length), ...type.codeUnits, ...content];

/// The same box with the size escape hatch: size 1, then a 64-bit largesize.
List<int> largeBox(String type, List<int> content) => [
      ..._u32be(1), ...type.codeUnits,
      ..._u32be(0), ..._u32be(16 + content.length),
      ...content,
    ];

List<int> png({required int width, required int height}) => [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ..._u32be(13), ...'IHDR'.codeUnits,
      ..._u32be(width), ..._u32be(height),
      8, 6, 0, 0, 0, // bit depth, colour type, compression, filter, interlace
      ..._u32be(0), // CRC placeholder
    ];

/// A JPEG with an APP1 segment ahead of the frame header, so the parser has to
/// actually walk segments rather than assume a fixed offset.
///
/// [sofMarker] picks baseline (0xC0) or progressive (0xC2). [extraSegmentMarker]
/// injects one more segment before the frame header — pass 0xC4 to prove a
/// Huffman table inside the SOFn marker range is not mistaken for a frame.
List<int> jpeg({
  required int width,
  required int height,
  int sofMarker = 0xC0,
  int? extraSegmentMarker,
}) => [
      0xFF, 0xD8, // start of image
      0xFF, 0xE1, ..._u16be(10), ...'Exif'.codeUnits, 0, 0, 0, 0,
      if (extraSegmentMarker != null)
        ...[0xFF, extraSegmentMarker, ..._u16be(6), 0, 1, 2, 3],
      0xFF, sofMarker, ..._u16be(17),
      8, // sample precision
      ..._u16be(height), ..._u16be(width),
      3, // component count
      1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
      0xFF, 0xDA, ..._u16be(8), 1, 1, 0, 0, 0x3F, 0, // start of scan
      0x00, 0x00,
    ];

List<int> gif({required int width, required int height}) => [
      ...'GIF89a'.codeUnits,
      ..._u16le(width), ..._u16le(height),
      0xF7, 0x00, 0x00, // packed fields, background index, aspect ratio
    ];

List<int> _riff(String form, List<int> body) =>
    [...'RIFF'.codeUnits, ..._u32le(4 + body.length), ...form.codeUnits, ...body];

List<int> webpLossy({required int width, required int height}) =>
    _riff('WEBP', [
      ...'VP8 '.codeUnits, ..._u32le(14),
      0x00, 0x00, 0x00, // frame tag
      0x9D, 0x01, 0x2A, // start code
      ..._u16le(width), ..._u16le(height),
      0x00, 0x00,
    ]);

List<int> webpLossless({required int width, required int height}) {
  // 14 bits of width-1 and 14 of height-1, packed little-endian.
  final bits = (width - 1) | ((height - 1) << 14);
  return _riff('WEBP', [
    ...'VP8L'.codeUnits, ..._u32le(5),
    0x2F, // lossless signature
    ..._u32le(bits),
  ]);
}

List<int> webpExtended({required int width, required int height}) =>
    _riff('WEBP', [
      ...'VP8X'.codeUnits, ..._u32le(10),
      0x10, 0x00, 0x00, 0x00, // flags + reserved
      ..._u24le(width - 1), ..._u24le(height - 1),
    ]);

List<int> wav() =>
    _riff('WAVE', [...'fmt '.codeUnits, ..._u32le(16), ...List.filled(16, 0)]);

/// A bare `ftyp` box, which is all the sniffer needs to name the family.
List<int> isoBaseMedia({required String brand}) =>
    box('ftyp', [...brand.codeUnits, ..._u32be(512), ...brand.codeUnits]);

/// An MP4 whose `moov` sits up front, carrying one `trak` per entry in
/// [dimensions]. A 0x0 entry stands in for an audio track.
List<int> mp4WithTracks(
  List<MediaDimensions> dimensions, {
  int tkhdVersion = 0,
  bool largeMoovSize = false,
}) {
  final traks = <int>[];
  for (final size in dimensions) {
    final timingBytes = tkhdVersion == 1 ? 32 : 20;
    final tkhd = box('tkhd', [
      tkhdVersion, 0x00, 0x00, 0x07, // version + flags
      ...List.filled(timingBytes, 0), // creation, modification, id, duration
      ...List.filled(52, 0), // reserved, layer, volume, transform matrix
      ..._u32be(size.width << 16), // 16.16 fixed point
      ..._u32be(size.height << 16),
    ]);
    traks.addAll(box('trak', tkhd));
  }

  final moov = largeMoovSize ? largeBox('moov', traks) : box('moov', traks);
  return [...isoBaseMedia(brand: 'isom'), ...moov];
}

/// An EBML header followed by its doctype string, which is the only thing
/// separating WebM from generic Matroska.
List<int> webm({String docType = 'webm'}) => [
      0x1A, 0x45, 0xDF, 0xA3, // EBML magic
      0x01, 0x00, 0x00, 0x00,
      0x42, 0x82, 0x84, ...docType.codeUnits, // DocType element
      ...List.filled(8, 0),
    ];

/// An Ogg page whose first packet names the codec.
List<int> ogg({String codec = 'opus'}) => [
      ...'OggS'.codeUnits,
      0x00, 0x02, // version, header type
      ...List.filled(20, 0), // granule position, serial, sequence, checksum
      0x01, 0x1E, // segment table
      ...(codec == 'opus' ? 'OpusHead'.codeUnits : codec.codeUnits),
      ...List.filled(8, 0),
    ];

/// MP3 with an ID3v2 tag in front, which is how virtually every real file
/// arrives.
List<int> mp3() => [
      ...'ID3'.codeUnits,
      0x04, 0x00, 0x00, // version, revision, flags
      0x00, 0x00, 0x00, 0x0A, // synchsafe tag size
      ...List.filled(10, 0),
    ];

List<int> pdf() => [...'%PDF-1.7'.codeUnits, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3];

/// A ZIP local file header — shared verbatim by docx, xlsx, epub, apk and jar.
List<int> zip() => [
      0x50, 0x4B, 0x03, 0x04, // PK\x03\x04
      0x14, 0x00, 0x00, 0x00, 0x08, 0x00,
      ...List.filled(16, 0),
    ];
