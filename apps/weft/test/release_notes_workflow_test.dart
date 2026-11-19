import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards on how the release notes reach the GitHub release, both stores and
/// the app's "What's new" sheet.
///
/// One script, `tooling/scripts/release_notes.py`, run by each workflow on
/// its own commit — so the four cannot drift, and none waits for another. All
/// of it is wired by string in YAML; a dropped step is a release with no notes
/// and a green run.
File _repoFile(String relative) {
  for (final prefix in const ['', '../../']) {
    final file = File('$prefix$relative');
    if (file.existsSync()) return file;
  }
  throw StateError(
    '$relative not found — run from apps/weft or from the workspace root',
  );
}

void main() {
  late String release;
  late String play;
  late String testflight;
  setUpAll(() {
    String read(String name) =>
        _repoFile('.github/workflows/$name').readAsStringSync();
    release = read('release.yml');
    play = read('deploy_internal.yml');
    testflight = read('deploy_testflight.yml');
  });

  test('the app bundles the notes asset', () {
    final pubspec = _repoFile('apps/weft/pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('    - assets/release_notes.json\n'));
  });

  test('every store build writes the asset before it builds', () {
    for (final (name, workflow, build) in [
      ('deploy_internal', play, 'flutter build appbundle'),
      ('deploy_testflight', testflight, 'flutter build ios'),
    ]) {
      final notes = workflow.indexOf('tooling/scripts/release_notes.py');
      expect(notes, isNot(-1), reason: name);
      expect(
        workflow.indexOf('--app-asset apps/weft/assets/release_notes.json'),
        greaterThan(notes),
        reason: name,
      );
      expect(workflow.indexOf(build), greaterThan(notes), reason: name);
    }
  });

  test('every release build bundles the notes before it builds', () {
    // One download per platform job, each ahead of its `flutter pub get`.
    final downloads = RegExp(
      r'- name: Bundle the release notes\n'
      r'        uses: actions/download-artifact@v4\n'
      r'        with:\n'
      r'          name: release-notes\n'
      r'          path: apps/weft/assets\n'
      r'      - run: flutter pub get\n',
    ).allMatches(release);
    expect(downloads, hasLength(5));
    expect(
      release,
      contains('--github notes/github.md --app-asset notes/release_notes.json'),
    );
  });

  test('the GitHub release body is the script, not GitHub generating', () {
    expect(release, isNot(contains('generate_release_notes')));
    expect(
      release,
      contains(r'body_path: ${{ runner.temp }}/release-notes.md'),
    );
    // Neither notes file is attached to the release as a download.
    expect(release, contains('rm dist/release_notes.json'));
    expect(release, contains('mv dist/github.md'));
    // The fallback reads history, and a shallow clone has none.
    final verify = release.substring(
      release.indexOf('  verify:'),
      release.indexOf('  android:'),
    );
    expect(verify, contains('fetch-depth: 0'));
  });

  test("Play gets the notes as What's new", () {
    expect(play, contains(r'--play-dir "$RUNNER_TEMP/whatsnew"'));
    expect(play, contains(r'whatsNewDirectory: ${{ runner.temp }}/whatsnew'));
  });

  test('App Store Connect gets the notes after the upload', () {
    final upload = testflight.indexOf('- name: Upload to TestFlight');
    final notes = testflight.indexOf(
      '- name: Set "What to Test" and "What\'s New"',
    );
    expect(notes, greaterThan(upload));
    expect(testflight, contains(r'--store "$RUNNER_TEMP/store_notes.txt"'));
    expect(testflight, contains('tooling/store/build_notes.py'));
    // A dry run uploads nothing, so there is no build to annotate.
    expect(testflight.substring(notes), contains('!inputs.dry_run'));
  });
}
