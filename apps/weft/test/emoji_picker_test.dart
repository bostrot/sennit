import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' show Category;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/emoji_catalogue.dart';
import 'package:weft/features/chat/emoji_picker_sheet.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/recording_repository.dart';

/// The full reaction picker: every emoji the device draws, searchable, with a
/// skin tone, and recents that come back in the long-press row.
void main() {
  const chat = 'merged:anna';
  const line = 'Quick update from my side.';

  late DemoChatRepository demo;
  late RecordingChatRepository repository;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
    repository = RecordingChatRepository(demo);
  });
  tearDown(() => demo.dispose());

  Finder inSheet(Finder finder) =>
      find.descendant(of: find.byType(BottomSheet), matching: finder);

  Future<void> pump(
    WidgetTester tester, {
    ChatRepository? repo,
    EmojiSupportCheck? check,
    double? version = 16.0,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repo ?? repository),
          emojiVersionProvider.overrideWithValue(version),
          if (check != null) emojiSupportCheckProvider.overrideWithValue(check),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: const ChatView(chatId: chat),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openActions(WidgetTester tester) async {
    await tester.longPress(
      find.text(line, findRichText: true).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
  }

  Future<void> openPicker(WidgetTester tester) async {
    await openActions(tester);
    await tester.tap(find.byIcon(Icons.add_reaction_outlined).last);
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(inSheet(find.byType(TextField)), query);
    await tester.pumpAndSettle();
  }

  testWidgets('the picker opens on the full set, a tab per group', (
    tester,
  ) async {
    await pump(tester);
    await openPicker(tester);

    // No recents yet, so it opens on faces — far beyond the six of the quick
    // row and the seventy the old hand-picked list held.
    expect(inSheet(find.text('Smileys & people')), findsOneWidget);
    expect(inSheet(find.text('🫠')), findsOneWidget);
    for (final group in [
      'Animals & nature',
      'Food & drink',
      'Activities',
      'Travel & places',
      'Objects',
      'Symbols',
      'Flags',
    ]) {
      expect(find.byTooltip(group), findsOneWidget, reason: group);
    }

    await tester.tap(find.byTooltip('Flags'));
    await tester.pumpAndSettle();
    expect(inSheet(find.text('🏁')), findsOneWidget);

    await tester.tap(inSheet(find.text('🏁')));
    await tester.pumpAndSettle();
    expect(repository.lastCallTo('react')?.key, '🏁');
  });

  testWidgets('search finds an emoji by name and by shortcode', (tester) async {
    await pump(tester);
    await openPicker(tester);

    await search(tester, 'party');
    expect(inSheet(find.text('🎉')), findsOneWidget);
    // The group tabs give way to the results.
    expect(find.byTooltip('Flags'), findsNothing);

    await search(tester, ':thumbs_up:');
    expect(inSheet(find.text('👍')), findsOneWidget);

    await search(tester, 'qqqxzz');
    expect(inSheet(find.text('No emoji found')), findsOneWidget);
  });

  testWidgets('search speaks the reader language, and English too', (
    tester,
  ) async {
    await pump(tester, locale: const Locale('de'));
    await openPicker(tester);

    await search(tester, 'daumen');
    expect(inSheet(find.text('👍')), findsOneWidget);
    await search(tester, 'thumbs');
    expect(inSheet(find.text('👍')), findsOneWidget);
  });

  testWidgets('a pick from the picker joins the long-press row', (
    tester,
  ) async {
    await pump(tester);
    await openActions(tester);
    expect(inSheet(find.text('🎉')), findsNothing);
    await tester.tap(find.byIcon(Icons.add_reaction_outlined).last);
    await tester.pumpAndSettle();
    await search(tester, 'party');
    await tester.tap(inSheet(find.text('🎉')));
    await tester.pumpAndSettle();

    await openActions(tester);
    // In the quick row now, after the four that never move.
    final row = tester
        .widgetList<Text>(inSheet(find.byType(Text)))
        .map((t) => t.data)
        .where((d) => d != null && quickOrNew.contains(d))
        .toList();
    expect(row, ['👍', '❤️', '😂', '😮', '🎉', '😢']);

    // And at the top of the picker, under Recent.
    await tester.tap(find.byIcon(Icons.add_reaction_outlined).last);
    await tester.pumpAndSettle();
    expect(inSheet(find.text('Recent')), findsOneWidget);
    expect(inSheet(find.text('🎉')), findsOneWidget);
  });

  testWidgets('a skin tone reaches people and hands', (tester) async {
    await pump(tester);
    await openPicker(tester);

    await tester.tap(find.byTooltip('Skin tone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medium').last);
    await tester.pumpAndSettle();

    await search(tester, 'thumbs up');
    expect(inSheet(find.text('👍🏽')), findsOneWidget);
    await tester.tap(inSheet(find.text('👍🏽')));
    await tester.pumpAndSettle();
    expect(repository.lastCallTo('react')?.key, '👍🏽');
  });

  testWidgets('an emoji the device cannot draw is never offered', (
    tester,
  ) async {
    // The font answers no for the melting face, as an Android without the
    // Emoji 14 font would.
    await pump(
      tester,
      check: (emoji) async => [for (final e in emoji) e != '🫠'],
    );
    await openPicker(tester);

    expect(inSheet(find.text('😀')), findsOneWidget);
    expect(inSheet(find.text('🫠')), findsNothing);
    await search(tester, 'melting');
    expect(inSheet(find.text('🫠')), findsNothing);
  });

  testWidgets('a bridge that refuses the reaction says which network', (
    tester,
  ) async {
    await pump(tester, repo: _RefusingRepository(demo));
    await openPicker(tester);
    await search(tester, 'party');
    await tester.tap(inSheet(find.text('🎉')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Telegram didn’t accept that reaction. It may only allow some emoji.',
      ),
      findsOneWidget,
    );
    expect(find.text('That did not go through.'), findsNothing);
  });

  group('catalogue', () {
    Future<List<bool>> all(List<String> emoji) async => [
      for (final _ in emoji) true,
    ];

    test('newer emoji only on an OS that draws them', () async {
      final old = await buildEmojiCatalogue(
        languageCode: 'en',
        version: 14.0,
        check: all,
      );
      final current = await buildEmojiCatalogue(
        languageCode: 'en',
        version: 16.0,
        check: all,
      );
      bool has(EmojiCatalogue c, String e) => c.all.any((x) => x.emoji == e);

      expect(has(old, '🫠'), isTrue);
      expect(has(old, '🫨'), isFalse);
      expect(has(old, '🫩'), isFalse);
      expect(has(current, '🫨'), isTrue);
      expect(has(current, '🫩'), isTrue);
      expect(current.groups[Category.SMILEYS]!.length, greaterThan(300));
      expect(current.all.length, greaterThan(1600));
    });

    test('the quick row keeps four fixed and follows the reader', () {
      expect(quickReactionsWith(const []), kQuickReactions);
      expect(quickReactionsWith(const ['👍', '🎉']), [
        '👍',
        '❤️',
        '😂',
        '😮',
        '🎉',
        '😢',
      ]);
      expect(quickReactionsWith(const ['🔥', '🎉', '🙏']), [
        '👍',
        '❤️',
        '😂',
        '😮',
        '🔥',
        '🎉',
      ]);
      // A recent ❤ without its selector is still the heart in the fixed four.
      expect(quickReactionsWith(const ['❤']), kQuickReactions);
    });
  });
}

const quickOrNew = {'👍', '❤️', '😂', '😮', '😢', '🙏', '🎉'};

class _RefusingRepository extends RecordingChatRepository {
  _RefusingRepository(super.inner);

  @override
  Future<void> react(String chatId, String eventId, String key) async {
    throw const ReactionRejectedException(ChatNetwork.telegram);
  }
}
