import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../support/attachment_fixtures.dart';
import '../support/golden_harness.dart';

/// Threads as pictures: the indicator in the room, and the thread itself.
///
/// Captured inside [ChatView] rather than on a bare Scaffold, for the same
/// reason the attachment goldens are: the indicator is read against the bubble
/// it hangs under and the column it sits in, and an image of the row alone
/// would pass unchanged through the regression it exists to catch — an
/// indicator that no longer lines up with the message above it, or one whose
/// leading rule vanishes into the surface behind it in one theme.
///
/// Both themes, because the row is the one piece of chat chrome drawn on
/// `surfaceContainerHigh` with a primary-coloured rule: the two are close
/// together in light and far apart in dark, and a tint that reads in one can be
/// invisible in the other.
void main() {
  setUpAll(loadGoldenFonts);

  const chatId = '!design_room:example.org';
  final sentAt = DateTime(2026, 8, 15, 14, 20);

  WeftMessage message({
    required String eventId,
    required String body,
    required int minutesAgo,
    bool isOwn = false,
    String senderName = 'Priya',
    String? threadRootId,
    String? threadName,
  }) => WeftMessage(
    eventId: eventId,
    roomId: chatId,
    network: ChatNetwork.matrix,
    // Derived from the name, not fixed: bubble grouping runs on the
    // sender *id*, and two people sharing one id would render as one
    // person speaking twice — which is exactly the failure the group
    // check exists to prevent.
    senderId: isOwn
        ? '@me:example.org'
        : '@${senderName.toLowerCase()}:example.org',
    senderName: isOwn ? 'You' : senderName,
    timestamp: sentAt.subtract(Duration(minutes: minutesAgo)),
    kind: MessageKind.text,
    isOwn: isOwn,
    body: body,
    threadRootId: threadRootId,
    threadName: threadName,
  );

  /// A room holding a named forum topic, an unnamed Matrix thread, and one
  /// message that is in neither.
  ///
  /// All three in one image on purpose: the difference between "Bugs · 3
  /// replies" and "shipping Thursday? · 1 reply" is the whole of what the
  /// fallback title does, and it is only legible with the two side by side.
  List<WeftMessage> history() => [
    message(
      eventId: r'$topic',
      body: 'anyone else seeing the flaky attachment test?',
      threadName: 'Bugs',
      minutesAgo: 40,
    ),
    message(
      eventId: r'$t1',
      body: 'yes, since Tuesday',
      minutesAgo: 34,
      threadRootId: r'$topic',
      threadName: 'Bugs',
    ),
    message(
      eventId: r'$t2',
      body: 'it is the fake clock, I think',
      minutesAgo: 32,
      senderName: 'Sam',
      threadRootId: r'$topic',
      threadName: 'Bugs',
    ),
    message(
      eventId: r'$t3',
      body: 'looking at it now',
      minutesAgo: 30,
      isOwn: true,
      threadRootId: r'$topic',
      threadName: 'Bugs',
    ),
    message(eventId: r'$loose', body: 'unrelated, sorry', minutesAgo: 20),
    message(
      eventId: r'$plain',
      body: 'are we still shipping Thursday?',
      minutesAgo: 12,
      isOwn: true,
    ),
    message(
      eventId: r'$p1',
      body: 'if CI is green by then',
      minutesAgo: 8,
      threadRootId: r'$plain',
    ),
  ];

  Future<void> expectGolden(
    WidgetTester tester,
    String name, {
    String? threadRootId,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      final repository = StubChatRepository(history: history());
      addTearDown(repository.dispose);

      await pumpWeft(
        tester,
        ChatView(chatId: chatId, threadRootId: threadRootId),
        size: const Size(560, 900),
        mode: mode,
        repository: repository,
      );

      await expectLater(
        find.byType(ChatView),
        matchesGoldenFile('${name}_$suffix.png'),
      );
    }
  }

  testWidgets('thread indicators in the room, both themes', (tester) async {
    await expectGolden(tester, 'thread_indicators');
  });

  testWidgets('one thread open, both themes', (tester) async {
    // The bar names the topic and the conversation it belongs to, the root
    // leads, and the composer says where the next message goes — none of which
    // the room's own bar or composer would say.
    await expectGolden(tester, 'thread_view', threadRootId: r'$topic');
  });
}
