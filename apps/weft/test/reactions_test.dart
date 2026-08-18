import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/reaction_bar.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/recording_repository.dart';

/// Reactions as the reader meets them: a long-press, a chip, and a second tap
/// that takes it back.
///
/// The aggregation itself is tested in `packages/weft_richtext` and the
/// repository routing in `message_relations_test.dart`. What is only testable
/// here is the wiring between them — that the bubble hands its *own* event id
/// down, that the chip reflects what came back, and that a reaction landing
/// while the chat is open reaches the screen at all.
void main() {
  /// Anna is the merged fixture: three legs, and her Signal leg spoke last, so
  /// the chat's default send network is Signal. The message reacted to below is
  /// deliberately on the Telegram leg.
  const mergedChat = 'merged:anna';
  const telegramRoom = '!anna_tg_room:example.org';

  /// A line only the Telegram fixture uses, so finding it is finding a bubble
  /// on the leg that is not the send network.
  const telegramLine = 'Quick update from my side.';

  late DemoChatRepository demo;
  late RecordingChatRepository repository;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
    repository = RecordingChatRepository(demo);
  });
  tearDown(() => demo.dispose());

  Future<void> pump(WidgetTester tester, {String chatId = mergedChat}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: ChatView(chatId: chatId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Long-presses the first bubble carrying [text] and picks [emoji] from the
  /// quick row of the action sheet.
  Future<void> reactTo(WidgetTester tester, String text, String emoji) async {
    await tester.longPress(
      find.text(text, findRichText: true).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    // Scoped to the sheet: once a chip is on screen the same emoji is also in
    // the timeline behind the modal barrier, and `first` would find that one.
    await tester.tap(
      find
          .descendant(of: find.byType(BottomSheet), matching: find.text(emoji))
          .first,
    );
    await tester.pumpAndSettle();
  }

  /// The message an event id names, across every leg.
  Future<WeftMessage> messageFor(String eventId) async {
    final timeline = await demo.timelineFor(mergedChat);
    for (var round = 0; round < 6; round++) {
      await timeline.loadMore(count: 30);
    }
    return [
      for (final source in timeline.sources) ...source.loaded,
    ].firstWhere((m) => m.eventId == eventId);
  }

  testWidgets('a reaction sent from a bubble appears on it', (tester) async {
    await pump(tester);
    expect(find.byType(ReactionChip), findsNothing);

    await reactTo(tester, telegramLine, '👍');

    // The bar exists, carries the key, and counts the one person who sent it.
    expect(find.byType(ReactionChip), findsOneWidget);
    final chip = tester.widget<ReactionChip>(find.byType(ReactionChip));
    expect(chip.tally.key, '👍');
    expect(chip.tally.count, 1);
    expect(chip.tally.byLocalUser, isTrue);
  });

  // Regression: nothing in the chat view listened to the timeline, so a
  // reaction was in the model and not on the screen until the next pagination.
  // That is the worst of the failure modes available, because nothing looks
  // broken.
  testWidgets('the chip arrives without waiting for more history', (
    tester,
  ) async {
    await pump(tester);
    await reactTo(tester, telegramLine, '❤️');

    expect(find.byType(ReactionChip), findsOneWidget);
  });

  testWidgets('the reaction names the bubble it came from, on its own leg', (
    tester,
  ) async {
    await pump(tester);
    await reactTo(tester, telegramLine, '👍');

    final call = repository.lastCallTo('react');
    expect(call, isNotNull);
    expect(call!.key, '👍');

    // The routing rule, seen from the UI: the event the annotation names is on
    // the Telegram leg, while the chat would have *sent* on Signal. A reaction
    // routed by send network would point at an event that room never saw.
    final target = await messageFor(call.eventId!);
    expect(target.roomId, telegramRoom);

    final chats = await demo.watchChats().first;
    final chat = chats.firstWhere((c) => c.id == mergedChat);
    expect(chat.sendNetwork, ChatNetwork.signal);
  });

  testWidgets('tapping the reader own chip takes the reaction back', (
    tester,
  ) async {
    await pump(tester);
    await reactTo(tester, telegramLine, '👍');

    final reactionEventId = tester
        .widget<ReactionChip>(find.byType(ReactionChip))
        .tally
        .localEventId;
    expect(reactionEventId, isNotNull);

    await tester.tap(find.byType(ReactionChip));
    await tester.pumpAndSettle();

    // Un-reacting redacts the *annotation*, not the message it points at.
    expect(repository.lastCallTo('unreact')?.eventId, reactionEventId);
    expect(find.byType(ReactionChip), findsNothing);
  });

  testWidgets('the same key twice is a toggle, not a second reaction', (
    tester,
  ) async {
    await pump(tester);
    await reactTo(tester, telegramLine, '👍');
    await reactTo(tester, telegramLine, '👍');

    expect(repository.lastCallTo('unreact'), isNotNull);
    expect(find.byType(ReactionChip), findsNothing);
  });

  testWidgets('long-pressing a chip names who reacted', (tester) async {
    await pump(tester);
    await reactTo(tester, telegramLine, '👍');

    await tester.longPress(find.byType(ReactionChip));
    await tester.pumpAndSettle();

    expect(find.text('1 person'), findsOneWidget);
    expect(find.text('@me:example.org'), findsOneWidget);
  });

  testWidgets('the picker offers a reaction beyond the quick row', (
    tester,
  ) async {
    await pump(tester);

    await tester.longPress(
      find.text(telegramLine, findRichText: true).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More reactions'));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .descendant(of: find.byType(BottomSheet), matching: find.text('🎉'))
          .first,
    );
    await tester.pumpAndSettle();

    expect(repository.lastCallTo('react')?.key, '🎉');
    expect(
      tester.widget<ReactionChip>(find.byType(ReactionChip)).tally.key,
      '🎉',
    );
  });

  testWidgets('a key the reader has used shows up in the picker recents', (
    tester,
  ) async {
    await pump(tester);
    await reactTo(tester, telegramLine, '😂');

    // A different message, so the picker is reached from a bubble with no
    // reactions of its own.
    await tester.longPress(
      find.text('Sounds good 👍', findRichText: true).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More reactions'));
    await tester.pumpAndSettle();

    expect(find.text('Recent'), findsOneWidget);
  });
}
