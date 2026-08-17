import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart' as picker;
import 'package:weft_attachments/weft_attachments.dart';

/// Bytes read from the front of a picked file to fill [AttachmentSource.header].
///
/// Everything `weft_attachments` decides — the sniffed mime type, the msgtype,
/// the pixel dimensions — is decided from this slice, and a 200 MB video must
/// not be pulled into memory to answer "is this an mp4?". 64 KiB is comfortably
/// past a JPEG's EXIF block and past the `ftyp`/`moov` boxes of every file that
/// front-loads them, while staying small enough that picking twenty photos costs
/// about a megabyte.
const int kAttachmentHeaderBytes = 64 * 1024;

/// Where a picked file is coming from.
///
/// One enum plus one method rather than three methods, because the source sheet
/// is then a table of rows and a fake picker is a single `switch` — the split
/// between `image_picker` and `file_selector` is an implementation detail the
/// composer has no business knowing.
enum AttachmentPickSource {
  /// Photos and videos, from the platform's own media gallery when it has one.
  media,

  /// Any file at all, from the platform's document browser.
  files,

  /// A photo taken now. Mobile only — [AttachmentPicker.supports] says so.
  camera,
}

/// Picks files to send, in whatever way the platform actually does that.
///
/// An interface rather than a set of top-level functions because both plugins
/// behind it are method channels: a widget test that calls one gets a
/// `MissingPluginException`, so the composer's tests override this provider with
/// a fake and exercise the sheet, the preview and the send without a platform.
abstract class AttachmentPicker {
  /// Whether [source] can be offered at all on this platform. A desktop with no
  /// camera should not show a camera row that fails when tapped.
  bool supports(AttachmentPickSource source);

  /// Runs the platform picker, returning one source per file chosen.
  ///
  /// Empty means the user cancelled, which is not an error and must not surface
  /// as one.
  Future<List<AttachmentSource>> pick(AttachmentPickSource source);
}

/// The real picker: `image_picker` for the mobile gallery and camera,
/// `file_selector` for documents and for everything on desktop.
///
/// Two plugins rather than one because they answer different questions.
/// `image_picker` reaches the *photo library* — the grid the user thinks of as
/// "my photos", with the OS's own limited-access picker on iOS and Android 13+
/// — while `file_selector` reaches the *file system*. Offering only the second
/// on a phone makes sending a photo a hunt through Downloads.
class PlatformAttachmentPicker implements AttachmentPicker {
  const PlatformAttachmentPicker();

  /// Type groups for the desktop "photo or video" row.
  ///
  /// Extensions rather than mime types: `file_selector` maps them per platform,
  /// and a bare `image/*` is not expressible in a Windows file dialog filter.
  static const List<XTypeGroup> _mediaTypes = [
    XTypeGroup(
      label: 'Photos and videos',
      extensions: [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'heic',
        'bmp',
        'tiff',
        'mp4',
        'mov',
        'm4v',
        'webm',
        'mkv',
        'avi',
      ],
    ),
  ];

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  bool supports(AttachmentPickSource source) =>
      source == AttachmentPickSource.camera ? _isMobile : true;

  @override
  Future<List<AttachmentSource>> pick(AttachmentPickSource source) async {
    final files = switch (source) {
      AttachmentPickSource.media when _isMobile =>
        await picker.ImagePicker().pickMultipleMedia(),
      AttachmentPickSource.media => await openFiles(
        acceptedTypeGroups: _mediaTypes,
      ),
      AttachmentPickSource.files => await openFiles(),
      AttachmentPickSource.camera => [
        ?await picker.ImagePicker().pickImage(
          source: picker.ImageSource.camera,
        ),
      ],
    };

    return [for (final file in files) await attachmentSourceForFile(file)];
  }
}

/// Describes [file] the way `weft_attachments` expects: a name, a real length,
/// and a leading slice.
///
/// [AttachmentSource.filename] carries the file's **path**, not its display
/// name, because that path is what the repository's byte loader opens when the
/// upload actually runs — `basename` is what becomes the event's `body`. The
/// source is therefore only valid while the file is still there, which holds for
/// both a document the user chose and the cache copy `image_picker` makes.
Future<AttachmentSource> attachmentSourceForFile(XFile file) async {
  final size = await file.length();
  return AttachmentSource(
    // A picker that reports no path at all (a platform that hands back bytes)
    // still has a name, and a name is what the sniffer's extension fallback
    // needs.
    filename: file.path.isEmpty ? file.name : file.path,
    sizeBytes: size,
    header: await _readHeader(file, size),
    // Frequently a lie, and often `application/octet-stream`; `sniffMimeType`
    // treats it as the hint it is and prefers the bytes.
    declaredMimeType: file.mimeType,
  );
}

/// The first [kAttachmentHeaderBytes] of [file], or the whole thing when it is
/// smaller.
///
/// Streamed rather than `readAsBytes()`-then-sublist: the point of a header
/// slice is that the rest of the file is never read, and a picked 4 GB video
/// would otherwise be loaded into memory to be immediately thrown away.
Future<Uint8List> _readHeader(XFile file, int size) async {
  final wanted = size > 0 && size < kAttachmentHeaderBytes
      ? size
      : kAttachmentHeaderBytes;
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, wanted)) {
    builder.add(chunk);
    if (builder.length >= wanted) break;
  }
  return builder.takeBytes();
}

/// The picker the composer uses. Overridden in tests with a fake, because every
/// implementation behind it is a method channel.
final attachmentPickerProvider = Provider<AttachmentPicker>(
  (ref) => const PlatformAttachmentPicker(),
);
