@Tags(['preview'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';

import '../support/golden_harness.dart';

/// Renders the desktop shell to disk so it can be looked at.
///
/// Not a golden — nothing is compared. This is the working equivalent of
/// running the macOS app while iterating on its layout, without a five-minute
/// build in between. Tagged so it stays out of the ordinary run.
class _EmojiSample extends StatelessWidget {
  const _EmojiSample();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final style in [
            context.text.bodyMedium,
            context.text.bodySmall,
            context.text.labelSmall,
            context.text.titleSmall,
          ])
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              color: const Color(0x11FF0000),
              child: Text('Hi 🎉 ok 👍🏽 📷 Photo — end', style: style),
            ),
          const SizedBox(height: 8),
          const Text('Bare 22pt: 🎉👍📷', style: TextStyle(fontSize: 22)),
        ],
      ),
    ),
  );
}

void main() {
  setUpAll(loadGoldenFonts);

  const out = '/tmp/braid'
      '/fe50cf4a-2741-4781-85cc-71325a1d67dd/scratchpad';

  Future<void> shot(
    WidgetTester tester,
    String name, {
    required Widget child,
    Size size = const Size(1440, 900),
    WeftThemeMode mode = WeftThemeMode.dark,
  }) async {
    await pumpWeft(
      tester,
      RepaintBoundary(child: child),
      size: size,
      mode: mode,
      surface: WeftSurface.mac,
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('mac inbox', (tester) async {
    await shot(tester, 'mac_inbox', child: const InboxShell());
  });

  testWidgets('mac inbox light', (tester) async {
    await shot(
      tester,
      'mac_inbox_light',
      child: const InboxShell(),
      mode: WeftThemeMode.light,
    );
  });

  testWidgets('emoji sample', (tester) async {
    final emoji = File('/System/Library/Fonts/Apple Color Emoji.ttc');
    if (emoji.existsSync()) {
      final bytes = emoji.readAsBytesSync().buffer.asByteData();
      for (final family in const [
        'Roboto',
        '.AppleSystemUIFont',
        'CupertinoSystemText',
      ]) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
    await shot(
      tester,
      'emoji_sample',
      size: const Size(560, 260),
      mode: WeftThemeMode.light,
      child: const _EmojiSample(),
    );
  });

  testWidgets('mac chat', (tester) async {
    await shot(
      tester,
      'mac_chat',
      child: const ChatView(chatId: 'merged:anna'),
    );
  });
}
