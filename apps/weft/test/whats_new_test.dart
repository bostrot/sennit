import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/whats_new/whats_new.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart' show WeftSettings;

/// The "What's new" sheet after an update.
///
/// What has to hold: it appears on the first start of a newer version, never
/// on a fresh install, never twice, and never with notes that are not this
/// version's — the committed asset is empty, and a fork or a `flutter run`
/// build must stay quiet.
void main() {
  const notes = ReleaseNotes(
    version: '1.0.12',
    notes: '• What is a Matrix server? explained on sign-in\n• This sheet',
  );

  late WeftStores stores;
  setUp(() => stores = WeftStores.inMemory());
  tearDown(() => stores.dispose());

  Future<void> pump(
    WidgetTester tester, {
    ReleaseNotes? bundled = notes,
    String version = '1.0.12',
    WeftSurface surface = WeftSurface.touch,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storesProvider.overrideWithValue(stores),
          appVersionProvider.overrideWithValue(version),
          releaseNotesProvider.overrideWith((_) async => bundled),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(surface: surface),
          home: const WhatsNewGate(child: Scaffold(body: Text('inbox'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder sheet() => find.byType(WhatsNewSheet);

  testWidgets('shows the notes once after an update', (tester) async {
    stores.settings.setString(WeftSettings.whatsNewLastVersion, '1.0.11');
    recordLaunchVersion(stores.settings, '1.0.12');
    await pump(tester);

    expect(sheet(), findsOneWidget);
    expect(find.text('What\'s new in Sennit 1.0.12'), findsOneWidget);
    expect(find.textContaining('What is a Matrix server?'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(sheet(), findsNothing);
    expect(find.text('inbox'), findsOneWidget);

    // The next start of the same version owes nothing.
    recordLaunchVersion(stores.settings, '1.0.12');
    await tester.pumpWidget(const SizedBox());
    await pump(tester);
    expect(sheet(), findsNothing);
  });

  testWidgets('a fresh install records its version and shows nothing', (
    tester,
  ) async {
    recordLaunchVersion(stores.settings, '1.0.12');
    // Setup finishes before the inbox appears; that must not read as an
    // install from before the version was recorded.
    stores.settings.setBool(WeftSettings.onboardingDone, value: true);
    await pump(tester);

    expect(sheet(), findsNothing);
    expect(
      stores.settings.getString(WeftSettings.whatsNewLastVersion),
      '1.0.12',
    );
  });

  testWidgets('an install from before the version was recorded is an update', (
    tester,
  ) async {
    stores.settings.setBool(WeftSettings.onboardingDone, value: true);
    recordLaunchVersion(stores.settings, '1.0.12');
    await pump(tester);

    expect(sheet(), findsOneWidget);
  });

  testWidgets('a build without notes shows nothing, and does not owe them', (
    tester,
  ) async {
    stores.settings.setString(WeftSettings.whatsNewLastVersion, '1.0.11');
    recordLaunchVersion(stores.settings, '1.0.12');
    await pump(tester, bundled: null);

    expect(sheet(), findsNothing);
    expect(
      stores.settings.getString(WeftSettings.whatsNewPendingVersion),
      isNull,
    );
  });

  testWidgets("another version's notes are not shown", (tester) async {
    stores.settings.setString(WeftSettings.whatsNewLastVersion, '1.0.12');
    recordLaunchVersion(stores.settings, '1.0.13');
    await pump(tester, version: '1.0.13');

    expect(sheet(), findsNothing);
  });

  testWidgets('a downgrade is not an update', (tester) async {
    stores.settings.setString(WeftSettings.whatsNewLastVersion, '1.0.13');
    recordLaunchVersion(stores.settings, '1.0.12');
    await pump(tester);

    expect(sheet(), findsNothing);
  });

  testWidgets('fits a phone and a desktop window', (tester) async {
    addTearDown(tester.view.reset);
    for (final (size, surface) in const [
      (Size(360, 640), WeftSurface.touch),
      (Size(1400, 900), WeftSurface.touch),
      (Size(1400, 900), WeftSurface.mac),
    ]) {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = size;
      stores.settings.setString(WeftSettings.whatsNewLastVersion, '1.0.11');
      recordLaunchVersion(stores.settings, '1.0.12');
      await tester.pumpWidget(const SizedBox());
      await pump(tester, surface: surface);

      expect(sheet(), findsOneWidget, reason: '$size $surface');
      expect(tester.takeException(), isNull, reason: '$size $surface');
      expect(find.text('Got it'), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
    }
  });

  group('the notes asset', () {
    test('the committed copy is empty, so it shows nothing', () {
      final raw = File('assets/release_notes.json').readAsStringSync();
      expect(ReleaseNotes.parse(raw), isNull);
    });

    test('malformed or blank notes read as none', () {
      expect(ReleaseNotes.parse(''), isNull);
      expect(ReleaseNotes.parse('[]'), isNull);
      expect(ReleaseNotes.parse('{"version": "1.0.12", "notes": " "}'), isNull);
      expect(
        ReleaseNotes.parse('{"version": "1.0.12", "notes": "• a"}')?.notes,
        '• a',
      );
    });
  });

  test('versions compare by number, not by text', () {
    expect(compareVersions('1.0.9', '1.0.12'), -1);
    expect(compareVersions('1.0.12', '1.0.12'), 0);
    expect(compareVersions('1.1.0', '1.0.99'), 1);
    expect(compareVersions('1.0', '1.0.0'), 0);
  });
}
