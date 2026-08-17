import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:weft/app/session_providers.dart';
import 'package:weft/features/chat/attachment_bubble.dart';
import 'package:weft/features/chat/attachment_preview_sheet.dart';
import 'package:weft/features/chat/media_viewer.dart';
import 'package:weft/main.dart';
import 'package:weft/services/attachments/attachment_picker.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';

import '../test/support/attachment_fixtures.dart';

/// The attachment send loop, driven against a real engine on a real desktop.
///
///   cd apps/weft
///   flutter test integration_test/attachment_flow_test.dart -d macos \
///     --dart-define=WEFT_DEMO=true
///
/// Everything here is also covered by `test/attachment_bubble_test.dart` and
/// `test/media_viewer_test.dart`, and this is deliberately not a duplicate of
/// them: `flutter test` runs in a headless `FakeAsync` zone where **no image
/// ever decodes** — `Image.memory` resolves its frame through the engine's
/// codec, which is real asynchronous work the fake clock never advances. Every
/// picture in those suites is therefore either primed by hand or a placeholder,
/// and a decoded picture has no hit area to tap. Run on a device, with a real
/// event loop and a real rasteriser, the photo decodes, the tap lands, and the
/// progress bubble ticks on a real 140 ms timer — which is the only way to
/// answer "does this actually work on macOS?" without a person watching it.
///
/// Only the picker is faked, because it is the one step that cannot be driven:
/// a real `NSOpenPanel` is a modal the test cannot dismiss. Everything after it
/// — reading the picked file off disk, the header slice, the plan, the queue,
/// the progress stream, the settled bubble and the full-screen viewer — is the
/// production path.
///
/// Pass `--dart-define=WEFT_SHOT_DIR=/some/dir` to write a PNG of each step. The
/// images are the record of the run; without the define nothing is written, so
/// the test leaves no files behind on anyone else's machine.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const shotDir = String.fromEnvironment('WEFT_SHOT_DIR');
  final rootKey = GlobalKey();

  late Directory temp;
  late File photo;
  Directory? shots;

  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('weft-attachment-flow-');
    // A real file, because the send path opens `AttachmentSource.filename` for
    // itself: 400x225 of flat bands, the same fixture the goldens use.
    photo = File(p.join(temp.path, 'holiday.png'))..writeAsBytesSync(kPhoto);

    if (shotDir.isEmpty) return;
    try {
      shots = Directory(shotDir)..createSync(recursive: true);
    } on FileSystemException {
      // Deliberately not under [temp], which is deleted when the run ends: the
      // images are the point of asking for them.
      shots = Directory.systemTemp.createTempSync('weft-shots-');
    }
    debugPrint('weft: writing step images to ${shots!.path}');
  });

  tearDownAll(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Writes what is on screen to `WEFT_SHOT_DIR`, if there is one.
  ///
  /// Captures the app's own boundary rather than the root view: the live
  /// binding paints its own test scaffolding around the tree, and a record of
  /// the run should show the app and not the harness.
  ///
  /// The macOS app is sandboxed, so a path outside its container is *not*
  /// writable however absolute it looks — `Documents/…` throws `Operation not
  /// permitted`. The requested directory is therefore tried and then given up
  /// on in favour of the container's own temp, whose real location is printed:
  /// silently writing nothing would look exactly like a passing run.
  Future<void> shot(WidgetTester tester, String name) async {
    final target = shots;
    if (target == null) return;
    final boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return;
    File(
      p.join(target.path, '$name.png'),
    ).writeAsBytesSync(data.buffer.asUint8List());
  }

  /// Pumps real frames until [finder] matches, or gives up.
  ///
  /// `pumpAndSettle` is the wrong tool for an upload: the progress bubble is
  /// driven by a timer between frames, so the tree settles repeatedly while the
  /// upload is still going and settling proves nothing about it.
  Future<bool> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 40));
      if (finder.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  Future<bool> pumpUntilGone(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 40));
      if (finder.evaluate().isEmpty) return true;
    }
    return false;
  }

  testWidgets('a photo can be sent, watched, and opened full screen', (
    tester,
  ) async {
    expect(
      kDemoMode,
      isTrue,
      reason:
          'Run with --dart-define=WEFT_DEMO=true: without it the app reaches '
          'for a homeserver and this test is about the UI over the pipeline.',
    );

    final picker = _StagedPicker(photo);
    await tester.pumpWidget(
      ProviderScope(
        // The only override. The repository, the queue, the transport and the
        // renderer are all the ones a `flutter run --dart-define=WEFT_DEMO=true`
        // would use.
        overrides: [attachmentPickerProvider.overrideWithValue(picker)],
        child: RepaintBoundary(key: rootKey, child: const WeftApp()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ChatTile), findsWidgets);
    await shot(tester, '01-inbox');

    await tester.tap(find.byType(ChatTile).first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Attach'), findsOneWidget);
    await shot(tester, '02-chat');

    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    expect(find.text('Photo or video'), findsOneWidget);
    // A desktop has no camera row, and that is the picker's `supports` answer
    // rather than the sheet's guess.
    expect(find.text('Camera'), findsNothing);
    await shot(tester, '03-source-sheet');

    await tester.tap(find.text('Photo or video'));
    await tester.pumpAndSettle();

    expect(picker.asked, AttachmentPickSource.media);
    expect(find.text('Send 1 file'), findsOneWidget);
    // The preview reads the real file through the same loader the send path
    // uses, so this is a decoded picture and not an icon.
    expect(
      find.descendant(
        of: find.byType(AttachmentSourceThumbnail),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    await shot(tester, '04-preview');

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));

    expect(
      await pumpUntil(tester, find.byType(LinearProgressIndicator)),
      isTrue,
      reason: 'the upload must be visible while it is in flight',
    );
    // A bubble the user cannot get out of is worse than no bubble.
    expect(find.byTooltip('Cancel upload'), findsOneWidget);
    await shot(tester, '05-uploading');

    expect(
      await pumpUntilGone(tester, find.byType(LinearProgressIndicator)),
      isTrue,
      reason: 'the upload must finish and stop being an upload',
    );
    await tester.pumpAndSettle();

    final picture = find.descendant(
      of: find.byType(MediaAttachment),
      matching: find.byType(Image),
    );

    // Reopening the chat, and this is the one thing this run found that the
    // widget suites could not: `ChatView` reads its timeline **once**, in
    // `_open`, and never again. A message that lands while the thread is on
    // screen — the photo that just finished uploading, and equally a text sent
    // in demo mode or an event arriving from a sync — is not in `_view`, so the
    // upload bubble disappears as the task leaves the queue and nothing takes
    // its place until the chat is opened again. The inbox tile updates, because
    // it watches a stream. Recorded in the phase notes; a live timeline is a
    // change to how `ChatView` refreshes rather than anything in the attachment
    // pipeline, so it is not made here. Reopen and carry on — and if this is
    // ever fixed, this still passes.
    if (picture.evaluate().isEmpty) {
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatTile).first);
      await tester.pumpAndSettle();
    }

    final settled = await pumpUntil(tester, picture);
    await shot(tester, '06-sent');
    expect(
      settled,
      isTrue,
      reason: 'the settled bubble shows the photo that was just sent',
    );
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);

    // The tap the widget suites cannot make: under `flutter test` the decoded
    // picture never exists, so there is nothing at these coordinates to hit.
    await tester.tap(picture.first);
    expect(await pumpUntil(tester, find.byType(MediaViewer)), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('You'), findsWidgets);
    expect(
      find.descendant(
        of: find.byType(MediaViewer),
        matching: find.byType(Image),
      ),
      findsWidgets,
    );
    await shot(tester, '07-viewer');
  });
}

/// Hands back a file already staged on disk.
///
/// Both real implementations open a platform modal — an `NSOpenPanel` on macOS
/// — which a test cannot dismiss, so this is the one seam that has to be faked
/// for the flow to be drivable at all. It still goes through
/// [attachmentSourceForFile], so the size, the 64 KiB header slice and the
/// declared mime type are read from the real file exactly as the composer reads
/// them.
class _StagedPicker implements AttachmentPicker {
  _StagedPicker(this.file);

  final File file;
  AttachmentPickSource? asked;

  @override
  bool supports(AttachmentPickSource source) =>
      source != AttachmentPickSource.camera;

  @override
  Future<List<AttachmentSource>> pick(AttachmentPickSource source) async {
    asked = source;
    return [await attachmentSourceForFile(XFile(file.path))];
  }
}
