import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/shortcuts.dart';
import 'package:weft/features/chat/chat_view.dart';

import 'support/golden_harness.dart';

/// ⌘V in a conversation.
///
/// The intent is invoked directly rather than by simulating the keystroke.
/// Driving a modifier chord through the test binding needs a platform to
/// resolve it against and, when it does not, waits for a paste that never
/// comes — two of four tests sat for ten minutes each. What is worth pinning is
/// the wiring on either side of the key: that ⌘V and Ctrl+V are bound to this
/// intent at all, and that invoking it does the right thing with each of the
/// two clipboards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadGoldenFonts);

  const channel = MethodChannel('com.bostrot.weft/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...List<int>.filled(64, 0),
  ]);

  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('weft-paste-widget'));
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Puts [names] on the clipboard, as the platform would report them.
  void clipboardHolds(List<String> names) {
    final entries = names.map((name) {
      final file = File('${temp.path}/$name')..writeAsBytesSync(png);
      return {'path': file.path, 'name': name};
    }).toList();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readImages') return entries;
      if (call.method == 'hasImage') return entries.isNotEmpty;
      return null;
    });
  }

  Future<void> paste(WidgetTester tester) async {
    await pumpWeft(
      tester,
      const ChatView(chatId: 'merged:anna'),
      surface: WeftSurface.mac,
      fileReader: (source, {int? maxBytes}) async => png,
    );
    // Under `runAsync`, because reading the clipboard touches a real file:
    // a test body runs in a `FakeAsync` zone where actual I/O never completes,
    // and the paste would sit on `File.length()` until the test timed out.
    await tester.runAsync(() async {
      // From inside the composer, which is where the shortcut is installed:
      // the action is deliberately not app-wide, so ⌘V anywhere else in Sennit
      // is still an ordinary paste.
      Actions.invoke(
        tester.element(find.byType(TextField).first),
        const PasteIntoComposerIntent(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  test('the composer binds paste under both conventions', () {
    final bound = composerShortcuts.entries
        .where((e) => e.value is PasteIntoComposerIntent)
        .map((e) => e.key)
        .cast<SingleActivator>()
        .toList();

    expect(
      bound.any((a) => a.trigger == LogicalKeyboardKey.keyV && a.meta),
      isTrue,
    );
    expect(
      bound.any((a) => a.trigger == LogicalKeyboardKey.keyV && a.control),
      isTrue,
      reason: 'Ctrl+V is the same key on Windows and Linux',
    );
  });

  testWidgets('pasting an image offers to send it', (tester) async {
    clipboardHolds(['shot.png']);
    await paste(tester);

    expect(
      find.text('shot.png'),
      findsWidgets,
      reason: 'the pasted picture reaches the same preview a picked file does',
    );
  });

  testWidgets('pasting several images offers all of them', (tester) async {
    clipboardHolds(['one.png', 'two.png']);
    await paste(tester);

    expect(find.text('one.png'), findsWidgets);
    expect(find.text('two.png'), findsWidgets);
  });

  testWidgets('a clipboard with no image opens nothing', (tester) async {
    clipboardHolds(const []);
    await paste(tester);

    expect(
      find.byType(BottomSheet),
      findsNothing,
      reason: 'text pastes are handed back to the framework untouched',
    );
  });

  testWidgets('a platform with no clipboard channel opens nothing', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, null);
    await paste(tester);

    expect(find.byType(BottomSheet), findsNothing);
  });
}
