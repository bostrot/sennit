import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/providers.dart';
import 'package:weft/app/shortcuts.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/search/search_screen.dart';
import 'package:weft/features/settings/shortcuts_sheet.dart';

import '../support/recording_repository.dart';
import '../support/semantics_probe.dart';

/// Weft from a keyboard alone.
///
/// The audit's CROSS-3 was two findings wearing one number, and both are here:
/// whole surfaces that Tab could not reach, and no shortcuts at all with Enter
/// overloaded so a five-line composer had no reachable second line. The tests
/// are written against the *bindings table* rather than against hard-coded
/// keys, so the map, the sheet and these assertions cannot drift apart — and
/// so the suite says the same thing on a machine where Cmd is the modifier as
/// on one where Ctrl is.
void main() {
  late DemoChatRepository demo;
  late RecordingChatRepository repository;
  late WeftStores stores;

  setUp(() {
    demo = DemoChatRepository(uploadTick: Duration.zero);
    repository = RecordingChatRepository(demo);
    stores = WeftStores.inMemory();
  });
  tearDown(() {
    demo.dispose();
    stores.dispose();
  });

  /// The app as `main.dart` assembles it: shortcuts above the navigator, so a
  /// binding works on a pushed route as much as on the inbox.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    Widget home = const InboxShell(),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(repository),
        storesBootstrapProvider.overrideWith((ref) async => stores),
      ],
    );
    addTearDown(container.dispose);
    // Resolved before the first frame, not during it. `storesProvider` is the
    // synchronous face of this future and throws while it is pending, so a
    // screen that reads settings — search does — would build against an error
    // rather than against the in-memory store this test set up.
    await container.read(storesBootstrapProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: WeftTheme.build(),
          builder: (context, child) => WeftShortcuts(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// Sends [activator] as a real key sequence, modifiers and all.
  Future<void> pressActivator(
    WidgetTester tester,
    SingleActivator activator,
  ) async {
    final modifiers = <LogicalKeyboardKey>[
      if (activator.control) LogicalKeyboardKey.control,
      if (activator.meta) LogicalKeyboardKey.meta,
      if (activator.alt) LogicalKeyboardKey.alt,
      if (activator.shift) LogicalKeyboardKey.shift,
    ];
    for (final key in modifiers) {
      await tester.sendKeyDownEvent(key);
    }
    await tester.sendKeyEvent(activator.trigger);
    for (final key in modifiers.reversed) {
      await tester.sendKeyUpEvent(key);
    }
    await tester.pumpAndSettle();
  }

  /// The binding called [description], or a failure naming it.
  WeftKeyBinding bindingFor(String description) => weftKeyBindings().firstWhere(
    (b) => b.description == description,
    orElse: () => fail('No binding called "$description"'),
  );

  /// Presses the first key combination bound to [description].
  ///
  /// Looked up rather than written out, which is the point: a binding that is
  /// renamed, re-keyed or dropped fails here instead of quietly passing
  /// against a key nobody uses any more.
  Future<void> press(WidgetTester tester, String description) =>
      pressActivator(tester, bindingFor(description).activators.first);

  /// The label of whatever focusable currently holds focus, or null when focus
  /// is on something `weft_design` did not build.
  String? focusedLabel() => FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<WeftFocusable>()
      ?.label;

  /// Tabs up to [limit] times, collecting every distinct focusable it lands on.
  Future<List<String>> tabThrough(WidgetTester tester, {int limit = 60}) async {
    final seen = <String>[];
    for (var i = 0; i < limit; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final label = focusedLabel();
      if (label != null && (seen.isEmpty || seen.last != label)) {
        seen.add(label);
      }
    }
    return seen;
  }

  /// Tabs [limit] times, collecting the name of every node it lands on.
  ///
  /// Named from the semantics tree rather than from [WeftFocusable], so a
  /// Material button, an `InkWell` and one of Weft's own controls all count the
  /// same way — the question this answers is "can a keyboard reach it", and the
  /// widget it happens to be built from is not part of it.
  Future<Set<String>> tabAcross(WidgetTester tester, {int limit = 150}) async {
    final reached = <String>{};
    for (var i = 0; i < limit; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final name = focusedNameIn(tester);
      if (name != null) reached.add(name);
    }
    return reached;
  }

  group('every control is reachable by Tab alone', () {
    /// Asserts that everything on screen when it opens is reached by Tab.
    ///
    /// The set is snapshotted *before* tabbing rather than after: traversal
    /// scrolls, so a list can grow controls that were not on screen when the
    /// user started pressing Tab, and demanding those too would make the
    /// assertion depend on how far a long list happened to scroll.
    Future<void> expectAllReachable(WidgetTester tester) async {
      final controls = controlNamesIn(tester).toSet();
      expect(controls, isNotEmpty, reason: 'nothing to reach — wrong screen?');

      final reached = await tabAcross(tester);
      final missed = controls.difference(reached);
      expect(
        missed,
        isEmpty,
        reason:
            'a screen reader can name these and a keyboard cannot reach them:\n'
            '${missed.join('\n')}',
      );
    }

    testWidgets('on the inbox', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester);
      await expectAllReachable(tester);
      handle.dispose();
    });

    testWidgets('in a conversation', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, home: const ChatView(chatId: 'merged:anna'));
      await expectAllReachable(tester);
      handle.dispose();
    });

    testWidgets('on search', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, home: const SearchScreen(initialQuery: 'the'));
      await expectAllReachable(tester);
      handle.dispose();
    });
  });

  group('traversal', () {
    testWidgets('Tab reaches the rail and every inbox row', (tester) async {
      await pumpApp(tester);
      final reached = await tabThrough(tester);

      // Both of these were `GestureDetector`s, which Tab does not stop on —
      // so the whole inbox and the whole network filter were unreachable while
      // the `InkWell`-based controls beside them worked, which is worse than a
      // uniform absence because it looks like Tab works.
      expect(
        reached.any((label) => label.startsWith('All conversations')),
        isTrue,
        reason: 'Tab never landed on the rail: $reached',
      );
      expect(
        reached.any((label) => label.startsWith('Anna Maven')),
        isTrue,
        reason: 'Tab never landed on an inbox row: $reached',
      );
    });

    testWidgets('the rail comes before the inbox, not after it', (
      tester,
    ) async {
      await pumpApp(tester);
      final reached = await tabThrough(tester);

      final rail = reached.indexWhere(
        (label) => label.startsWith('All conversations'),
      );
      final firstRow = reached.indexWhere(
        (label) => label.startsWith('Anna Maven'),
      );
      expect(rail, isNonNegative);
      expect(firstRow, isNonNegative);
      // Ordered traversal rather than reading order, so this holds under RTL
      // too — reading order would put the rail last the moment the app is put
      // into Arabic.
      expect(rail, lessThan(firstRow));
    });

    testWidgets('Enter opens the focused conversation', (tester) async {
      final container = await pumpApp(tester);
      expect(container.read(selectedChatProvider), isNull);

      for (var i = 0; i < 60; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        if (focusedLabel()?.startsWith('Anna Maven') ?? false) break;
      }
      expect(focusedLabel(), startsWith('Anna Maven'));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      // Landing on a row that cannot be opened is the same dead end as never
      // landing on it.
      expect(container.read(selectedChatProvider), isNotNull);
    });

    testWidgets('the focused row wears a ring in the focus-ring colour', (
      tester,
    ) async {
      await pumpApp(tester);
      final ring = WeftTheme.build().extension<WeftPalette>()!.focusRing;

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      final painted = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .any((box) {
            final decoration = box.decoration;
            return decoration is BoxDecoration &&
                decoration.border?.top.color == ring;
          });
      expect(painted, isTrue);
    });
  });

  /// What each app-wide binding must be seen to do, and how to set it up.
  ///
  /// Keyed by description and checked against the bindings table below, so a
  /// binding added without an expectation fails here rather than shipping
  /// untested — which is the failure this group exists to make impossible.
  /// Every entry runs against *every* activator the binding carries: Weft
  /// binds two keys to four of its five commands, and a per-binding test that
  /// only pressed the first one would have left half the table unexercised.
  final effects =
      <
        String,
        ({
          Future<void> Function(WidgetTester, ProviderContainer) arrange,
          void Function(WidgetTester, ProviderContainer) expectFired,
        })
      >{
        'Next conversation': (
          arrange: (tester, container) async {},
          expectFired: (tester, container) => expect(
            container.read(selectedChatProvider),
            container.read(visibleChatsProvider).first.id,
          ),
        ),
        'Previous conversation': (
          arrange: (tester, container) async {},
          // From nowhere, "previous" is the bottom of the list: the user has
          // not been anywhere yet, so there is nothing to be before.
          expectFired: (tester, container) => expect(
            container.read(selectedChatProvider),
            container.read(visibleChatsProvider).last.id,
          ),
        ),
        'Search all conversations': (
          arrange: (tester, container) async {},
          expectFired: (tester, container) =>
              expect(find.byType(SearchScreen), findsOneWidget),
        ),
        'Write a message': (
          arrange: (tester, container) async {
            container.read(selectedChatProvider.notifier).select('merged:anna');
            await tester.pumpAndSettle();
          },
          expectFired: (tester, container) => expect(
            FocusManager.instance.primaryFocus?.debugLabel,
            'Braid composer',
          ),
        ),
        'Keyboard shortcuts': (
          arrange: (tester, container) async {},
          expectFired: (tester, container) =>
              expect(find.text('New line'), findsOneWidget),
        ),
      };

  group('every shortcut fires its action', () {
    test('the expectations below cover every app-wide binding', () {
      final bound = weftKeyBindings()
          .where((b) => b.intent != null)
          .map((b) => b.description)
          .toSet();
      // Both directions. A missing expectation is an untested command; a stale
      // one is an expectation about a key nobody can press any more.
      expect(effects.keys.toSet(), bound);
    });

    for (final entry in effects.entries) {
      // One test per key rather than a loop inside one, so the second
      // combination is proved to do the thing rather than proved to find it
      // already done by the first — and so a failure names the key.
      for (final activator in bindingFor(entry.key).activators) {
        testWidgets('${entry.key} — ${describeShortcut(activator)}', (
          tester,
        ) async {
          final container = await pumpApp(tester);
          await entry.value.arrange(tester, container);
          await pressActivator(tester, activator);
          entry.value.expectFired(tester, container);
        });
      }
    }
  });

  group('shortcuts', () {
    testWidgets('nothing app-wide is bound to an unmodified key', (
      tester,
    ) async {
      // The rule that keeps a shortcut from eating a character while the
      // composer has focus. Escape and Enter *are* Weft's, but they are bound
      // inside the chat and fall through when they have nothing to do.
      for (final activator in weftShortcutMap().keys) {
        activator as SingleActivator;
        expect(
          activator.control || activator.meta || activator.alt,
          isTrue,
          reason: '${activator.trigger.keyLabel} is bound with no modifier',
        );
      }
    });

    testWidgets('search opens with the field focused', (tester) async {
      await pumpApp(tester);
      expect(find.byType(SearchScreen), findsNothing);

      await press(tester, 'Search all conversations');
      expect(find.byType(SearchScreen), findsOneWidget);

      // Twice is once: the second press used to push a second search screen,
      // and the Escape out of it landed the user back on a search they thought
      // they had left.
      await press(tester, 'Search all conversations');
      expect(find.byType(SearchScreen), findsOneWidget);
    });

    testWidgets('the shortcuts sheet is reachable by its own shortcut', (
      tester,
    ) async {
      await pumpApp(tester);
      await press(tester, 'Keyboard shortcuts');

      expect(find.text('Keyboard shortcuts'), findsWidgets);
      // Every binding, including the three the composer owns — the sheet is
      // built from the same table, so it cannot describe a key that does
      // nothing or omit one that does something.
      expect(find.text('New line'), findsOneWidget);
      expect(find.text('Cancel reply or edit'), findsOneWidget);
    });

    testWidgets('next and previous move the open conversation', (tester) async {
      final container = await pumpApp(tester);
      final chats = container.read(visibleChatsProvider);
      expect(chats.length, greaterThan(1));

      await press(tester, 'Next conversation');
      expect(container.read(selectedChatProvider), chats.first.id);

      await press(tester, 'Next conversation');
      expect(container.read(selectedChatProvider), chats[1].id);

      await press(tester, 'Previous conversation');
      expect(container.read(selectedChatProvider), chats.first.id);
    });

    testWidgets('next conversation is inert on a one-pane window', (
      tester,
    ) async {
      // Disabled rather than silent: with no detail pane there is nothing for
      // the selection to move in, so the key carries on to whoever else wants
      // it instead of being eaten by something the user cannot see happening.
      final container = await pumpApp(tester, size: const Size(430, 900));
      await press(tester, 'Next conversation');
      expect(container.read(selectedChatProvider), isNull);
    });

    testWidgets('the composer is reachable from the inbox', (tester) async {
      final container = await pumpApp(tester);
      // Two-pane, so the composer is a *sibling* of the list the user is in —
      // which is exactly why the shortcut goes through a registry rather than
      // an `Actions` handler inside the conversation.
      container.read(selectedChatProvider.notifier).select('merged:anna');
      await tester.pumpAndSettle();

      await press(tester, 'Write a message');
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Braid composer');
    });
  });

  group('the composer', () {
    Future<void> pumpChat(WidgetTester tester) async {
      await pumpApp(tester, home: const ChatView(chatId: 'merged:anna'));
    }

    Future<void> typeInComposer(WidgetTester tester, String text) async {
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
    }

    testWidgets('Shift+Enter breaks the line and Enter sends it', (
      tester,
    ) async {
      await pumpChat(tester);
      await typeInComposer(tester, 'first');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();

      final controller = tester.widget<TextField>(find.byType(TextField));
      // KEY-04: `maxLines: 5` was unreachable from a desktop keyboard, because
      // `TextInputAction.send` made the embedder call `performAction` for
      // Shift+Enter exactly as it did for Enter.
      expect(controller.controller!.text, 'first\n');

      await tester.enterText(find.byType(TextField), 'first\nsecond');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(controller.controller!.text, isEmpty);
      // Emptied *because it was sent*, not because Enter cleared a field: the
      // two look identical on screen for the frame after the key.
      expect(repository.lastCallTo('send')?.body, 'first\nsecond');
    });

    testWidgets('a newline lands where the caret is, not at the end', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'abcd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 2);

      insertComposerNewline(controller);

      expect(controller.text, 'ab\ncd');
      expect(controller.selection.baseOffset, 3);
    });

    testWidgets('Escape leaves reply mode', (tester) async {
      await pumpChat(tester);
      await tester.longPress(
        find.text('Quick update from my side.', findRichText: true).first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Cancel reply'), findsOneWidget);
      // Entering reply mode puts the caret in the composer, which is both the
      // obvious behaviour and what makes Escape reachable: it is bound inside
      // the conversation, so it only fires while the focus is in one.
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Braid composer');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // The context bar is gone, which is the whole observable difference —
      // KEY-05 was that `_cancelComposerContext` had exactly one way in, the
      // close button.
      expect(find.byTooltip('Cancel reply'), findsNothing);
    });

    testWidgets('Escape with nothing to cancel leaves the route alone', (
      tester,
    ) async {
      await pumpChat(tester);
      // Deliberately not awaited: the future a modal route hands back
      // completes when the sheet is *dismissed*, which is the thing this test
      // is about to do with the key it is testing.
      unawaited(showShortcutsSheet(tester.element(find.byType(ChatView))));
      await tester.pumpAndSettle();
      expect(find.text('New line'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // A chat that swallowed every Escape would need two presses here, and
      // the first would do nothing anybody could see.
      expect(find.text('New line'), findsNothing);
    });

    testWidgets('an unmodified key is not a shortcut', (tester) async {
      await pumpChat(tester);
      await typeInComposer(tester, 'draft');

      // The letters every binding in the table is built on, pressed bare while
      // the composer holds the caret. A shortcut map with an unmodified entry
      // in it would navigate away mid-sentence — which is the failure mode the
      // "no unmodified binding" rule exists to make impossible.
      for (final key in [
        LogicalKeyboardKey.keyK,
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.keyM,
        LogicalKeyboardKey.slash,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }

      expect(find.byType(SearchScreen), findsNothing);
      expect(find.text('New line'), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Braid composer');
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'draft');
    });
  });
}
