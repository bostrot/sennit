/// Getting a staged attachment back out of Weft: to a place the user picks, or
/// to another app entirely.
library;

import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' as sharing;
import 'package:weft_attachments/weft_attachments.dart';

import 'attachment_picker.dart';

/// Hands a file to the platform, either to save or to share.
///
/// An interface for the same reason [AttachmentPicker] is one — both
/// implementations behind it are method channels, and a widget test that reaches
/// one gets a `MissingPluginException` — so without the seam the viewer's whole
/// action bar would be untestable. Overriding [mediaExporterProvider] replaces
/// the file dialog and the share sheet and leaves everything else real.
abstract class MediaExporter {
  /// Whether a save destination can be chosen on this platform at all.
  ///
  /// False on Android and iOS, where `file_selector` has no save dialog and the
  /// system share sheet *is* the way a file reaches Files or Photos. The viewer
  /// reads this rather than offering a Save button that throws when tapped.
  bool get canSave;

  /// Copies [file] somewhere the user picks. Returns where it went, or null if
  /// they cancelled — which is not an error and must not be reported as one.
  Future<String?> save(File file, {required String suggestedName});

  /// Hands [file] to the platform's share sheet.
  ///
  /// [origin] anchors the popover on iPad and macOS; without it the sheet
  /// appears in the middle of the screen with no relationship to what was
  /// tapped.
  Future<void> share(File file, {String? mimeType, String? text, Rect? origin});
}

/// The real one: `file_selector` for Save, `share_plus` for Share.
class PlatformMediaExporter implements MediaExporter {
  const PlatformMediaExporter();

  static bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  bool get canSave => !_isMobile;

  @override
  Future<String?> save(File file, {required String suggestedName}) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      // The extension the file actually has, offered as the one filter, so the
      // dialog does not quietly append `.txt` to a photo on Windows.
      acceptedTypeGroups: _typeGroupsFor(suggestedName),
    );
    if (location == null) return null;

    // `copy` rather than reading and writing the bytes: the staged file may be a
    // 200 MB video, and the OS can move it without any of it passing through
    // this isolate.
    await file.copy(location.path);
    return location.path;
  }

  @override
  Future<void> share(
    File file, {
    String? mimeType,
    String? text,
    Rect? origin,
  }) async {
    await sharing.SharePlus.instance.share(
      sharing.ShareParams(
        files: [sharing.XFile(file.path, mimeType: mimeType)],
        text: text,
        sharePositionOrigin: origin,
      ),
    );
  }

  static List<XTypeGroup> _typeGroupsFor(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return const [];
    final extension = name.substring(dot + 1).toLowerCase();
    return [
      XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
    ];
  }
}

/// The mime type to announce for a staged file.
///
/// Sniffed from the bytes that are now actually on disk rather than guessed from
/// the name, reusing the sniffer the send path uses: a receiving app decides how
/// to open what it is given from this string, and a photo announced as
/// `application/octet-stream` lands in a file manager instead of a gallery.
/// Only [kAttachmentHeaderBytes] are read — the same slice the send path works
/// from, and the whole point of the sniffer is that it never needs more.
///
/// Synchronous, which for once is the better of the two: 64 KiB off a local file
/// is beneath noticing next to the share sheet that follows it, and an async
/// read here would sit unresolved in every widget test's fake-async zone and put
/// the Save and Share actions out of reach of `flutter test` entirely.
String stagedMimeType(File file) {
  final length = file.lengthSync();
  final wanted = length < kAttachmentHeaderBytes
      ? length
      : kAttachmentHeaderBytes;
  final handle = file.openSync();
  try {
    return sniffMimeType(
      AttachmentSource(
        filename: file.path,
        sizeBytes: length,
        header: handle.readSync(wanted),
      ),
    );
  } finally {
    handle.closeSync();
  }
}

/// The exporter the viewer's Save and Share actions run through. Overridden in
/// tests with a fake, because both plugins behind it are method channels.
final mediaExporterProvider = Provider<MediaExporter>(
  (ref) => const PlatformMediaExporter(),
);
