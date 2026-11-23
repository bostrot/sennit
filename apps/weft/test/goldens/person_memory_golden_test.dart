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

/// Goldens for personal memory: a chat's memory with the model's suggestions
/// waiting under it, a person's short memory, and the settings screen that
/// says what is sent where.
///
/// The editor frame is the one that matters. A suggestion has to read as a
/// question — a fact with a tick and a cross beside it, under a line saying
/// nothing is added until it is accepted — and not as something already in
/// the note above.
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
    final stores = WeftStores.inMemory()
      ..personMemory = MemoryBook.empty
          .withNote(
            keys,
            '## Ongoing topics\nLisbon trip in May, she books the flat\n\n'
            '## Tone in this chat\nGerman, du, lots of emojis',
          )
          .withNote(
            anna.keys,
            '- Annie, my sister\n- Birthday 3 June\n- Tom; Mia (5), Ben (3)',
          )
          .withProposals(keys, const [
            'Started a new job at Deutsche Bahn in November',
            'Mia’s birthday is on 12 March',
          ])
          .encode();
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

  testWidgets('a chat with suggestions waiting, both themes', (tester) async {
    await expectGolden(
      tester,
      'editor',
      (key) => MemoryEditor.chat(
        key: key,
        chat: chat,
        people: const [anna],
        loadMessages: () async => const [],
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
