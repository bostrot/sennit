import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';

import 'support/golden_harness.dart';
import 'support/seeded_repository.dart';

/// What the ticks say, and who is writing.
///
/// The ticks are the most-read four pixels in a messenger and they were saying
/// almost nothing: every state past "sending" drew the same double tick in the
/// same colour, so the mark meant "not failed" — while the one question anyone
/// looks at it for is whether the other side has seen it. Matrix has no
/// delivery receipts, only read ones, so the mapper stops at `delivered` and
/// nothing turned that into `read`.
class _ReadRepository extends SeededChatRepository {
  _ReadRepository(
    super.inner, {
    required super.messages,
    required this.readUpTo,
  });

  /// The event id the other side's receipt names, or null for no receipt.
  final String? readUpTo;

  @override
  List<({String roomId, String eventId, DateTime at})> peerReadUpTo(
    String chatId,
  ) => readUpTo == null
      ? const []
      : [
          (
            roomId: '!seeded:example.org',
            eventId: readUpTo!,
            at: DateTime(2026, 8, 15, 16, 40),
          ),
        ];
}

void main() {
  setUpAll(loadGoldenFonts);

  late DemoChatRepository demo;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  List<WeftMessage> ownThread() => [
    seededMessage(
      eventId: r'$mine',
      body: 'On my way',
      isOwn: true,
      minutesAgo: 3,
      deliveryState: DeliveryState.delivered,
    ),
  ];

  Future<void> pump(
    WidgetTester tester,
    SeededChatRepository repository, {
    // A thread with someone typing in it never settles — the dots animate for
    // as long as the state is true.
    bool settle = true,
  }) => pumpWeft(
    tester,
    const ChatView(chatId: 'seeded:chat'),
    repository: repository,
    size: const Size(560, 900),
    settle: settle,
  );

  /// The tick actually drawn, by its icon.
  IconData tickIn(WidgetTester tester) => tester
      .widgetList<Icon>(find.byType(Icon))
      .map((i) => i.icon)
      .whereType<IconData>()
      .firstWhere(
        (i) =>
            i == Icons.done_rounded ||
            i == Icons.done_all_rounded ||
            i == Icons.schedule_rounded ||
            i == Icons.error_outline_rounded,
      );

  group('the ticks', () {
    testWidgets('a delivered message shows two grey ticks', (tester) async {
      await pump(
        tester,
        _ReadRepository(demo, messages: ownThread(), readUpTo: null),
      );
      expect(tickIn(tester), Icons.done_all_rounded);
    });

    testWidgets('a read message turns them blue', (tester) async {
      await pump(
        tester,
        _ReadRepository(demo, messages: ownThread(), readUpTo: r'$mine'),
      );

      final tick = tester.widgetList<Icon>(find.byType(Icon)).firstWhere(
        (i) => i.icon == Icons.done_all_rounded,
      );
      final expected = WeftTheme.build(
        brightness: Brightness.dark,
      ).extension<WeftPalette>()!.readReceipt;
      expect(
        tick.color,
        expected,
        reason: 'the one thing the ticks are looked at for',
      );
    });

    testWidgets('a message only sent shows a single tick', (tester) async {
      await pump(
        tester,
        _ReadRepository(
          demo,
          readUpTo: null,
          messages: [
            seededMessage(
              eventId: r'$mine',
              body: 'On my way',
              isOwn: true,
              minutesAgo: 1,
              deliveryState: DeliveryState.sent,
            ),
          ],
        ),
      );
      expect(
        tickIn(tester),
        Icons.done_rounded,
        reason: 'accepted by the server is not the same as arrived',
      );
    });

    testWidgets('a receipt for a later message covers earlier ones', (
      tester,
    ) async {
      await pump(
        tester,
        _ReadRepository(
          demo,
          readUpTo: r'$second',
          messages: [
            seededMessage(
              eventId: r'$first',
              body: 'One',
              isOwn: true,
              minutesAgo: 6,
              deliveryState: DeliveryState.delivered,
            ),
            seededMessage(
              eventId: r'$second',
              body: 'Two',
              isOwn: true,
              minutesAgo: 5,
              deliveryState: DeliveryState.delivered,
            ),
          ],
        ),
      );

      final blue = WeftTheme.build(
        brightness: Brightness.dark,
      ).extension<WeftPalette>()!.readReceipt;
      final ticks = tester
          .widgetList<Icon>(find.byType(Icon))
          .where((i) => i.icon == Icons.done_all_rounded)
          .toList();
      expect(
        ticks.where((i) => i.color == blue),
        hasLength(2),
        reason: 'a receipt names one event and means everything before it',
      );
    });
  });

  group('typing', () {
    testWidgets('shows in the thread, where the reply will appear', (
      tester,
    ) async {
      // `bySemanticsLabel` reads the semantics tree, which a widget test does
      // not build unless it is asked to.
      // Disposed inside the body, not in a tearDown: the framework checks
      // for leaked handles before tearDowns run.
      final semantics = tester.ensureSemantics();
      await pump(
        tester,
        _TypingRepository(demo, messages: ownThread(), typing: const ['Anna']),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.bySemanticsLabel('Typing'),
        findsOneWidget,
        reason: 'a line of small print above the conversation is not seen',
      );
      semantics.dispose();
    });

    testWidgets('names who, in a group', (tester) async {
      // Disposed inside the body, not in a tearDown: the framework checks
      // for leaked handles before tearDowns run.
      final semantics = tester.ensureSemantics();
      await pump(
        tester,
        _TypingRepository(
          demo,
          messages: ownThread(),
          typing: const ['Anna'],
          isGroup: true,
        ),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.bySemanticsLabel('Anna is typing'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('is absent when nobody is', (tester) async {
      // Disposed inside the body, not in a tearDown: the framework checks
      // for leaked handles before tearDowns run.
      final semantics = tester.ensureSemantics();
      await pump(
        tester,
        _TypingRepository(demo, messages: ownThread(), typing: const []),
      );
      expect(find.bySemanticsLabel('Typing'), findsNothing);
      semantics.dispose();
    });
  });
}

class _TypingRepository extends SeededChatRepository {
  _TypingRepository(
    super.inner, {
    required super.messages,
    required this.typing,
    super.isGroup,
  });

  final List<String> typing;

  @override
  List<String> typingIn(String chatId) => typing;
}
