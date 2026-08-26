import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/attachments/clipboard_images.dart';

/// Pasting a picture into a conversation.
///
/// Flutter's `Clipboard` is text only, so ⌘V with a screenshot on the clipboard
/// used to do nothing at all — on a desktop, the most ordinary way there is to
/// send an image. What is asserted here is the seam: what the platform hands
/// back, in both of the shapes it comes in, becomes the same `AttachmentSource`
/// a file picker produces, so nothing downstream has to know a paste happened.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bostrot.weft/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// The bytes of a one-pixel PNG, magic number and all, so the mime sniffer
  /// downstream has something true to read.
  final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...List<int>.filled(64, 0),
  ]);

  void answer(Object? reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readImages') return reply;
      if (call.method == 'hasImage') {
        return reply is List && reply.isNotEmpty;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  test('an empty clipboard produces nothing', () async {
    answer(<Object?>[]);
    expect(await const ClipboardImages().read(), isEmpty);
    expect(await const ClipboardImages().hasImage(), isFalse);
  });

  test('a platform with no implementation is silent', () async {
    // Not an error and not a crash: ⌘V goes on pasting text, exactly as it did
    // before this existed. Windows and Linux are here until their channels are.
    messenger.setMockMethodCallHandler(channel, null);
    expect(await const ClipboardImages().read(), isEmpty);
    expect(await const ClipboardImages().hasImage(), isFalse);
  });

  test('a copied file is used where it lies', () async {
    final file = File(
      '${Directory.systemTemp.createTempSync('weft-paste').path}/shot.png',
    )..writeAsBytesSync(png);
    answer([
      {'path': file.path, 'name': 'shot.png'},
    ]);

    final sources = await const ClipboardImages().read();
    expect(sources, hasLength(1));
    expect(
      sources.single.filename,
      file.path,
      reason: 'the original file, not a re-encoded copy of it',
    );
    expect(sources.single.basename, 'shot.png');
    expect(sources.single.sizeBytes, png.length);
    expect(sources.single.header.take(4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('a file that has since gone is dropped, not faked', () async {
    answer([
      {'path': '/nowhere/at/all/shot.png', 'name': 'shot.png'},
    ]);
    expect(await const ClipboardImages().read(), isEmpty);
  });

  test('raw bytes are spooled to a file the send path can read', () async {
    answer([
      {'bytes': png, 'name': 'Pasted 2026-08-26 at 10.00.00.png'},
    ]);

    final sources = await const ClipboardImages().read();
    expect(sources, hasLength(1));

    final spooled = File(sources.single.filename);
    expect(spooled.existsSync(), isTrue);
    expect(spooled.readAsBytesSync(), png);
    expect(
      sources.single.basename,
      'Pasted 2026-08-26 at 10.00.00.png',
      reason: 'a timestamped name, not "image.png" twenty times over',
    );
    addTearDown(() => spooled.parent.deleteSync(recursive: true));
  });

  test('several images come back in order', () async {
    final dir = Directory.systemTemp.createTempSync('weft-paste-many');
    final one = File('${dir.path}/one.png')..writeAsBytesSync(png);
    final two = File('${dir.path}/two.png')..writeAsBytesSync(png);
    answer([
      {'path': one.path, 'name': 'one.png'},
      {'path': two.path, 'name': 'two.png'},
    ]);

    final sources = await const ClipboardImages().read();
    expect(sources.map((s) => s.basename), ['one.png', 'two.png']);
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  test('an entry with neither a path nor bytes is skipped', () async {
    answer([
      <String, Object?>{'name': 'nothing.png'},
      {'bytes': Uint8List(0), 'name': 'empty.png'},
    ]);
    expect(await const ClipboardImages().read(), isEmpty);
  });

  test('a channel that throws is treated as an empty clipboard', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    expect(await const ClipboardImages().read(), isEmpty);
    expect(await const ClipboardImages().hasImage(), isFalse);
  });
}
