import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/jump_to_latest_button.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/seeded_repository.dart';
import 'support/semantics_probe.dart';

/// The way back down.
///
/// Someone who scrolls up to check what was agreed last week has, until this,
/// one way to return to the conversation: flinging until the list stops. The
/// button is the one-tap version — and the half of it that matters as much as
/// its being there is its *not* being there: over the newest message it is a
/// thing in front of the words that does nothing.
void main() {
  late DemoChatRepository demo;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  const tooltip = 'Jump to latest';

  /// Enough history to scroll through, newest last. Message 0 is the newest.
  List<WeftMessage> history(int count) => [
    for (var i = 0; i < count; i++)
      seededMessage(
        eventId: '\$m$i',
        body: 'message $i',
        isOwn: i.isOdd,
        minutesAgo: i,
      ),
  ];

  Future<void> pumpChat(
    WidgetTester tester, {
    int messages = 60,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    WeftSurface surface = WeftSurface.touch,
    double textScale = 1,
    bool reduceMotion = false,
    SeededChatRepository? seeded,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository =
        seeded ?? SeededChatRepository(demo, messages: history(messages));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(
            brightness: brightness,
            surface: surface,
            reduceMotion: reduceMotion,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: ChatView(chatId: repository.chatId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ScrollPosition position(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  /// Drags the timeline towards older messages by [distance].
  Future<void> scrollUp(WidgetTester tester, double distance) async {
    await tester.drag(find.byType(ListView), Offset(0, distance));
    await tester.pumpAndSettle();
  }

  testWidgets('is not there while the newest message is on screen', (
    tester,
  ) async {
    await pumpChat(tester);

    expect(position(tester).pixels, 0);
    expect(find.byTooltip(tooltip), findsNothing);
  });

  testWidgets('stays away for a nudge that leaves the newest in reach', (
    tester,
  ) async {
    await pumpChat(tester);

    await scrollUp(tester, 120);

    expect(position(tester).pixels, greaterThan(0));
    expect(find.byTooltip(tooltip), findsNothing);
  });

  testWidgets('appears once scrolled up, and one tap returns to the newest', (
    tester,
  ) async {
    await pumpChat(tester);

    await scrollUp(tester, 600);
    await scrollUp(tester, 600);
    expect(find.text('message 0', findRichText: true), findsNothing);
    expect(find.byTooltip(tooltip), findsOneWidget);

    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();

    expect(position(tester).pixels, 0);
    expect(find.text('message 0', findRichText: true), findsOneWidget);
    // Gone again: it has nothing left to offer.
    expect(find.byTooltip(tooltip), findsNothing);
  });

  testWidgets('never shows in a conversation too short to scroll', (
    tester,
  ) async {
    await pumpChat(tester, messages: 3);

    await scrollUp(tester, 600);

    expect(find.byTooltip(tooltip), findsNothing);
  });

  testWidgets('with reduced motion the return is a jump, not a glide', (
    tester,
  ) async {
    await pumpChat(tester, reduceMotion: true);
    await scrollUp(tester, 600);
    await scrollUp(tester, 600);

    await tester.tap(find.byTooltip(tooltip));
    // One frame, no settling: there is no animation to wait out.
    await tester.pump();

    expect(position(tester).pixels, 0);
  });

  testWidgets('is a named control big enough for a thumb', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpChat(tester);
    await scrollUp(tester, 600);
    await scrollUp(tester, 600);

    // By its tooltip, which is where an `IconButton` puts its name.
    expect(controlNamesIn(tester), contains(tooltip));
    expect(unnamedControlsIn(tester), isEmpty);
    final size = tester.getSize(
      find.descendant(
        of: find.byType(JumpToLatestButton),
        matching: find.byType(IconButton),
      ),
    );
    expect(size.width, greaterThanOrEqualTo(kWeftMinTapTarget));
    expect(size.height, greaterThanOrEqualTo(kWeftMinTapTarget));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  // The places a floating control goes wrong: a narrow phone, a wide window
  // where the messages sit in a capped column, the other theme, and text
  // large enough to push everything else around.
  final layouts =
      <
        String,
        ({Size size, WeftSurface surface, Brightness brightness, double scale})
      >{
        'small phone, light': (
          size: const Size(320, 568),
          surface: WeftSurface.touch,
          brightness: Brightness.light,
          scale: 1,
        ),
        'phone, dark, largest text': (
          size: const Size(390, 844),
          surface: WeftSurface.touch,
          brightness: Brightness.dark,
          scale: 2,
        ),
        'desktop window, light': (
          size: const Size(1400, 900),
          surface: WeftSurface.mac,
          brightness: Brightness.light,
          scale: 1,
        ),
        'minimum desktop window, dark, large text': (
          size: const Size(720, 480),
          surface: WeftSurface.mac,
          brightness: Brightness.dark,
          scale: 1.5,
        ),
      };

  WeftMessage arrival(int n, {bool isOwn = false}) => seededMessage(
    eventId: '\$new$n',
    body: 'new $n',
    isOwn: isOwn,
    minutesAgo: -n,
  );

  Finder badge() => find.descendant(
    of: find.byType(JumpToLatestButton),
    matching: find.byType(WeftUnreadBadge),
  );

  group('counts what arrived while scrolled up', () {
    testWidgets("on the button, without the reader's own messages", (
      tester,
    ) async {
      final repository = _SyncingRepository(demo, messages: history(60));
      await pumpChat(tester, seeded: repository);
      await scrollUp(tester, 600);
      await scrollUp(tester, 600);
      expect(badge(), findsNothing);

      repository
        ..arrive(arrival(1))
        ..arrive(arrival(2, isOwn: true))
        ..arrive(arrival(3));
      repository.sync();
      await tester.pumpAndSettle();

      expect(find.text('2'), findsOneWidget);
      expect(badge(), findsOneWidget);
      // Said as well as drawn: the badge is a number only a sighted reader
      // gets, so the button's name carries it.
      expect(find.byTooltip('$tooltip, 2 new messages'), findsOneWidget);

      repository.arrive(arrival(4));
      repository.sync();
      await tester.pumpAndSettle();
      expect(find.byTooltip('$tooltip, 3 new messages'), findsOneWidget);
    });

    testWidgets('and forgets it once back at the newest message', (
      tester,
    ) async {
      final repository = _SyncingRepository(demo, messages: history(60));
      await pumpChat(tester, seeded: repository);
      await scrollUp(tester, 600);
      await scrollUp(tester, 600);
      repository.arrive(arrival(1));
      repository.sync();
      await tester.pumpAndSettle();
      expect(find.byTooltip('$tooltip, 1 new message'), findsOneWidget);

      await tester.tap(find.byTooltip('$tooltip, 1 new message'));
      await tester.pumpAndSettle();
      expect(find.text('new 1', findRichText: true), findsOneWidget);

      // Up again: what arrived before is no longer news.
      await scrollUp(tester, 600);
      await scrollUp(tester, 600);
      expect(find.byTooltip(tooltip), findsOneWidget);
      expect(badge(), findsNothing);
    });

    testWidgets('without taking keyboard focus off the button', (tester) async {
      final repository = _SyncingRepository(demo, messages: history(60));
      await pumpChat(tester, seeded: repository);
      await scrollUp(tester, 600);
      await scrollUp(tester, 600);
      Focus.of(
        tester.element(find.byIcon(Icons.keyboard_arrow_down)),
      ).requestFocus();
      await tester.pump();

      repository.arrive(arrival(1));
      repository.sync();
      await tester.pumpAndSettle();

      expect(badge(), findsOneWidget);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        focused!.findAncestorWidgetOfExactType<JumpToLatestButton>(),
        isNotNull,
      );
    });

    testWidgets('but not what arrived while the newest was in view', (
      tester,
    ) async {
      final repository = _SyncingRepository(demo, messages: history(60));
      await pumpChat(tester, seeded: repository);
      repository.arrive(arrival(1));
      repository.sync();
      await tester.pumpAndSettle();

      await scrollUp(tester, 600);
      await scrollUp(tester, 600);
      expect(find.byTooltip(tooltip), findsOneWidget);
      expect(badge(), findsNothing);
    });
  });

  for (final MapEntry(key: name, value: layout) in layouts.entries) {
    testWidgets('sits inside the timeline and works on a $name', (
      tester,
    ) async {
      await pumpChat(
        tester,
        size: layout.size,
        surface: layout.surface,
        brightness: layout.brightness,
        textScale: layout.scale,
      );
      await scrollUp(tester, layout.size.height);
      await scrollUp(tester, layout.size.height);

      final button = tester.getRect(find.byTooltip(tooltip));
      final timeline = tester.getRect(find.byType(ListView));
      // Wholly over the messages: not under the composer, not off the edge.
      expect(timeline.contains(button.topLeft), isTrue);
      expect(timeline.contains(button.bottomRight), isTrue);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      expect(position(tester).pixels, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps its count inside the timeline on a $name', (
      tester,
    ) async {
      final repository = _SyncingRepository(demo, messages: history(60));
      await pumpChat(
        tester,
        seeded: repository,
        size: layout.size,
        surface: layout.surface,
        brightness: layout.brightness,
        textScale: layout.scale,
      );
      await scrollUp(tester, layout.size.height);
      await scrollUp(tester, layout.size.height);
      for (var n = 1; n <= 12; n++) {
        repository.arrive(arrival(n));
      }
      repository.sync();
      await tester.pumpAndSettle();

      expect(find.text('12'), findsOneWidget);
      final count = tester.getRect(badge());
      final timeline = tester.getRect(find.byType(ListView));
      expect(timeline.contains(count.topLeft), isTrue);
      expect(timeline.contains(count.bottomRight), isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}

/// A chat that can be told a sync happened, the way the app learns that
/// something arrived: the chat list emits, and the open conversation re-reads
/// its timeline.
class _SyncingRepository extends GrowingChatRepository {
  _SyncingRepository(super.inner, {required super.messages});

  final _syncs = StreamController<List<Chat>>.broadcast();

  @override
  Stream<List<Chat>> watchChats() async* {
    yield [chat];
    yield* _syncs.stream;
  }

  void sync() => _syncs.add([chat]);
}
