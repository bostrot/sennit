import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:weft_attachments/weft_attachments.dart';

/// Images on the system clipboard.
///
/// Flutter's `Clipboard` is text only: `getData` takes a format and the only
/// one it accepts is `text/plain`. So ⌘V in a conversation with a screenshot
/// on the clipboard pasted nothing — on a desktop, the most ordinary way there
/// is to send a picture.
///
/// The platform hands back either a path (a file copied in the Finder, which
/// keeps its name and its exact bytes) or raw bytes (a screenshot, a browser's
/// "Copy Image"), and bytes are spooled to a temp file here so both arrive at
/// the send path as the same [AttachmentSource] a picker produces. Nothing
/// downstream needs to know a paste happened.
///
/// Silent everywhere the channel is not implemented. A platform without an
/// answer is a platform where ⌘V goes on pasting text, which is exactly what
/// it did before.
class ClipboardImages {
  const ClipboardImages({MethodChannel channel = _defaultChannel})
    : _channel = channel;

  static const _defaultChannel = MethodChannel('com.bostrot.weft/clipboard');

  final MethodChannel _channel;

  /// Whether a paste right now would produce a picture.
  ///
  /// Cheaper than [read] — it never copies bytes — and worth asking before
  /// putting a "Paste image" item in a menu.
  Future<bool> hasImage() async {
    try {
      return await _channel.invokeMethod<bool>('hasImage') ?? false;
    } on Object {
      return false;
    }
  }

  /// Every image on the clipboard, ready to send.
  ///
  /// Empty when there is none, when the platform has no implementation, or
  /// when the temp file could not be written — all three mean the same thing
  /// to the caller, which is "carry on and paste text".
  Future<List<AttachmentSource>> read() async {
    final List<Object?>? entries;
    try {
      entries = await _channel.invokeMethod<List<Object?>>('readImages');
    } on Object catch (error) {
      debugPrint('weft: clipboard image read failed: $error');
      return const [];
    }
    if (entries == null || entries.isEmpty) return const [];

    final sources = <AttachmentSource>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final source = await _toSource(entry);
      if (source != null) sources.add(source);
    }
    return sources;
  }

  Future<AttachmentSource?> _toSource(Map<Object?, Object?> entry) async {
    final name = entry['name'] as String? ?? 'Pasted image.png';

    final path = entry['path'] as String?;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (!file.existsSync()) return null;
      return _sourceForFile(file, name: path);
    }

    final bytes = entry['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) return null;
    final spooled = await _spool(bytes, name);
    return spooled == null ? null : _sourceForFile(spooled, name: spooled.path);
  }

  /// Writes clipboard bytes somewhere the send path can read them from.
  ///
  /// The whole pipeline below this — the preview sheet's thumbnail, the mime
  /// sniff, the upload — is built on a file that exists on disk, and giving
  /// pasted bytes a file is a great deal less invasive than teaching all of it
  /// about a second kind of source.
  Future<File?> _spool(Uint8List bytes, String name) async {
    try {
      final dir = Directory('${(await _tempRoot()).path}/pasted')
        ..createSync(recursive: true);
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } on Object catch (error) {
      debugPrint('weft: could not spool a pasted image: $error');
      return null;
    }
  }

  /// Where a pasted image is spooled.
  ///
  /// `path_provider` first, because on a phone it is the only answer that is
  /// certainly writable and certainly cleaned up. It is a method channel
  /// though, so it has somewhere to fail — a test, a headless run — and on
  /// every desktop the process's own temp directory is a perfectly good place
  /// for a file that lives until it has been uploaded.
  Future<Directory> _tempRoot() async {
    try {
      return await getTemporaryDirectory();
    } on Object {
      return Directory.systemTemp;
    }
  }

  Future<AttachmentSource> _sourceForFile(
    File file, {
    required String name,
  }) async {
    final size = await file.length();
    // The same 4kB the picker reads: enough for every magic number the sniffer
    // knows, and it never trusts a declared type over the bytes anyway.
    final handle = await file.open();
    try {
      return AttachmentSource(
        filename: name,
        sizeBytes: size,
        header: await handle.read(size < 4096 ? size : 4096),
      );
    } finally {
      await handle.close();
    }
  }
}
