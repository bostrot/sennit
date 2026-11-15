import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';

import '../support/golden_harness.dart';

/// Renders the App Store / Play Store screenshots from the demo fixtures.
///
/// The same trick as `brand_assets_test.dart`: a test, because rasterising
/// widgets needs a Flutter binding, writing real files under
/// `tooling/store/screenshots/`. The scenes lay out at the device's logical
/// size and are captured at its scale factor, which yields exactly the pixel
/// dimensions the stores demand — 1320×2868 for the 6.9" iPhone, 2064×2752
/// for the 13" iPad — with no simulator involved (the ffmpeg plugin ships no
/// arm64 simulator slice, so iOS 26 simulators cannot run the app at all).
void main() {
  setUpAll(() async {
    await loadGoldenFonts();
    // Marketing images only: the demo fixtures carry emoji, and without a
    // color-emoji face they render as tofu boxes — fine in a layout golden,
    // not in a store screenshot. Registered as an extra Roboto face so the
    // engine consults it for the glyphs Roboto lacks; macOS-only by nature,
    // which is where these images are produced anyway.
    final emoji = File('/System/Library/Fonts/Apple Color Emoji.ttc');
    if (emoji.existsSync()) {
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(emoji.readAsBytesSync().buffer.asByteData()));
      await loader.load();
    }
  });

  const outDir = '../../tooling/store/screenshots';

  Future<void> capture(
    WidgetTester tester,
    String name, {
    required Widget child,
    required Size logical,
    required double scale,
    WeftThemeMode mode = WeftThemeMode.light,
    String? chatToOpen,
  }) async {
    // Shadows as shadows. The test binding paints every shadow as a solid
    // black box so that goldens do not depend on a blur — which is why the
    // compose button in the published store screenshots wore a thick black
    // frame. Put back before the test body ends, which is when the framework
    // checks that it was.
    debugDisableShadows = false;
    try {
      await pumpWeft(
        tester,
        RepaintBoundary(child: child),
        size: logical,
        mode: mode,
      );
      await tester.pumpAndSettle();

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: scale);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$outDir/$name.png')..createSync(recursive: true);
        file.writeAsBytesSync(bytes!.buffer.asUint8List());
        expect(image.width, (logical.width * scale).round(), reason: name);
        expect(image.height, (logical.height * scale).round(), reason: name);
      });
    } finally {
      debugDisableShadows = true;
    }
  }

  // 6.9" iPhone: 440×956 points at 3× — 1320×2868.
  const iphone = Size(440, 956);
  // 13" iPad, portrait: 1032×1376 points at 2× — 2064×2752.
  const ipad = Size(1032, 1376);

  testWidgets('iphone inbox light', (tester) async {
    await capture(
      tester,
      'iphone_69_01_inbox_light',
      child: const InboxShell(),
      logical: iphone,
      scale: 3,
    );
  });

  testWidgets('iphone chat light', (tester) async {
    await capture(
      tester,
      'iphone_69_02_chat_light',
      child: const ChatView(chatId: 'merged:anna'),
      logical: iphone,
      scale: 3,
    );
  });

  testWidgets('iphone inbox dark', (tester) async {
    await capture(
      tester,
      'iphone_69_03_inbox_dark',
      child: const InboxShell(),
      logical: iphone,
      scale: 3,
      mode: WeftThemeMode.dark,
    );
  });

  testWidgets('iphone chat dark', (tester) async {
    await capture(
      tester,
      'iphone_69_04_chat_dark',
      child: const ChatView(chatId: 'merged:anna'),
      logical: iphone,
      scale: 3,
      mode: WeftThemeMode.dark,
    );
  });

  testWidgets('ipad inbox light two-pane', (tester) async {
    await capture(
      tester,
      'ipad_13_01_inbox_light',
      child: const InboxShell(),
      logical: ipad,
      scale: 2,
    );
  });

  testWidgets('ipad inbox dark two-pane', (tester) async {
    await capture(
      tester,
      'ipad_13_02_inbox_dark',
      child: const InboxShell(),
      logical: ipad,
      scale: 2,
      mode: WeftThemeMode.dark,
    );
  });

  // Google Play is strict about aspect ratio: phone shots must be 16:9 or
  // 9:16, and the Apple sets above are 9:19.6 — the shape of a modern iPhone,
  // which Play rejects outright. These are exactly 9:16 and 16:9.
  const playPhone = Size(360, 640);
  const playTablet = Size(960, 540);

  testWidgets('play phone inbox light', (tester) async {
    await capture(
      tester,
      'play_phone_01_inbox_light',
      child: const InboxShell(),
      logical: playPhone,
      scale: 3,
    );
  });

  testWidgets('play phone chat light', (tester) async {
    await capture(
      tester,
      'play_phone_02_chat_light',
      child: const ChatView(chatId: 'merged:anna'),
      logical: playPhone,
      scale: 3,
    );
  });

  testWidgets('play phone inbox dark', (tester) async {
    await capture(
      tester,
      'play_phone_03_inbox_dark',
      child: const InboxShell(),
      logical: playPhone,
      scale: 3,
      mode: WeftThemeMode.dark,
    );
  });

  testWidgets('play phone chat dark', (tester) async {
    await capture(
      tester,
      'play_phone_04_chat_dark',
      child: const ChatView(chatId: 'merged:anna'),
      logical: playPhone,
      scale: 3,
      mode: WeftThemeMode.dark,
    );
  });

  testWidgets('play tablet inbox light', (tester) async {
    await capture(
      tester,
      'play_tablet_01_inbox_light',
      child: const InboxShell(),
      logical: playTablet,
      scale: 2,
    );
  });

  testWidgets('play tablet inbox dark', (tester) async {
    await capture(
      tester,
      'play_tablet_02_inbox_dark',
      child: const InboxShell(),
      logical: playTablet,
      scale: 2,
      mode: WeftThemeMode.dark,
    );
  });
}
