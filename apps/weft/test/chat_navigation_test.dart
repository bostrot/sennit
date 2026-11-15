import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft_design/weft_design.dart';

import 'support/golden_harness.dart';

/// One conversation, one screen, one Back.
///
/// Every way into a conversation pushed a new screen without checking what
/// was already there, so a second tap that landed before the first screen had
/// appeared — or a notification for the chat already open — stacked a copy,
/// and Back had to be pressed once per copy.
void main() {
  const phone = Size(412, 915);

  testWidgets('two quick taps on a row open one conversation', (tester) async {
    await pumpWeft(tester, const InboxShell(), size: phone);

    final row = find.byType(ChatTile).first;
    await tester.tap(row);
    // No frame in between: the second tap arrives before the first screen
    // has been built, which is what a double tap is.
    await tester.tap(row, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(ChatView), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(ChatView), findsNothing);
    expect(find.byType(ChatTile), findsWidgets);
  });

  testWidgets('asking for the conversation already on top adds nothing', (
    tester,
  ) async {
    await pumpWeft(tester, const InboxShell(), size: phone);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );

    for (var i = 0; i < 3; i++) {
      navigator.push(chatRoute('merged:anna')).ignore();
      await tester.pumpAndSettle();
      await pushChat(navigator, 'merged:anna');
      await tester.pumpAndSettle();
      expect(find.byType(ChatView), findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byType(ChatView), findsNothing);
    }
  });
}
