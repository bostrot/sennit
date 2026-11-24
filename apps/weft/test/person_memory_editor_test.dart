/// The memory editors — a chat's and a person's — and the personal memory
/// settings.
///
/// The editors' promises: what is typed is kept, a suggested fact reaches a
/// note only through its tick or "Add to profile", and "Learn from chat" asks
/// nothing of the model while the memory switch is off. The settings screen's: the switch is off
/// until turned on, and the two that depend on it cannot be turned on alone.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/person_memory_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/contact/person_memory_screen.dart';
import 'package:weft/features/settings/person_memory_settings_screen.dart';
import 'package:weft/services/ai/person_memory.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

import 'support/golden_harness.dart';

const _anna = Chat(
  id: '!dm:example.org',
  title: 'Anna',
  sources: [
    ChatSource(roomId: '!dm:example.org', network: ChatNetwork.whatsapp),
  ],
);
const _keys = ['room:!dm:example.org'];
const MemoryPerson _person = (name: 'Anna', keys: ['dm:!dm:example.org']);

void main() {
  final en = lookupAppL10n(const Locale('en'));
  const size = Size(500, 1400);

  Future<WeftStores> pumpEditor(
    WidgetTester tester, {
    MemoryBook book = MemoryBook.empty,
  }) async {
    final stores = WeftStores.inMemory()..personMemory = book.encode();
    await pumpWeft(
      tester,
      MemoryEditor.chat(
        chat: _anna,
        people: const [_person],
        loadMessages: (_) async => const [],
      ),
      size: size,
      stores: stores,
    );
    return stores;
  }

  MemoryBook bookOf(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(MemoryEditor)),
  ).read(personMemoryProvider);

  Finder noteField() => find.byKey(const ValueKey('memory-note'));

  testWidgets('shows the note, says it is not sent, and keeps what is typed', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      book: MemoryBook.empty.withNote(_keys, 'Calls me Ricky'),
    );
    expect(find.text(en.chatMemoryScreenTitle('Anna')), findsOneWidget);
    expect(find.text('Calls me Ricky'), findsOneWidget);
    expect(find.text(en.personMemoryOffNotice), findsOneWidget);

    await tester.enterText(noteField(), 'Calls me Ricky\n- Du, never Sie');
    // Saved a moment after typing stops, not on every key.
    expect(bookOf(tester).noteFor(_keys), 'Calls me Ricky');
    await tester.pump(const Duration(seconds: 1));
    expect(bookOf(tester).noteFor(_keys), 'Calls me Ricky\n- Du, never Sie');
  });

  testWidgets('an empty note offers the suggested headings', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.text(en.personMemoryUseTemplate));
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester.widget<TextField>(noteField()).controller!.text,
      en.chatMemoryHint,
    );
    expect(find.text(en.personMemoryUseTemplate), findsNothing);
  });

  testWidgets('a suggestion reaches the note only through its tick', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      book: MemoryBook.empty.withNote(_keys, 'Calls me Ricky').withProposals(
        _keys,
        const ['Daughter Mia, born 12 March', 'Likes jazz'],
      ),
    );
    expect(find.text(en.personMemorySuggestionsTitle), findsOneWidget);
    expect(find.text('Daughter Mia, born 12 March'), findsOneWidget);

    // Typed but not yet saved: accepting must add to this, not to the old
    // note.
    await tester.enterText(noteField(), 'Calls me Ricky\nDu');
    await tester.tap(find.byTooltip(en.personMemoryAccept).first);
    await tester.pump();
    expect(
      bookOf(tester).noteFor(_keys),
      'Calls me Ricky\nDu\n- Daughter Mia, born 12 March',
    );
    expect(
      tester.widget<TextField>(noteField()).controller!.text,
      'Calls me Ricky\nDu\n- Daughter Mia, born 12 March',
    );

    await tester.tap(find.byTooltip(en.personMemoryDismiss));
    await tester.pump();
    expect(bookOf(tester).suggestionsFor(_keys), isEmpty);
    expect(bookOf(tester).noteFor(_keys), isNot(contains('jazz')));
    expect(find.text(en.personMemorySuggestionsTitle), findsNothing);
  });

  testWidgets('"Add to profile" puts a fact in the person\'s memory', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      book: MemoryBook.empty.withProposals(_keys, const ['Calls me Ricky']),
    );
    await tester.tap(find.byTooltip(en.personMemoryPromote));
    await tester.pump();
    expect(bookOf(tester).noteFor(_person.keys), '- Calls me Ricky');
    expect(bookOf(tester).noteFor(_keys), isEmpty);
    expect(bookOf(tester).suggestionsFor(_keys), isEmpty);
  });

  testWidgets('a person\'s memory counts toward a few lines', (tester) async {
    await pumpWeft(
      tester,
      MemoryEditor.person(person: _person),
      size: size,
      stores: WeftStores.inMemory(),
    );
    expect(find.text(en.personMemoryScreenTitle('Anna')), findsOneWidget);
    expect(find.text(en.personMemorySharedHint), findsOneWidget);
    expect(find.text(en.personMemoryLearn), findsNothing);
    expect(find.text('0 / $kPersonMemorySoftLimit'), findsOneWidget);

    await tester.enterText(noteField(), 'x' * (kPersonMemorySoftLimit + 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(en.personMemoryCondense), findsOneWidget);
    expect(bookOf(tester).noteFor(_person.keys), hasLength(301));
  });

  testWidgets('learning asks nothing while the memory is off', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.byKey(const ValueKey('memory-learn')));
    await tester.pumpAndSettle();
    expect(find.text(en.personMemoryLearnOff), findsOneWidget);
    expect(bookOf(tester).suggestionsFor(_keys), isEmpty);
  });

  group('settings', () {
    testWidgets('everything is off until the master switch is on', (
      tester,
    ) async {
      final stores = WeftStores.inMemory();
      await pumpWeft(
        tester,
        const PersonMemorySettingsScreen(),
        size: size,
        stores: stores,
      );
      expect(find.text(en.personMemoryExplainer), findsOneWidget);

      SwitchListTile tile(String title) => tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, title),
      );
      expect(tile(en.personMemoryUseInAi).value, isFalse);
      expect(tile(en.personMemoryAutoTitle).onChanged, isNull);
      expect(tile(en.personMemoryAutoTitle).value, isFalse);
      expect(tile(en.personMemoryEncryptedTitle).onChanged, isNull);

      await tester.tap(find.text(en.personMemoryUseInAi));
      await tester.pumpAndSettle();
      expect(stores.settings.getBool(WeftSettings.personMemoryInAi), isTrue);
      // Automatic learning is on as soon as the memory is.
      expect(tile(en.personMemoryAutoTitle).onChanged, isNotNull);
      expect(tile(en.personMemoryAutoTitle).value, isTrue);
      expect(tile(en.personMemoryEncryptedTitle).value, isFalse);
      expect(
        stores.settings.getBool(WeftSettings.personMemoryEncryptedChats),
        isFalse,
      );
    });

    // The explainer once took half a phone screen. One or two lines in every
    // language, at phone width, in the real font; the whole story is behind
    // "Learn more".
    group('text length', () {
      setUpAll(loadGoldenFonts);
      for (final locale in const ['en', 'de', 'es', 'fr', 'pt', 'zh']) {
        testWidgets('the explainer is two lines at most, in $locale', (
          tester,
        ) async {
          await pumpWeft(
            tester,
            const PersonMemorySettingsScreen(),
            size: const Size(390, 844),
            stores: WeftStores.inMemory(),
            variant: WeftGoldenVariant(name: locale, locale: Locale(locale)),
          );
          final l10n = lookupAppL10n(Locale(locale));
          final explainer = find.byKey(
            const ValueKey('person-memory-explainer'),
          );
          final lineHeight = tester
              .renderObject<RenderParagraph>(explainer)
              .getFullHeightForCaret(const TextPosition(offset: 0));
          expect(
            tester.getSize(explainer).height,
            lessThanOrEqualTo(lineHeight * 2 + 1),
          );
          expect(find.text(l10n.personMemoryLearnMore), findsOneWidget);
          for (final subtitle in [
            l10n.personMemoryUseInAiSubtitle,
            l10n.personMemoryAutoSubtitle,
            l10n.personMemoryEncryptedSubtitle,
          ]) {
            expect(subtitle.length, lessThanOrEqualTo(70), reason: subtitle);
          }

          await tester.tap(find.text(l10n.personMemoryLearnMore));
          await tester.pumpAndSettle();
          expect(find.text(l10n.personMemoryDetailsTitle), findsOneWidget);
        });
      }
    });
  });
}
