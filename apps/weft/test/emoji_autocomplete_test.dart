import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/settings.dart';
import 'package:weft/app/shortcuts.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/emoji_autocomplete.dart';
import 'package:weft/features/chat/emoji_picker_sheet.dart';
import 'package:weft/features/chat/emoji_shortcodes.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';

import 'support/recording_repository.dart';

/// `:thumbs` → 👍 in the composer.
///
/// The one behaviour worth more than the rest is that Return picks an emoji
/// *instead of* sending: a key that does both sends a message with `:thum` in
/// it to somebody else's phone.
void main() {
  TextEditingValue at(String text, [int? caret]) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret ?? text.length),
  );

  group('when the list opens', () {
    test('a colon at the start or after a space, and two characters', () {
      expect(shortcodeQueryAt(at(':th'))?.text, 'th');
      expect(shortcodeQueryAt(at('hi :upside'))?.text, 'upside');
      expect(shortcodeQueryAt(at('hi :upside'))?.start, 3);
      expect(shortcodeQueryAt(at('line\n:+1'))?.text, '+1');
    });

    test('not for one character, which is every :D and :P', () {
      expect(shortcodeQueryAt(at(':D')), isNull);
      expect(shortcodeQueryAt(at('ok :p')), isNull);
    });

    test('not for times, links or a word with a colon after it', () {
      expect(shortcodeQueryAt(at('meet at 10:30')), isNull);
      expect(shortcodeQueryAt(at('see https://example.org')), isNull);
      expect(shortcodeQueryAt(at('Note:important')), isNull);
    });

    test('not inside a code span or block', () {
      expect(shortcodeQueryAt(at('run `foo :bar')), isNull);
      expect(shortcodeQueryAt(at('```\nkey :value')), isNull);
      expect(shortcodeQueryAt(at('`a` :smile'))?.text, 'smile');
    });

    test('not with the caret back inside a word, or a selection', () {
      expect(shortcodeQueryAt(at(':thumbsup', 4)), isNull);
      expect(
        shortcodeQueryAt(
          const TextEditingValue(
            text: ':thumbs',
            selection: TextSelection(baseOffset: 0, extentOffset: 7),
          ),
        ),
        isNull,
      );
    });
  });

  group('ranking', () {
    test('prefix matches come before matches further in', () {
      final names = searchEmojiShortcodes('upside').map((s) => s.name);
      expect(names.first, 'upside_down_face');

      final heart = searchEmojiShortcodes('heart');
      expect(heart.first.name, 'heart');
      expect(heart.first.emoji, '❤️');
      final firstInside = heart.indexWhere((s) => !s.name.startsWith('heart'));
      final lastPrefix = heart.lastIndexWhere(
        (s) => s.name.startsWith('heart'),
      );
      expect(firstInside, greaterThan(lastPrefix));
    });

    test('the common aliases are there', () {
      expect(emojiForShortcode('thumbsup')?.emoji, '👍');
      expect(emojiForShortcode('+1')?.emoji, '👍');
      expect(emojiForShortcode('thumbs_up')?.emoji, '👍');
      expect(emojiForShortcode('joy')?.emoji, '😂');
      expect(emojiForShortcode('upside_down_face')?.emoji, '🙃');
    });

    test('letters in order find a name with a typo or abbreviation', () {
      expect(
        searchEmojiShortcodes('thmbsup').map((s) => s.emoji),
        contains('👍'),
      );
    });

    test('a recently used emoji goes first within its tier', () {
      final plain = searchEmojiShortcodes('sm');
      final last = plain.lastWhere((s) => s.name.startsWith('sm'));
      final ranked = searchEmojiShortcodes('sm', recents: [last.emoji]);
      expect(ranked.first.emoji, last.emoji);
    });

    test('a skin tone is applied to the emoji that take one', () {
      final toned = searchEmojiShortcodes(
        'thumbsup',
        skinTone: kSkinToneModifiers[2],
      );
      expect(toned.first.emoji, '👍\u{1F3FD}');
      final heart = searchEmojiShortcodes(
        'heart',
        skinTone: kSkinToneModifiers[2],
      );
      expect(heart.first.emoji, '❤️', reason: 'a heart has no skin');
    });
  });

  group('closing colon', () {
    test('converts an exact name', () {
      final out = convertClosedShortcode(at('nice :thumbsup:'));
      expect(out?.text, 'nice 👍');
      expect(out?.selection.baseOffset, 'nice 👍'.length);
      expect(convertClosedShortcode(at(':x:'))?.text, '❌');
    });

    test('leaves anything that is not a name, or not a shortcode', () {
      expect(convertClosedShortcode(at(':thumbsu:')), isNull);
      expect(convertClosedShortcode(at('at 12:30:')), isNull);
      expect(convertClosedShortcode(at('`code :joy:')), isNull);
    });
  });

  group('in a field', () {
    late int sends;
    late TextEditingController controller;
    late FocusNode focus;

    setUp(() {
      sends = 0;
      controller = TextEditingController();
      focus = FocusNode();
    });
    tearDown(() {
      controller.dispose();
      focus.dispose();
    });

    Future<void> pump(
      WidgetTester tester, {
      TextDirection direction = TextDirection.ltr,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: Directionality(
              textDirection: direction,
              child: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: 600,
                    // The composer's arrangement: its `Shortcuts` binds
                    // Return to send, outside the autocomplete.
                    child: Shortcuts(
                      shortcuts: composerShortcuts,
                      child: Actions(
                        actions: {
                          SendComposerIntent:
                              CallbackAction<SendComposerIntent>(
                                onInvoke: (_) => sends++,
                              ),
                        },
                        child: EmojiShortcodeAutocomplete(
                          controller: controller,
                          focusNode: focus,
                          child: TextField(
                            controller: controller,
                            focusNode: focus,
                            autofocus: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
    }

    Finder popup() => find.byWidgetPredicate(
      (w) => w is Text && (w.data?.startsWith(':') ?? false),
    );

    testWidgets('opens above the field with emoji and names', (tester) async {
      await pump(tester);
      await type(tester, 'hi :thumbs');
      expect(find.text(':thumbsup:'), findsOneWidget);
      expect(find.text('👍'), findsOneWidget);
      expect(
        tester.getBottomLeft(find.text(':thumbsup:')).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
      expect(
        popup().evaluate().length,
        lessThanOrEqualTo(kEmojiPopupVisibleRows + 2),
        reason: 'eight rows show; the rest scroll',
      );
    });

    testWidgets('does not open for a time', (tester) async {
      await pump(tester);
      await type(tester, 'at 10:30');
      expect(popup(), findsNothing);
    });

    testWidgets('Return inserts the selected emoji and does not send', (
      tester,
    ) async {
      await pump(tester);
      await type(tester, 'great :thumbsu');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.text, 'great 👍 ');
      expect(sends, 0);
      expect(popup(), findsNothing);

      // Closed again, Return is the composer's.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sends, 1);
    });

    testWidgets('↓ moves the selection and Tab inserts it', (tester) async {
      await pump(tester);
      await type(tester, ':smile');
      final second = searchEmojiShortcodes('smile')[1];
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.text, '${second.emoji} ');
      expect(focus.hasFocus, isTrue, reason: 'Tab did not move focus on');
    });

    testWidgets('↑ from the top wraps to the bottom', (tester) async {
      await pump(tester);
      await type(tester, ':thumbsd');
      final all = searchEmojiShortcodes('thumbsd');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.text, '${all.last.emoji} ');
    });

    testWidgets('Escape closes it, and it stays closed for that query', (
      tester,
    ) async {
      await pump(tester);
      await type(tester, ':joy');
      expect(popup(), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(popup(), findsNothing);
      await type(tester, ':joy_');
      expect(popup(), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sends, 1, reason: 'with the list closed Return sends again');
    });

    testWidgets('a click on a row inserts it', (tester) async {
      await pump(tester);
      await type(tester, ':upside');
      await tester.tap(find.text(':upside_down_face:'));
      await tester.pump();
      expect(controller.text, '🙃 ');
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('typing the closing colon converts an exact name', (
      tester,
    ) async {
      await pump(tester);
      await type(tester, 'yes :thumbsup');
      // As a keystroke would: one character more, the caret after it.
      controller.value = const TextEditingValue(
        text: 'yes :thumbsup:',
        selection: TextSelection.collapsed(offset: 14),
      );
      await tester.pump();
      expect(controller.text, 'yes 👍');
      expect(popup(), findsNothing);
    });

    testWidgets('a pick lands in the recents and ranks first next time', (
      tester,
    ) async {
      await pump(tester);
      final last = searchEmojiShortcodes(
        'sm',
      ).lastWhere((s) => s.name.startsWith('sm'));
      await type(tester, ':sm');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TextField)),
      );
      container.read(reactionRecentsProvider.notifier).note(last.emoji);
      await type(tester, '');
      await type(tester, ':sm');
      final rows = popup().evaluate().map((e) => (e.widget as Text).data);
      expect(rows.first, ':${last.name}:');
    });

    testWidgets('the skin tone chosen in the reaction picker is used', (
      tester,
    ) async {
      await pump(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TextField)),
      );
      container
          .read(reactionSkinToneProvider.notifier)
          .choose(kSkinToneModifiers[2]);
      await type(tester, ':thumbsu');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.text, '👍\u{1F3FD} ');
    });

    testWidgets('announces the selection to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      final spoken = <String>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        (message) async {
          final data = (message as Map)['data'] as Map;
          if (data['message'] is String) spoken.add(data['message'] as String);
          return null;
        },
      );
      await pump(tester);
      await type(tester, ':thumbsu');
      expect(spoken.last, '👍 :thumbsup:, 1 of 1');
      expect(find.bySemanticsLabel('Emoji suggestions'), findsOneWidget);
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        null,
      );
      handle.dispose();
    });

    testWidgets('right to left, it stays inside the field', (tester) async {
      await pump(tester, direction: TextDirection.rtl);
      await type(tester, ':thumbs');
      final field = tester.getRect(find.byType(TextField));
      final row = tester.getRect(find.text(':thumbsup:'));
      expect(row.left, greaterThanOrEqualTo(field.left));
      expect(row.right, lessThanOrEqualTo(field.right));
    });
  });

  group('in a conversation', () {
    late DemoChatRepository demo;
    late RecordingChatRepository repository;

    setUp(() {
      clearMessageDocumentCache();
      demo = DemoChatRepository(uploadTick: Duration.zero);
      repository = RecordingChatRepository(demo);
    });
    tearDown(() => demo.dispose());

    Future<void> pump(WidgetTester tester, WeftSurface surface) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: const WeftAppearance().themeFor(
              Brightness.light,
              surface: surface,
            ),
            home: const ChatView(chatId: 'merged:anna'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Return picks the emoji in the composer, then sends', (
      tester,
    ) async {
      await pump(tester, WeftSurface.mac);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'ship it :rocke');
      await tester.pump();
      expect(find.text(':rocket:'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repository.lastCallTo('send'), isNull);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'ship it 🚀 ');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repository.lastCallTo('send')?.body, 'ship it 🚀');
    });

    testWidgets('a phone keeps its own keyboard: no list', (tester) async {
      await pump(tester, WeftSurface.touch);
      await tester.enterText(find.byType(TextField), 'ship it :rocke');
      await tester.pump();
      expect(find.text(':rocket:'), findsNothing);
    });
  });
}
