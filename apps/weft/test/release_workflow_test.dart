import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards on the Play upload step in `.github/workflows/release.yml`.
///
/// Nothing here runs in the app; it exists because the upload is wired by
/// string, in a file no test would otherwise open, and every way it can break
/// breaks *silently at release time* — the tag builds, the GitHub release goes
/// out with all six artifacts, and only the store is quietly missing a build.
/// The three things that can drift are all cheap to check from here:
///
///  * the AAB filename, which "Collect artifacts" writes and the upload step
///    names again by hand,
///  * the package id, which lives for real in `build.gradle.kts`,
///  * the `if:` gates, which are the only thing keeping a dry run and an
///    unsigned build away from the store.
File _repoFile(String relative) {
  // `flutter test` runs from `apps/weft`; the workspace root and an IDE run it
  // from the repository root.
  for (final prefix in const ['', '../../']) {
    final file = File('$prefix$relative');
    if (file.existsSync()) return file;
  }
  throw StateError(
    '$relative not found — run from apps/weft or from the workspace root',
  );
}

/// `${{ needs.verify.outputs.version }}` in an action input and `$VERSION` in
/// a `run:` script are the same value by way of the job's `env:`. Compare the
/// two paths with both spellings flattened to one.
String _normaliseVersion(String value) => value
    .replaceAll(r'${{ needs.verify.outputs.version }}', '<version>')
    .replaceAll(r'$VERSION', '<version>');

/// The step block beginning with `- name: <name>`, up to the next step at the
/// same indentation.
String _step(String workflow, String name) {
  final start = workflow.indexOf('      - name: $name\n');
  if (start == -1) throw StateError('no step named "$name" in release.yml');
  final next = workflow.indexOf(
    RegExp(r'^      - ', multiLine: true),
    start + 1,
  );
  return workflow.substring(start, next == -1 ? workflow.length : next);
}

/// The value of a `key: value` line inside a step block, unquoted.
String _input(String step, String key) {
  final match = RegExp('^\\s*$key: (.*)\$', multiLine: true).firstMatch(step);
  if (match == null) throw StateError('the step has no "$key:" input');
  return match.group(1)!.trim().replaceAll('"', '').replaceAll("'", '');
}

void main() {
  // Read inside the tests, not while the file is loading: `expect` outside a
  // test body is an error, and a parse failure should read as a failing test.
  late String workflow;
  late String upload;
  setUp(() {
    workflow = _repoFile('.github/workflows/release.yml').readAsStringSync();
    upload = _step(workflow, 'Publish to the Play internal track');
  });

  test('the upload names the AAB that "Collect artifacts" actually writes', () {
    final collect = _step(workflow, 'Collect artifacts');
    final written = RegExp(r'"(dist/[^"]+\.aab)"').firstMatch(collect);
    expect(written, isNotNull, reason: 'no .aab copied into dist/');

    expect(
      _normaliseVersion(_input(upload, 'releaseFiles')),
      _normaliseVersion(written!.group(1)!),
    );
  });

  test('the upload targets the package id the app is actually built with', () {
    final gradle = _repoFile(
      'apps/weft/android/app/build.gradle.kts',
    ).readAsStringSync();
    final applicationId = RegExp(
      r'applicationId = "([^"]+)"',
    ).firstMatch(gradle);
    expect(
      applicationId,
      isNotNull,
      reason: 'no applicationId in the Gradle file',
    );

    expect(_input(upload, 'packageName'), applicationId!.group(1));
  });

  test('the release goes out to internal testers, not into a draft', () {
    expect(_input(upload, 'track'), 'internal');
    // A repository variable can force `draft` for the very first upload of an
    // app Play has never published; the default, and the point of the step,
    // is a release testers can install without a Console visit.
    expect(_input(upload, 'status'), contains('completed'));
  });

  test('a dry run and an unsigned build never reach the store', () {
    // workflow_dispatch is documented as a dry run, and an AAB built without
    // the keystore is debug-signed. Either one reaching Play is the failure
    // this gate exists for.
    expect(upload, contains("startsWith(github.ref, 'refs/tags/')"));
    expect(upload, contains("env.HAS_SIGNING == 'true'"));
    expect(upload, contains("env.HAS_PLAY == 'true'"));
  });

  test(
    'a fork without the service account skips the step instead of failing',
    () {
      // The `if:` above can only be evaluated when HAS_PLAY exists; a job-level
      // env entry is what makes the secret readable from a step condition at
      // all, and dropping it would make the condition silently always-false.
      expect(
        workflow,
        contains(
          "HAS_PLAY: \${{ secrets.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON != '' }}",
        ),
      );
    },
  );
}
