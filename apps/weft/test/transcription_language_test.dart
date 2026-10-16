/// The spoken-language setting on the endpoints screen.
///
/// Cohere Transcribe cannot detect the language, and an endpoint serving it
/// reads "no language" as English: German voice notes came back as English
/// text. The fix is a place to say which language is spoken, and these tests
/// pin that it reaches the setting the transcription service sends — and that
/// "detect" removes it again rather than storing an empty code.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/endpoints_screen.dart';
import 'package:weft/services/transcription/transcription_languages.dart';
import 'package:weft_store/weft_store.dart';

import 'support/golden_harness.dart';

void main() {
  final en = lookupAppL10n(const Locale('en'));
  const tall = Size(500, 2400);
  const dropdown = ValueKey('transcription-language');

  /// Opens the screen from a route below it, so Save has somewhere to pop to.
  Future<void> openEndpoints(WidgetTester tester, WeftStores stores) async {
    await pumpWeft(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const EndpointsScreen()),
          ),
          child: const Text('open'),
        ),
      ),
      size: tall,
      stores: stores,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(dropdown));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text(en.commonSave));
    await tester.pumpAndSettle();
  }

  testWidgets('detects by default, and a picked language is saved', (
    tester,
  ) async {
    final stores = WeftStores.inMemory();
    stores.settings.setBool(WeftSettings.transcriptionEnabled, value: true);
    await openEndpoints(tester, stores);

    expect(find.text(en.endpointsTranscriptionLanguageDetect), findsOneWidget);

    await pick(tester, kTranscriptionLanguages['de']!);
    await save(tester);

    expect(stores.settings.getString(WeftSettings.transcriptionLanguage), 'de');
  });

  testWidgets('switching back to detect removes the stored language', (
    tester,
  ) async {
    final stores = WeftStores.inMemory();
    stores.settings.setString(WeftSettings.transcriptionLanguage, 'de');
    await openEndpoints(tester, stores);

    expect(find.text(kTranscriptionLanguages['de']!), findsOneWidget);

    await pick(tester, en.endpointsTranscriptionLanguageDetect);
    await save(tester);

    expect(
      stores.settings.getString(WeftSettings.transcriptionLanguage),
      isNull,
    );
  });

  testWidgets('is offered without a transcription endpoint switched on', (
    tester,
  ) async {
    // An on-device model reads the same setting, with no endpoint at all.
    final stores = WeftStores.inMemory();
    await openEndpoints(tester, stores);

    expect(find.byKey(dropdown), findsOneWidget);
  });

  testWidgets('a stored code the list does not know stays selected', (
    tester,
  ) async {
    final stores = WeftStores.inMemory();
    stores.settings.setString(WeftSettings.transcriptionLanguage, 'sv');
    await openEndpoints(tester, stores);

    expect(find.text('sv'), findsOneWidget);

    await save(tester);
    expect(stores.settings.getString(WeftSettings.transcriptionLanguage), 'sv');
  });
}
