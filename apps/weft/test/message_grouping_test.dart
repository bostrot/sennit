import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';

import 'support/golden_harness.dart';
import 'support/seeded_repository.dart';
import 'package:weft/data/demo_repository.dart';

/// Who said what, in a group.
///
/// Consecutive messages are drawn as one run — no repeated name, tighter
/// spacing — and the rule for what counts as consecutive left the *sender* out
/// of it. Two people answering within five minutes were run together, and the
/// second one's name disappeared: a reply from someone else reading as a
/// second line from whoever spoke first. In a group chat that is the one thing
/// that must never be got wrong, and nothing in the suite could see it.
void main() {
  setUpAll(loadGoldenFonts);

  late DemoChatRepository demo;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  /// A group where two people speak, close together in time.
  SeededChatRepository twoSpeakers() => SeededChatRepository(
    demo,
    isGroup: true,
    title: 'Design Team',
    messages: [
      seededMessage(
        eventId: r'$one',
        body: 'Just saw it on the high street',
        minutesAgo: 8,
        senderId: '@elke:example.org',
        senderName: 'Elke',
      ),
      seededMessage(
        eventId: r'$two',
        body: 'Very cool, but a bit unnerving',
        // Three minutes later: inside the five-minute window that decides a
        // run, which is what made this a bug rather than a coincidence.
        minutesAgo: 5,
        senderId: '@nils:example.org',
        senderName: 'Nils',
      ),
      seededMessage(
        eventId: r'$three',
        body: 'I thought so too',
        minutesAgo: 4,
        senderId: '@nils:example.org',
        senderName: 'Nils',
      ),
    ],
  );

  testWidgets('a second speaker keeps their name', (tester) async {
    await pumpWeft(
      tester,
      const ChatView(chatId: 'seeded:chat'),
      repository: twoSpeakers(),
      size: const Size(560, 900),
    );

    expect(find.text('Elke'), findsOneWidget);
    expect(
      find.text('Nils'),
      findsOneWidget,
      reason: 'a reply from someone else is not a second line from the first',
    );
  });

  testWidgets('the same speaker is not named twice in a row', (tester) async {
    await pumpWeft(
      tester,
      const ChatView(chatId: 'seeded:chat'),
      repository: twoSpeakers(),
      size: const Size(560, 900),
    );

    // Nils speaks twice; the run is what stops the name repeating under it.
    expect(find.text('Nils'), findsOneWidget);
  });

  testWidgets('every speaker in a group has a face', (tester) async {
    await pumpWeft(
      tester,
      const ChatView(chatId: 'seeded:chat'),
      repository: twoSpeakers(),
      size: const Size(560, 900),
    );

    // One per run rather than one per message: the gutter is held for grouped
    // messages so the run stays aligned, and only the first carries the face.
    final avatars = tester
        .widgetList<WeftAvatar>(find.byType(WeftAvatar))
        .where((a) => a.size == 24)
        .length;
    expect(
      avatars,
      2,
      reason: 'a wall of identical bubbles cannot be told apart by reading',
    );
  });
}
