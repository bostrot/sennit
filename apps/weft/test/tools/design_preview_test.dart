@Tags(['preview'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';

import '../support/golden_harness.dart';

/// The screens people live in, drawn to disk so a design change can be looked
/// at rather than imagined.
///
///   WEFT_PREVIEW_DIR=/somewhere flutter test \
///     test/tools/design_preview_test.dart --run-skipped
///
/// Asserts nothing and writes outside the repository, which is why it is
/// tagged out of an ordinary run. Shadows are drawn as shadows — the test
/// binding paints them as solid black boxes by default, which is right for a
/// layout golden and wrong for anything meant to be looked at.
void main() {
  final out = Platform.environment['WEFT_PREVIEW_DIR'];

  setUpAll(() async {
    await loadGoldenFonts();
    final emoji = File('/System/Library/Fonts/Apple Color Emoji.ttc');
    if (emoji.existsSync()) {
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(emoji.readAsBytesSync().buffer.asByteData()));
      await loader.load();
    }
  });
  setUp(clearMessageDocumentCache);

  const phone = Size(390, 844);
  const desk = Size(1280, 800);

  final scenes = <(String, Widget, Size, WeftSurface)>[
    ('phone_inbox', const InboxShell(), phone, WeftSurface.touch),
    (
      'phone_chat_merged',
      const ChatView(chatId: 'merged:anna'),
      phone,
      WeftSurface.touch,
    ),
    (
      'phone_chat_group',
      const ChatView(chatId: '!design_room:example.org'),
      phone,
      WeftSurface.touch,
    ),
    (
      'phone_chat_dm',
      const ChatView(chatId: '!konrad_wa_room:example.org'),
      phone,
      WeftSurface.touch,
    ),
    (
      'tablet_inbox',
      const InboxShell(),
      const Size(1024, 768),
      WeftSurface.touch,
    ),
    ('mac_window', const InboxShell(), desk, WeftSurface.mac),
    ('mac_chat', const ChatView(chatId: 'merged:anna'), desk, WeftSurface.mac),
  ];

  for (final (name, child, size, surface) in scenes) {
    for (final mode in [WeftThemeMode.light, WeftThemeMode.dark]) {
      testWidgets('$name ${mode.name}', (tester) async {
        if (out == null) return;
        debugDisableShadows = false;
        try {
          await pumpWeft(
            tester,
            RepaintBoundary(child: child),
            size: size,
            mode: mode,
            surface: surface,
          );
          await tester.pumpAndSettle();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byType(RepaintBoundary).first,
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            File('$out/${name}_${mode.name}.png')
              ..createSync(recursive: true)
              ..writeAsBytesSync(bytes!.buffer.asUint8List());
          });
        } finally {
          debugDisableShadows = true;
        }
      });
    }
  }
}
