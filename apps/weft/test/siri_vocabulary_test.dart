import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Siri example phrases for every intent Sennit declares, in every language
/// the iOS bundle ships.
///
/// App Store Connect checks `INIntentsSupported` against an
/// `AppIntentVocabulary.plist` in each `.lproj` the app has, and reports
/// ITMS-90626 once per language and intent that lacks example phrases. It
/// does that after the upload, by email, so this test is the only place a
/// new language or intent can be caught before a release.
void main() {
  final runner = Directory('ios/Runner');

  Set<String> declaredIntents() {
    final plist = File('${runner.path}/Info.plist').readAsStringSync();
    final block = RegExp(
      r'<key>INIntentsSupported</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist);
    if (block == null) return const {};
    return RegExp(
      r'<string>([^<]+)</string>',
    ).allMatches(block.group(1)!).map((m) => m.group(1)!).toSet();
  }

  List<Directory> localizations() =>
      runner
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.lproj'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('Sennit declares the three messaging intents', () {
    expect(declaredIntents(), {
      'INSendMessageIntent',
      'INSearchForMessagesIntent',
      'INSetMessageAttributeIntent',
    });
  });

  test('every localization has example phrases for every intent', () {
    final intents = declaredIntents();
    final lprojs = localizations();
    expect(
      lprojs.map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last),
      containsAll([
        'Base.lproj',
        'en.lproj',
        'de.lproj',
        'es.lproj',
        'fr.lproj',
        'pt-BR.lproj',
        'zh-Hans.lproj',
      ]),
    );

    for (final lproj in lprojs) {
      final file = File('${lproj.path}/AppIntentVocabulary.plist');
      expect(file.existsSync(), isTrue, reason: '${file.path} is missing');
      final text = file.readAsStringSync();
      expect(text, contains('<key>IntentPhrases</key>'), reason: file.path);

      final entries = RegExp(
        r'<key>IntentName</key>\s*<string>([^<]+)</string>\s*'
        r'<key>IntentExamples</key>\s*<array>(.*?)</array>',
        dotAll: true,
      ).allMatches(text);
      final examples = {
        for (final m in entries)
          m.group(1)!: RegExp(
            r'<string>([^<]+)</string>',
          ).allMatches(m.group(2)!).map((e) => e.group(1)!).toList(),
      };

      expect(examples.keys.toSet(), intents, reason: file.path);
      for (final MapEntry(key: intent, value: phrases) in examples.entries) {
        expect(phrases, isNotEmpty, reason: '$intent in ${file.path}');
        // Siri matches an example to the app by its name.
        expect(
          phrases.any((p) => p.contains('Sennit')),
          isTrue,
          reason: '$intent in ${file.path} never names Sennit',
        );
      }
    }
  });

  test('the vocabulary is a Runner resource in every language', () {
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(project, contains('/* AppIntentVocabulary.plist in Resources */,'));
    for (final lproj in localizations()) {
      final name = lproj.uri.pathSegments.where((s) => s.isNotEmpty).last;
      expect(
        project,
        contains('path = "$name/AppIntentVocabulary.plist"'),
        reason: '$name is not in the variant group',
      );
    }
  });
}
