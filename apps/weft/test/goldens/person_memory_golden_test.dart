import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/contact/person_memory_screen.dart';
import 'package:weft/features/settings/person_memory_settings_screen.dart';
import 'package:weft/services/ai/person_memory.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

import '../support/golden_harness.dart';

/// Goldens for personal memory: a chat's memory with what Sennit learned by
/// itself under it, a person's short memory, and the settings screen.
///
/// The editor frame is the one that matters. A learned fact has to read as
/// learned — marked, dated, one pinned — and apart from the user's own note
/// above it, with the last automatic update one tap from undone. The writing
/// style stands apart from the facts: the user's in the chat's memory,
/// Anna's in hers, the usual one on the settings screen.
void main() {
  setUpAll(loadGoldenFonts);

  const window = Size(620, 1180);
  const chat = Chat(
    id: '!dm:example.org',
    title: 'Anna',
    sources: [
      ChatSource(roomId: '!dm:example.org', network: ChatNetwork.whatsapp),
    ],
  );
  const keys = ['room:!dm:example.org'];
  const MemoryPerson anna = (name: 'Anna', keys: ['dm:!dm:example.org']);

  WeftStores stores() {
    var book = MemoryBook.empty
        .withNote(keys, '## Tone in this chat\nGerman, du, lots of emojis')
        .withNote(anna.keys, '- Annie, my sister');
    book = book
        .applyLearning(
          const MemoryUpdate(
            adds: [
              MemoryAddition('Lisbon trip in May, she books the flat'),
              MemoryAddition('Birthday on 3 June', about: 'Anna'),
              MemoryAddition(
                'Works at Deutsche Bahn since November',
                about: 'Anna',
              ),
            ],
            styles: {
              'me': 'Very short, all lowercase, no full stops, often an emoji; du',
              'Anna': 'Full sentences with capitals, an emoji in most',
              'default': 'Short and casual, few capitals',
            },
          ),
          chatKeys: keys,
          people: const [anna],
          numbered: const [],
          now: DateTime(2026, 11, 18, 9, 30),
        )
        .book;
    book = book.pinLearned(
      anna.keys,
      book.learnedFor(anna.keys).first,
      pinned: true,
    );
    book = book
        .applyLearning(
          const MemoryUpdate(
            adds: [
              MemoryAddition('Planning Mia’s birthday party, Sunday 15:00'),
            ],
          ),
          chatKeys: keys,
          people: const [anna],
          numbered: const [],
          now: DateTime(2026, 11, 24, 18, 5),
        )
        .book;
    final stores = WeftStores.inMemory()..personMemory = book.encode();
    stores.settings.setBool(WeftSettings.personMemoryInAi, value: true);
    return stores;
  }

  Future<void> expectGolden(
    WidgetTester tester,
    String name,
    Widget Function(Key key) screen,
  ) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      await pumpWeft(
        tester,
        screen(ValueKey(suffix)),
        size: window,
        mode: mode,
        stores: stores(),
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('person_memory_${name}_$suffix.png'),
      );
    }
  }

  testWidgets('a chat with learned facts, both themes', (tester) async {
    await expectGolden(
      tester,
      'editor',
      (key) => MemoryEditor.chat(
        key: key,
        chat: chat,
        people: const [anna],
        loadMessages: (_) async => const [],
      ),
    );
  });

  testWidgets('a person, both themes', (tester) async {
    await expectGolden(
      tester,
      'person',
      (key) => MemoryEditor.person(key: key, person: anna),
    );
  });

  testWidgets('the settings screen, both themes', (tester) async {
    await expectGolden(
      tester,
      'settings',
      (key) => PersonMemorySettingsScreen(key: key),
    );
  });
}
