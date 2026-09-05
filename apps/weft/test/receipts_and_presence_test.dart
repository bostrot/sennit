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
  List<({String roomId, String userId, String eventId, DateTime at})>
  peerReadUpTo(String chatId) => readUpTo == null
      ? const []
      : [
          (
            roomId: '!seeded:example.org',
            userId: '@peer:example.org',
            eventId: readUpTo!,
            at: DateTime(2026, 8, 15, 16, 40),
          ),
        ];
}

/// A group whose members have read up to a stated event.
///
/// Separate from [_ReadRepository] because the interesting input is different:
/// one is "did the peer read it", the other is "how many of them did", and a
/// single double taking both would be answering two questions with one field.
class _GroupReadRepository extends SeededChatRepository {
  _GroupReadRepository(
    super.inner, {
    required super.messages,
    required this.readers,
    required this.peerCount,
  }) : super(isGroup: true);

  /// Everyone whose receipt covers the newest own message.
  final List<String> readers;

  /// How many people are in the group besides the user, or null when the
  /// membership has not loaded — which is ordinary for a bridged group.
  final int? peerCount;

  @override
  Chat get chat => super.chat.copyWith(participantCount: peerCount);

  @override
  List<({String roomId, String userId, String eventId, DateTime at})>
  peerReadUpTo(String chatId) => [
    for (final reader in readers)
      (
        roomId: '!seeded:example.org',
        userId: reader,
        eventId: r'$mine',
        at: DateTime(2026, 8, 15, 16, 40),
      ),
  ];
}

/// The read tick as it is actually drawn, corrected for the bubble it sits on.
///
/// Not `palette.readReceipt`: that token is corrected for the *inbox row's*
/// background, and in a dark theme the same blue on the own bubble's pale fill
/// is 1.3:1 — the most important of the five marks and the hardest to see. The
/// bubble corrects per surface, so an assertion against the raw token would be
/// asserting a colour nothing draws.
Color _blue() {
  final palette = WeftTheme.build(
    brightness: Brightness.dark,
  ).extension<WeftPalette>()!;
  return palette.readReceiptOn(palette.ownBubble);
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
    bool? readReceipts,
  }) => pumpWeft(
    tester,
    const ChatView(chatId: 'seeded:chat'),
    repository: repository,
    size: const Size(560, 900),
    settle: settle,
    readReceipts: readReceipts,
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

      final tick = tester
          .widgetList<Icon>(find.byType(Icon))
          .firstWhere((i) => i.icon == Icons.done_all_rounded);
      final expected = _blue();
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

      final blue = _blue();
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

    testWidgets('a receipts-disabled account never renders a read state', (
      tester,
    ) async {
      // The receipt in hand is real; what has changed is that the account is
      // not sending public receipts, so nearly every bridge has stopped
      // relaying the other direction. A blue tick here would be fabricated
      // from whatever stale receipt happened to survive.
      await pump(
        tester,
        _ReadRepository(demo, messages: ownThread(), readUpTo: r'$mine'),
        readReceipts: false,
      );

      final blue = _blue();
      final ticks = tester
          .widgetList<Icon>(find.byType(Icon))
          .where((i) => i.icon == Icons.done_all_rounded);

      expect(ticks, isNotEmpty, reason: 'the message still arrived');
      expect(ticks.where((i) => i.color == blue), isEmpty);
    });

    testWidgets('and says why the ticks cannot say more', (tester) async {
      // Two grey ticks with receipts off mean "we are not being told", not
      // "they have not looked at it" — and the difference is the whole reason
      // anyone looks at the mark.
      await pump(
        tester,
        _ReadRepository(demo, messages: ownThread(), readUpTo: r'$mine'),
        readReceipts: false,
      );

      expect(
        find.byTooltip(
          'Delivered, Read receipts are off, so this may already have been read',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a group is read only when everyone has read it', (
      tester,
    ) async {
      // WhatsApp's rule. A group where one person of three has opened the
      // message is not a message that has been read, and a client that said so
      // would make the mark useless in exactly the conversations it is most
      // looked at.
      await pump(
        tester,
        _GroupReadRepository(
          demo,
          messages: ownThread(),
          readers: const ['@one:example.org'],
          peerCount: 3,
        ),
      );

      final blue = _blue();
      expect(
        tester
            .widgetList<Icon>(find.byType(Icon))
            .where((i) => i.icon == Icons.done_all_rounded && i.color == blue),
        isEmpty,
      );
    });

    testWidgets('a group with every receipt in turns blue', (tester) async {
      await pump(
        tester,
        _GroupReadRepository(
          demo,
          messages: ownThread(),
          readers: const [
            '@one:example.org',
            '@two:example.org',
            '@three:example.org',
          ],
          peerCount: 3,
        ),
      );

      final blue = _blue();
      expect(
        tester
            .widgetList<Icon>(find.byType(Icon))
            .where((i) => i.icon == Icons.done_all_rounded && i.color == blue),
        isNotEmpty,
      );
    });

    testWidgets('every state is a different mark, in every rendering', (
      tester,
    ) async {
      // The one thing a golden can see and a string assertion cannot, asserted
      // as numbers so it fails with a reason rather than as an image diff: two
      // of the five states draw the *same glyph* and differ only in ink, and a
      // contrast correction that lands them on the same colour is a read
      // marker nobody can tell from a delivered one.
      //
      // High contrast is where this actually broke: `colorScheme.error` there
      // is a near-white pink meant for a dark surface, and the own bubble is
      // near-white too, so the tick saying a message never left was drawn at
      // 1.05:1 against the thing behind it.
      for (final variant in [
        weftGoldenBaseline,
        const WeftGoldenVariant(name: 'high_contrast', highContrast: true),
      ]) {
        // Light and dark, not `WeftThemeMode.values`: `system` resolves
        // against the platform brightness, and a palette built here for one
        // while the harness drew the other would be comparing two themes.
        for (final (mode, brightness) in const [
          (WeftThemeMode.dark, Brightness.dark),
          (WeftThemeMode.light, Brightness.light),
        ]) {
          await pumpWeft(
            tester,
            const ChatView(chatId: 'seeded:chat'),
            repository: _ReadRepository(
              demo,
              readUpTo: r'$read',
              messages: [
                seededMessage(
                  eventId: r'$read',
                  body: 'seen',
                  isOwn: true,
                  minutesAgo: 20,
                  deliveryState: DeliveryState.delivered,
                ),
                seededMessage(
                  eventId: r'$delivered',
                  body: 'arrived',
                  isOwn: true,
                  minutesAgo: 15,
                  deliveryState: DeliveryState.delivered,
                ),
                seededMessage(
                  eventId: r'$failed',
                  body: 'never left',
                  isOwn: true,
                  minutesAgo: 5,
                  deliveryState: DeliveryState.failed,
                ),
              ],
            ),
            size: const Size(560, 900),
            mode: mode,
            variant: variant,
          );

          final where = '${variant.name}/${mode.name}';
          final palette = WeftTheme.build(
            brightness: brightness,
            highContrast: variant.highContrast,
          ).extension<WeftPalette>()!;

          final ticks = tester
              .widgetList<Icon>(find.byType(Icon))
              .where(
                (i) =>
                    i.icon == Icons.done_all_rounded ||
                    i.icon == Icons.error_outline_rounded,
              )
              .toList();

          final blue = palette.readReceiptOn(palette.ownBubble);
          final read = ticks.where((i) => i.color == blue);
          expect(read, hasLength(1), reason: 'exactly one read tick in $where');

          final others = ticks.where((i) => i.color != blue);
          expect(
            others,
            hasLength(2),
            reason: 'delivered and failed are not read in $where',
          );
          for (final tick in others) {
            expect(
              WeftContrast.ratio(tick.color!, palette.ownBubble),
              greaterThanOrEqualTo(WeftContrast.uiComponent),
              reason:
                  'a tick nobody can see against the bubble it sits on says '
                  'nothing, in $where',
            );
          }
          expect(
            WeftContrast.ratio(blue, palette.ownBubble),
            greaterThanOrEqualTo(WeftContrast.uiComponent),
            reason: 'the read tick too, in $where',
          );
        }
      }
    });

    testWidgets('a group of unknown size stops at delivered', (tester) async {
      // One receipt out of nine looks exactly like one out of one.
      await pump(
        tester,
        _GroupReadRepository(
          demo,
          messages: ownThread(),
          readers: const ['@one:example.org'],
          peerCount: null,
        ),
      );

      final blue = _blue();
      expect(
        tester
            .widgetList<Icon>(find.byType(Icon))
            .where((i) => i.icon == Icons.done_all_rounded && i.color == blue),
        isEmpty,
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
