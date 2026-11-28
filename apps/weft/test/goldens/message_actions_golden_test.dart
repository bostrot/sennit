import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/features/chat/emoji_picker_sheet.dart';
import 'package:weft/features/chat/message_actions_sheet.dart';

import '../support/golden_harness.dart';

/// Goldens for the long-press sheet.
///
/// `message_actions_sheet_test.dart` pins that the quick row is one line and
/// that no `mxc://` URI is drawn. What only an image holds anyone to is the
/// sheet reading as one: the row of reactions at the top with the picker
/// button closing it, the divider, then the actions — not the four emoji
/// spread across the sheet with a URI under them and the rest on a third line,
/// which is what a reader with a custom emoji in their recents was shown.
///
/// The recents here include such an emoji, so the image is of the case that
/// broke. The emoji draw as placeholder boxes, as in `rich_reactions`.
void main() {
  setUpAll(loadGoldenFonts);

  const phone = Size(390, 844);
  final message = WeftMessage(
    eventId: r'$m1',
    roomId: '!r:example.org',
    network: ChatNetwork.whatsapp,
    senderId: '@anna:example.org',
    senderName: 'Anna',
    body: 'See you tomorrow',
    timestamp: DateTime.utc(2026, 11, 28, 9),
    isOwn: false,
    kind: MessageKind.text,
  );

  Future<void> expectGolden(
    WidgetTester tester,
    String name, {
    WeftGoldenVariant variant = weftGoldenBaseline,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      await pumpWeft(
        tester,
        Scaffold(
          key: ValueKey(suffix),
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showMessageActionsSheet(
                  context,
                  message: message,
                  quickReactions: quickReactionsWith(const [
                    'mxc://example.org/blobcat',
                    '🎉',
                  ]),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        size: phone,
        mode: mode,
        variant: variant,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('message_actions_${name}_$suffix.png'),
      );
      Navigator.of(tester.element(find.text('open'))).pop();
      await tester.pumpAndSettle();
    }
  }

  testWidgets('a phone', (tester) async {
    await expectGolden(tester, 'phone');
  });

  testWidgets('right to left', (tester) async {
    await expectGolden(tester, 'rtl', variant: weftAccessibilityVariants.first);
  });

  testWidgets('at 2× text', (tester) async {
    await expectGolden(
      tester,
      'large_text',
      variant: weftAccessibilityVariants[1],
    );
  });
}
