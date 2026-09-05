import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kDoubleTapMinTime, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/app/shortcuts.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/message_actions_sheet.dart';
import 'package:weft/features/chat/rich_text_view.dart';

import 'support/golden_harness.dart';
import 'support/seeded_repository.dart';

/// Selecting message text with a pointer, and not selecting it with a thumb.
///
/// The two halves are one test file because the guarantee is a *pair*: a Mac
/// gets a drag-selectable thread, and a phone gets exactly what it had — the
/// long-press sheet, no selection handles, no `SelectionArea` in the tree at
/// all. Either one alone passes while the other is broken.
///
/// Keyboard work is invoked as an intent rather than typed as a chord, for the
/// reason `composer_paste_test.dart` gives at length: a modifier chord through
/// the test binding waits on a platform that is not there. What is worth
/// pinning is the wiring on both sides of the key.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadGoldenFonts);

  const first = 'Hello there';
  const second = 'See you at six';

  late DemoChatRepository demo;
  String? copied;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    demo.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// A thread of [messages], pumped on the surface [pointer] describes.
  Future<SeededChatRepository> pumpThread(
    WidgetTester tester, {
    required List<WeftMessage> messages,
    required bool pointer,
  }) async {
    final repository = SeededChatRepository(demo, messages: messages);
    await pumpWeft(
      tester,
      ChatView(chatId: repository.chatId),
      size: const Size(900, 700),
      surface: pointer ? WeftSurface.mac : WeftSurface.touch,
      repository: repository,
    );
    return repository;
  }

  /// The two-line exchange most of these tests drag across.
  List<WeftMessage> exchange() => [
    seededMessage(eventId: r'$one', body: first, minutesAgo: 4),
    seededMessage(eventId: r'$two', body: second, minutesAgo: 3),
  ];

  Finder bodyOf(String text) => find.text(text, findRichText: true);

  /// Drags the mouse from [from] to [to], the way a selection is made.
  Future<void> dragSelect(WidgetTester tester, Offset from, Offset to) async {
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    // In steps, because a single jump can land outside every selectable on the
    // way and leave the region with one edge.
    for (var i = 1; i <= 4; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 4)!);
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// ⌘C, dispatched from [at] the way the menu bar and the key both dispatch
  /// it — through the tree, so which handler answers is the thing under test.
  Future<void> pressCopy(WidgetTester tester, Finder at) async {
    final context = tester.element(at);
    const intent = CopyMessageIntent();
    final action = Actions.maybeFind<CopyMessageIntent>(
      context,
      intent: intent,
    );
    expect(
      action,
      isNotNull,
      reason: 'nothing above $at answers CopyMessageIntent',
    );
    if (action!.isEnabled(intent)) {
      Actions.of(context).invokeAction(action, intent, context);
    }
    await tester.pumpAndSettle();
  }

  group('a machine with a pointer', () {
    testWidgets('a drag across two messages selects both of them', (
      tester,
    ) async {
      await pumpThread(tester, messages: exchange(), pointer: true);

      expect(
        find.byType(SelectionArea),
        findsOneWidget,
        reason: 'the thread is one selection, not one per bubble',
      );

      // Reversed list: the newer message is the lower one on screen.
      await dragSelect(
        tester,
        tester.getTopLeft(bodyOf(first)) + const Offset(1, 4),
        tester.getBottomRight(bodyOf(second)) - const Offset(1, 4),
      );
      await pressCopy(tester, find.byType(SelectionArea));

      expect(copied, contains(first));
      expect(copied, contains(second));
    });

    testWidgets('two messages copy as two lines, not one run-on', (
      tester,
    ) async {
      // `SelectionArea` concatenates its children with nothing between them —
      // `Hello thereSee you at six` — which is the words without the shape.
      await pumpThread(tester, messages: exchange(), pointer: true);

      await dragSelect(
        tester,
        tester.getTopLeft(bodyOf(first)) + const Offset(1, 4),
        tester.getBottomRight(bodyOf(second)) - const Offset(1, 4),
      );
      await pressCopy(tester, find.byType(SelectionArea));

      expect(copied, '$first\n$second');
    });

    testWidgets('the clock and the network badge stay out of the copy', (
      tester,
    ) async {
      // Chrome *about* a message, not words anybody wrote. A merged thread
      // draws both on every bubble, and an excerpt pasted into a mail should
      // not read `Telegram Hello there 13:56 Signal See you at six 13:57`.
      await pumpThread(
        tester,
        pointer: true,
        messages: [
          seededMessage(
            eventId: r'$one',
            body: first,
            minutesAgo: 4,
            roomId: '!tg:example.org',
          ),
          seededMessage(
            eventId: r'$two',
            body: second,
            minutesAgo: 3,
            roomId: '!sig:example.org',
            network: ChatNetwork.signal,
          ),
        ],
      );

      await dragSelect(
        tester,
        tester.getTopLeft(bodyOf(first)) + const Offset(1, 4),
        tester.getBottomRight(bodyOf(second)) - const Offset(1, 4),
      );
      await pressCopy(tester, find.byType(SelectionArea));

      expect(copied, '$first\n$second');
    });

    testWidgets('a double-click selects the word under it', (tester) async {
      // Long enough to wrap. The hover cluster slides in over the *top* of a
      // bubble — that is the Slack shape and it is deliberate — so the word
      // under the pointer on the first line is under a button by the time the
      // second click lands. The last line is clear of it, which is also where
      // a reader double-clicking a long message is most likely to be.
      const wrapped =
          'Hello there, this is a long enough line to wrap onto a second one '
          'so the last word sits well clear of the hover cluster: pomegranate';
      await pumpThread(
        tester,
        pointer: true,
        messages: [
          seededMessage(eventId: r'\$long', body: wrapped, minutesAgo: 4),
        ],
      );

      final body = bodyOf(wrapped);
      // On the last line, in the last word.
      final word = tester.getBottomLeft(body) + const Offset(60, -6);
      // The same pointer for both, which is what makes them consecutive taps
      // rather than two unrelated clicks.
      await tester.tapAt(word, pointer: 7, kind: PointerDeviceKind.mouse);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(word, pointer: 7, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      await pressCopy(tester, find.byType(SelectionArea));

      expect(copied, isNotNull);
      expect(copied!.trim(), isNot(contains(' ')));
      expect(wrapped, contains(copied!.trim()));
    });

    testWidgets('a mention copies as the name, never as the id', (
      tester,
    ) async {
      // The same class of leak the Phase 05 reply preview fixed: the pill says
      // "Anna Maven" and an mxid on the clipboard is a different fact about a
      // person than the one on the screen.
      await pumpThread(
        tester,
        pointer: true,
        messages: [
          seededMessage(
            eventId: r'$mention',
            body: 'ping @anna:example.org please',
            formattedBody:
                'ping <a href="https://matrix.to/#/@anna:example.org">'
                'Anna Maven</a> please',
            minutesAgo: 2,
          ),
        ],
      );

      final body = find.byType(RichTextView).first;
      await dragSelect(
        tester,
        tester.getTopLeft(body) + const Offset(1, 4),
        tester.getBottomRight(body) - const Offset(1, 4),
      );
      await pressCopy(tester, find.byType(SelectionArea));

      expect(copied, contains('Anna Maven'));
      expect(copied, isNot(contains('@anna:example.org')));
    });

    testWidgets('a code block keeps its own lines and its indentation', (
      tester,
    ) async {
      await pumpThread(
        tester,
        pointer: true,
        messages: [
          seededMessage(
            eventId: r'$code',
            body: 'run this',
            formattedBody: '<p>run this</p><pre><code>one\n  two</code></pre>',
            minutesAgo: 2,
          ),
        ],
      );

      await dragSelect(
        tester,
        tester.getTopLeft(bodyOf('run this')) + const Offset(1, 4),
        tester.getBottomRight(find.text('one\n  two')) - const Offset(1, 4),
      );
      await pressCopy(tester, find.byType(SelectionArea));

      // The paragraph does not weld onto the code, and the indent survives.
      expect(copied, 'run this\none\n  two');
    });

    testWidgets('⌘C with nothing selected copies the focused message', (
      tester,
    ) async {
      await pumpThread(tester, messages: exchange(), pointer: true);

      // From inside a bubble, which is where the focus is when the reader has
      // tabbed to a message rather than dragged across one.
      await pressCopy(tester, find.byType(RichTextView).first);

      expect(copied, anyOf(first, second));
    });

    testWidgets('a selection wins over the focused message', (tester) async {
      await pumpThread(tester, messages: exchange(), pointer: true);

      await dragSelect(
        tester,
        tester.getTopLeft(bodyOf(first)) + const Offset(1, 4),
        tester.getBottomRight(bodyOf(first)) - const Offset(1, 4),
      );
      // Dispatched from inside the *second* bubble: a reader who has just
      // dragged across one message and pressed Copy means that drag, wherever
      // the focus ring happens to be.
      await pressCopy(tester, bodyOf(second));

      expect(copied?.trim(), first);
    });

    testWidgets('a long press does not open the actions sheet', (tester) async {
      // A mouse's long press is a click held still, which is how a careful
      // drag-select starts.
      await pumpThread(tester, messages: exchange(), pointer: true);

      await tester.longPress(bodyOf(first), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a right-click still raises Braid’s own menu, once', (
      tester,
    ) async {
      await pumpThread(tester, messages: exchange(), pointer: true);

      await tester.tapAt(
        tester.getCenter(bodyOf(first)),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(find.byType(PopupMenuItem<MessageActionChoice>), findsWidgets);
      expect(
        find.byType(AdaptiveTextSelectionToolbar),
        findsNothing,
        reason: 'two menus for one right-click is two menus too many',
      );
    });

    testWidgets('right-click on a selection copies the selection', (
      tester,
    ) async {
      await pumpThread(tester, messages: exchange(), pointer: true);

      await dragSelect(
        tester,
        tester.getTopLeft(bodyOf(second)) + const Offset(1, 4),
        tester.getBottomRight(bodyOf(second)) - const Offset(1, 4),
      );
      // On the *other* message, so what is copied cannot come from whichever
      // bubble the menu was raised over.
      await tester.tapAt(
        tester.getCenter(bodyOf(first)),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      // Every verb the menu had before is still on it.
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Reply'), findsOneWidget);

      await tester.tap(find.text('Copy text'));
      await tester.pumpAndSettle();

      expect(copied?.trim(), second);
    });

    testWidgets('the hover cluster and the reaction bar still answer a click', (
      tester,
    ) async {
      // Selection must not cost the message its verbs. The cluster is what
      // replaced long-press on a pointer, so if a live selection swallowed its
      // clicks there would be no way left to reply to a message at all.
      await pumpThread(
        tester,
        pointer: true,
        messages: [
          seededMessage(
            eventId: r'$one',
            body: first,
            minutesAgo: 4,
            reactions: [
              ReactionTally(
                key: '👍',
                senderIds: const ['@bob:example.org'],
                firstReactedAt: DateTime.utc(2026, 8, 28, 12),
              ),
            ],
          ),
          seededMessage(eventId: r'$two', body: second, minutesAgo: 3),
        ],
      );

      // One mouse for the whole scene, the way there is one on a desk: drag a
      // selection with it, then move it over a bubble and use the cluster.
      final from = tester.getTopLeft(bodyOf(first)) + const Offset(1, 4);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: from);
      addTearDown(mouse.removePointer);
      await tester.pump();

      await mouse.down(from);
      await tester.pump();
      final to = tester.getBottomRight(bodyOf(second)) - const Offset(1, 4);
      for (var i = 1; i <= 4; i++) {
        await mouse.moveTo(Offset.lerp(from, to, i / 4)!);
        await tester.pump();
      }
      await mouse.up();
      await tester.pumpAndSettle();

      await mouse.moveTo(tester.getCenter(bodyOf(second)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Reply').first);
      await tester.pumpAndSettle();
      // The composer's context bar names who is being answered on its
      // semantics node rather than in a `Text` — see `_ComposerContextBar`.
      expect(
        find.bySemanticsLabel('Replying to Anna Maven'),
        findsOneWidget,
        reason: 'the hover cluster still reaches the composer',
      );

      // And the reaction chip, which is a plain InkWell under the selection.
      await tester.tap(find.text('👍'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a caption and a transcript are text like any other', (
      tester,
    ) async {
      // A caption goes through `RichTextView` and gets selection for free; a
      // transcript is the one run of message text that does not, and states
      // its own line break — so this is where that would silently regress.
      final voice = WeftMessage(
        eventId: r'$voice',
        roomId: '!seeded:example.org',
        network: ChatNetwork.telegram,
        senderId: '@anna:example.org',
        senderName: 'Anna Maven',
        timestamp: DateTime(2026, 8, 18, 13, 55),
        kind: MessageKind.audio,
        isOwn: false,
        body: 'listen to this bit',
        attachmentUrl: r'$voice',
        durationMs: 4000,
        transcript: 'meet me by the portcullis at six',
      );
      await pumpThread(tester, pointer: true, messages: [voice]);

      await dragSelect(
        tester,
        // `.last`: the caption also appears, ellipsised, in the audio
        // tile's own one-line summary above it.
        tester.getTopLeft(bodyOf('listen to this bit').last) +
            const Offset(1, 4),
        tester.getBottomRight(find.text('meet me by the portcullis at six')) -
            const Offset(1, 4),
      );
      await pressCopy(tester, find.byType(SelectionArea));

      expect(copied, 'listen to this bit\nmeet me by the portcullis at six');
    });

    testWidgets('a tap on a link opens it, a drag from it selects', (
      tester,
    ) async {
      final launched = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
              if (call.method == 'launch') {
                launched.add((call.arguments as Map)['url']! as String);
              }
              return true;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/url_launcher'),
              null,
            ),
      );

      await pumpThread(
        tester,
        pointer: true,
        messages: [
          seededMessage(
            eventId: r'$link',
            body: 'the notes',
            formattedBody: '<a href="https://example.org/notes">the notes</a>',
            minutesAgo: 2,
          ),
        ],
      );

      final link = bodyOf('the notes');
      await tester.tapAt(tester.getCenter(link), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(launched, [
        'https://example.org/notes',
      ], reason: 'a click on a link still opens it under a SelectionArea');

      await dragSelect(
        tester,
        tester.getTopLeft(link) + const Offset(1, 4),
        tester.getBottomRight(link) - const Offset(1, 4),
      );
      await pressCopy(tester, find.byType(SelectionArea));

      expect(copied?.trim(), 'the notes');
      expect(
        launched,
        ['https://example.org/notes'],
        reason: 'a drag across a link selects it rather than opening it again',
      );
    });
  });

  group('a machine with a thumb', () {
    testWidgets('message text is not selectable', (tester) async {
      await pumpThread(tester, messages: exchange(), pointer: false);

      expect(find.byType(SelectionArea), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('a long press still opens the actions sheet', (tester) async {
      await pumpThread(tester, messages: exchange(), pointer: false);

      await tester.longPress(bodyOf(first), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
    });

    testWidgets('Copy from the sheet still copies the whole message', (
      tester,
    ) async {
      await pumpThread(tester, messages: exchange(), pointer: false);

      await tester.longPress(bodyOf(first), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy text'));
      await tester.pumpAndSettle();

      expect(copied, first);
    });
  });

  group('the keyboard around it', () {
    test('⌘C and Ctrl+C both reach the message copy', () {
      // Both modifiers unconditionally, for the reason ⌘V is bound both ways:
      // macOS never gets here — AppKit claims ⌘C through the menu bar — so
      // this table is what Windows and Linux run on.
      final copyKeys = messageCopyShortcuts.entries
          .where((e) => e.value is CopyMessageIntent)
          .map((e) => e.key)
          .cast<SingleActivator>()
          .toList();

      expect(
        copyKeys.any((a) => a.trigger == LogicalKeyboardKey.keyC && a.meta),
        isTrue,
      );
      expect(
        copyKeys.any((a) => a.trigger == LogicalKeyboardKey.keyC && a.control),
        isTrue,
      );
    });

    test('the copy bindings do not touch the composer’s paste', () {
      // ⌘V is the composer's and stays the composer's; the copy table is
      // installed around the message list and must not claim anything else.
      expect(
        messageCopyShortcuts.keys.cast<SingleActivator>().every(
          (a) => a.trigger == LogicalKeyboardKey.keyC,
        ),
        isTrue,
      );
      expect(
        composerShortcuts.entries
            .where((e) => e.value is PasteIntoComposerIntent)
            .length,
        2,
      );
    });

    testWidgets('⌘A in the composer selects the composer, not the thread', (
      tester,
    ) async {
      await pumpThread(tester, messages: exchange(), pointer: true);

      await tester.enterText(find.byType(TextField), 'draft text');
      await tester.pumpAndSettle();

      // From the caret, which is where the Mac menu bar dispatches Edit ▸
      // Select All from — `menus.dart` resolves it against `primaryFocus`.
      Actions.invoke(
        primaryFocus!.context!,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pumpAndSettle();

      // The caret's own field answered, so the thread was never asked.
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .controller
            .selection
            .textInside('draft text'),
        'draft text',
      );
      await pressCopy(tester, find.byType(SelectionArea));
      expect(copied, isNot(contains(first)));
    });

    testWidgets('⌘A inside the thread selects the thread', (tester) async {
      await pumpThread(tester, messages: exchange(), pointer: true);

      Actions.invoke(
        tester.element(find.byType(RichTextView).first),
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pumpAndSettle();
      await pressCopy(tester, find.byType(SelectionArea));

      expect(copied, contains(first));
      expect(copied, contains(second));
    });
  });
}
