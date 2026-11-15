import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:weft/app/localisation.dart';

/// The checks that make a translation pipeline a pipeline rather than a folder
/// of JSON.
///
/// Everything here is cheap and catches the failure that is otherwise invisible
/// until a reader in Lisbon opens the app: a locale that is declared but does
/// not resolve, a key added to English and forgotten everywhere else, an ARB
/// entry with no description that a translator will guess at.
///
/// The key-parity group reads the ARB files from disk rather than the generated
/// Dart on purpose. The generator silently falls back to the template for a
/// missing key, so a Spanish file with half its keys deleted compiles, runs,
/// and shows English — which is exactly the bug, and is invisible to any test
/// that only ever asks `AppL10n` for a string.
void main() {
  /// The ARB directory, found relative to the test's working directory, which
  /// `flutter test` sets to the package root.
  final arbDir = Directory('lib/l10n');

  /// The message keys in an ARB file: not the `@@locale`-style file metadata,
  /// and not the `@key` description blocks.
  Set<String> messageKeysOf(File file) {
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return decoded.keys.where((k) => !k.startsWith('@')).toSet();
  }

  List<File> translatedArbFiles() =>
      arbDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.arb'))
          .where((f) => !f.path.endsWith('app_en.arb'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  group('supported locales', () {
    test('every declared locale resolves to itself, not to the fallback', () {
      // `basicLocaleListResolution` is what `MaterialApp` runs against the
      // device's preferred-locale list. A locale that is declared but falls off
      // the list resolves to English, which is a translation nobody sees.
      for (final locale in weftSupportedLocales) {
        final resolved = basicLocaleListResolution([
          locale,
        ], weftSupportedLocales);
        expect(
          resolved,
          locale,
          reason: '$locale is declared but resolves to $resolved',
        );
      }
    });

    test('English is first, and is what an undeclared locale gets', () {
      expect(weftSupportedLocales.first, const Locale('en'));
      expect(
        basicLocaleListResolution([const Locale('ja')], weftSupportedLocales),
        const Locale('en'),
      );
    });

    test('the app delegate accepts every declared locale', () {
      // Including the two with a script or country subtag, and — the reason
      // this test exists — including `ar` and `he`, which have no ARB file. A
      // locale the delegate refuses is a locale with no `AppL10n` in
      // `Localizations` at all, so `context.l10n` throws a null check on the
      // first widget that draws rather than falling back to English.
      final delegate = weftLocalizationsDelegates.firstWhere(
        (d) => d.type == AppL10n,
      );
      for (final locale in weftSupportedLocales) {
        expect(
          delegate.isSupported(locale),
          isTrue,
          reason: 'the AppL10n delegate does not support $locale',
        );
      }
    });
  });

  group('ARB files', () {
    test('every translated file has exactly the template key set', () {
      final template = messageKeysOf(File('${arbDir.path}/app_en.arb'));
      expect(template, isNotEmpty);

      final files = translatedArbFiles();
      expect(files, isNotEmpty, reason: 'no translated ARB files found');

      for (final file in files) {
        final keys = messageKeysOf(file);
        final missing = template.difference(keys).toList()..sort();
        final extra = keys.difference(template).toList()..sort();
        expect(
          [missing, extra],
          [<String>[], <String>[]],
          reason:
              '${file.uri.pathSegments.last} differs from app_en.arb\n'
              '  missing: ${missing.isEmpty ? '(none)' : missing.join(', ')}\n'
              '  extra:   ${extra.isEmpty ? '(none)' : extra.join(', ')}',
        );
      }
    });

    test('every template key has a description a translator can use', () {
      final decoded =
          jsonDecode(File('${arbDir.path}/app_en.arb').readAsStringSync())
              as Map<String, dynamic>;
      final undescribed = <String>[];
      for (final key in decoded.keys.where((k) => !k.startsWith('@'))) {
        final meta = decoded['@$key'];
        final description = meta is Map ? meta['description'] : null;
        // A one-word description is the same as none: it repeats the key back.
        if (description is! String || description.trim().length < 12) {
          undescribed.add(key);
        }
      }
      expect(
        undescribed,
        isEmpty,
        reason:
            'these keys have no usable @key description in app_en.arb: '
            '${undescribed.join(', ')}',
      );
    });

    test('every translated file declares its locale and its review state', () {
      for (final file in translatedArbFiles()) {
        final decoded =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final name = file.uri.pathSegments.last;
        expect(
          decoded['@@locale'],
          isA<String>(),
          reason: '$name has no @@locale',
        );
        // Not asserted as still-pending: a reviewed file has the marker
        // deleted, and this test must keep passing after that happens. What is
        // asserted is that if it is there it says what it is supposed to say,
        // so it stays greppable.
        final review = decoded['@@x-review'];
        if (review != null) {
          expect(
            review,
            startsWith('TRANSLATOR REVIEW PENDING'),
            reason: '$name has an @@x-review that is not the agreed marker',
          );
        }
      }
    });

    test('no translated file ships @key description blocks', () {
      // Descriptions belong to the template alone. A copy in a translated file
      // is a copy that goes stale, and gen-l10n ignores it either way.
      for (final file in translatedArbFiles()) {
        final decoded =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final descriptions = decoded.keys
            .where((k) => k.startsWith('@') && !k.startsWith('@@'))
            .toList();
        expect(
          descriptions,
          isEmpty,
          reason:
              '${file.uri.pathSegments.last} carries description blocks: '
              '${descriptions.join(', ')}',
        );
      }
    });
  });

  group('the catalogue and the code agree', () {
    /// Every `.dart` under `lib/`, minus the generated localisations — which
    /// mention every key by definition and would make the orphan check below
    /// vacuous.
    List<File> appSources() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.contains('/l10n/gen/'))
        .toList();

    test('no ARB key is defined and never used', () {
      final keys = messageKeysOf(File('${arbDir.path}/app_en.arb'));
      final source = appSources().map((f) => f.readAsStringSync()).join('\n');

      // A plain substring search, not a parse: a key is reached as
      // `l10n.settingsTitle` or as `.settingsTitle`, and both contain the name.
      // The false *negative* this risks — a key whose name is a substring of
      // another — is the safe direction: it under-reports orphans rather than
      // failing a build over a key that is used.
      final orphans = keys.where((key) => !source.contains(key)).toList()
        ..sort();

      expect(
        orphans,
        isEmpty,
        reason:
            'these keys are in app_en.arb and reached from nowhere in lib/. '
            'Delete them, or use them: ${orphans.join(', ')}',
      );
    });

    // The other direction — a `context.l10n.typo` that does not exist — needs
    // no test: the generated class has no such getter, so it is a compile
    // error, and `flutter analyze` in CI is what catches it. Asserting it here
    // would mean parsing Dart to prove something the compiler already proves.
  });

  group('Android resources', () {
    /// The `<string>` and `<plurals>` names in one `strings.xml`.
    ///
    /// A regex rather than an XML parser, deliberately: the files are ours,
    /// the shape is one attribute, and a dependency on `xml` for four lines in
    /// a test is a dependency the app then carries.
    Set<String> androidKeys(File file) {
      final source = file.readAsStringSync();
      return RegExp(
        r'<(?:string|plurals)\s+name="([^"]+)"',
      ).allMatches(source).map((m) => m.group(1)!).toSet();
    }

    /// Every `values-*/strings.xml` beside a base `values/strings.xml`.
    List<(Directory base, List<File> translations)> catalogues() {
      final roots = [
        Directory('android/app/src/main/res'),
        Directory('android/wear/src/main/res'),
      ].where((d) => d.existsSync());

      return [
        for (final root in roots)
          (
            root,
            root
                .listSync()
                .whereType<Directory>()
                .where((d) => d.path.split('/').last.startsWith('values-'))
                .map((d) => File('${d.path}/strings.xml'))
                .where((f) => f.existsSync())
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path)),
          ),
      ];
    }

    test('every values-* file has exactly the base key set', () {
      // The failure this pins is silent in a way the ARB one is not: Android
      // falls back per *string*, so a `values-de` missing four keys is a German
      // screen with four English sentences on it and no error anywhere.
      for (final (root, translations) in catalogues()) {
        final base = File('${root.path}/values/strings.xml');
        expect(base.existsSync(), isTrue, reason: 'no ${base.path}');
        final expected = androidKeys(base);
        expect(expected, isNotEmpty, reason: '${base.path} defines no strings');

        expect(
          translations,
          isNotEmpty,
          reason: 'no values-*/strings.xml under ${root.path}',
        );

        for (final file in translations) {
          final keys = androidKeys(file);
          final missing = expected.difference(keys).toList()..sort();
          final extra = keys.difference(expected).toList()..sort();
          expect(
            [missing, extra],
            [<String>[], <String>[]],
            reason:
                '${file.path} differs from ${base.path}\n'
                '  missing: ${missing.isEmpty ? '(none)' : missing.join(', ')}\n'
                '  extra:   ${extra.isEmpty ? '(none)' : extra.join(', ')}',
          );
        }
      }
    });

    test('every locale Sennit declares has an Android catalogue', () {
      // Android spells a region `-r`: `pt-BR` is `values-pt-rBR`. Getting that
      // wrong produces a directory Android silently never reads.
      const androidFor = {
        'es': 'es',
        'de': 'de',
        'fr': 'fr',
        'pt': 'pt-rBR',
        'zh': 'zh-rCN',
      };

      for (final (root, translations) in catalogues()) {
        final present = translations
            .map(
              (f) => f.parent.path.split('/').last.substring('values-'.length),
            )
            .toSet();
        for (final locale in weftSupportedLocales) {
          final code = androidFor[locale.languageCode];
          // `ar` and `he` are declared for layout and have no translations —
          // on Android as in the ARB catalogue.
          if (code == null) continue;
          expect(
            present,
            contains(code),
            reason: 'no values-$code under ${root.path} for $locale',
          );
        }
      }
    });
  });

  group('Apple usage descriptions', () {
    /// The keys an `InfoPlist.strings` overrides.
    Set<String> plistStringsKeys(File file) => RegExp(
      r'^"([^"]+)"\s*=',
      multiLine: true,
    ).allMatches(file.readAsStringSync()).map((m) => m.group(1)!).toSet();

    /// The `NS…UsageDescription` keys an `Info.plist` declares.
    Set<String> usageDescriptionKeys(File file) => RegExp(
      r'<key>(NS[A-Za-z]*UsageDescription)</key>',
    ).allMatches(file.readAsStringSync()).map((m) => m.group(1)!).toSet();

    for (final platform in ['ios', 'macos']) {
      test('$platform InfoPlist.strings match Info.plist', () {
        final runner = Directory('$platform/Runner');
        if (!runner.existsSync()) return;
        final expected = usageDescriptionKeys(
          File('${runner.path}/Info.plist'),
        );
        expect(
          expected,
          isNotEmpty,
          reason: '$platform/Runner/Info.plist declares no usage descriptions',
        );

        final files =
            runner
                .listSync()
                .whereType<Directory>()
                .where((d) => d.path.endsWith('.lproj'))
                .map((d) => File('${d.path}/InfoPlist.strings'))
                .where((f) => f.existsSync())
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));

        expect(files, isNotEmpty, reason: 'no $platform InfoPlist.strings');

        for (final file in files) {
          final keys = plistStringsKeys(file);
          final missing = expected.difference(keys).toList()..sort();
          final extra = keys.difference(expected).toList()..sort();
          expect(
            [missing, extra],
            [<String>[], <String>[]],
            reason:
                '${file.path} differs from Info.plist\n'
                '  missing: ${missing.isEmpty ? '(none)' : missing.join(', ')}\n'
                '  extra:   ${extra.isEmpty ? '(none)' : extra.join(', ')}',
          );
        }
      });
    }
  });

  group('AppL10n resolution', () {
    /// The string [read] returns from a subtree localized to [locale], through
    /// the delegates `main.dart` actually installs.
    Future<String> stringIn(
      WidgetTester tester,
      Locale locale,
      String Function(AppL10n l10n) read,
    ) async {
      late String value;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          home: Builder(
            builder: (context) {
              value = read(context.l10n);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pump();
      return value;
    }

    testWidgets('Spanish under es, English under an undeclared locale', (
      tester,
    ) async {
      expect(
        await stringIn(tester, const Locale('es'), (l) => l.settingsTitle),
        'Ajustes',
      );
      expect(
        await stringIn(tester, const Locale('ja'), (l) => l.settingsTitle),
        'Settings',
      );
    });

    testWidgets('the RTL locales fall back to English, not to keys', (
      tester,
    ) async {
      // The half-state `ar` and `he` are declared for: right-to-left layout,
      // English words. If this ever returns a key, the fallback is broken.
      for (final locale in [const Locale('ar'), const Locale('he')]) {
        expect(
          await stringIn(tester, locale, (l) => l.settingsTitle),
          'Settings',
          reason: '$locale should fall back to English',
        );
      }
    });

    testWidgets('script and country subtags resolve to their base file', (
      tester,
    ) async {
      expect(
        await stringIn(
          tester,
          const Locale('pt', 'BR'),
          (l) => l.settingsTitle,
        ),
        'Configurações',
      );
      expect(
        await stringIn(
          tester,
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
          (l) => l.settingsTitle,
        ),
        '设置',
      );
    });

    testWidgets('placeholders and plurals survive translation', (tester) async {
      expect(
        await stringIn(
          tester,
          const Locale('de'),
          (l) => l.settingsShowNetworkInAll('WhatsApp'),
        ),
        contains('WhatsApp'),
      );
      expect(
        await stringIn(
          tester,
          const Locale('de'),
          (l) => l.settingsUnhideStatusSenders(1),
        ),
        '1 einblenden',
      );
      expect(
        await stringIn(
          tester,
          const Locale('de'),
          (l) => l.settingsUnhideStatusSenders(4),
        ),
        '4 einblenden',
      );
    });
  });
}
