import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards on `.github/workflows/deploy_internal.yml`, the Play upload.
///
/// Nothing here runs in the app; it exists because the upload is wired by
/// string, in a file no test would otherwise open, and every way it can break
/// breaks *silently* — a green run, or no run at all, and the internal track
/// simply never gets a build. That is how the upload sat for its first two
/// months: a step of release.yml behind a job on a runner that was offline.
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

/// The step block beginning with `- name: <name>`, up to the next step at the
/// same indentation.
String _step(String workflow, String name) {
  final start = workflow.indexOf('      - name: $name\n');
  if (start == -1) throw StateError('no step named "$name" in the workflow');
  final next = workflow.indexOf(
    RegExp(r'^      - ', multiLine: true),
    start + 1,
  );
  return workflow.substring(start, next == -1 ? workflow.length : next);
}

/// The value of a `key: value` line inside a block, unquoted.
String _input(String block, String key) {
  final match = RegExp('^\\s*$key: (.*)\$', multiLine: true).firstMatch(block);
  if (match == null) throw StateError('the block has no "$key:" line');
  return match.group(1)!.trim().replaceAll('"', '').replaceAll("'", '');
}

void main() {
  // Read inside the tests, not while the file is loading: `expect` outside a
  // test body is an error, and a parse failure should read as a failing test.
  late String workflow;
  late String release;
  late String upload;
  setUp(() {
    workflow = _repoFile(
      '.github/workflows/deploy_internal.yml',
    ).readAsStringSync();
    release = _repoFile('.github/workflows/release.yml').readAsStringSync();
    upload = _step(workflow, 'Upload to Play Store');
  });

  test('the upload names the AAB the build step actually writes', () {
    final build = _step(workflow, 'Build App Bundle');
    expect(_input(build, 'run'), startsWith('flutter build appbundle'));
    expect(_input(build, 'working-directory'), 'apps/weft');
    expect(
      _input(upload, 'releaseFiles'),
      'apps/weft/build/app/outputs/bundle/release/app-release.aab',
    );
  });

  test('every run gets a version code above every earlier one', () {
    // Play refuses a versionCode at or below one the app has already had.
    // The pubspec build number does not move on a manual run, and the run
    // number starts far below the timestamp codes already on Play.
    expect(
      _input(_step(workflow, 'Build App Bundle'), 'run'),
      contains(r'--build-number=$(date +%s)'),
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
    // app Play has never published; what must not come back is a hardcoded
    // one.
    expect(_input(upload, 'status'), contains('completed'));
    expect(_input(upload, 'status'), isNot('draft'));
  });

  test('a version bump on main triggers it, and only for the app pubspec', () {
    expect(workflow, contains("      - 'apps/weft/pubspec.yaml'"));
    expect(
      workflow,
      contains(
        r'changes=$(git diff "${{ github.event.before }}" HEAD -- apps/weft/pubspec.yaml)',
      ),
    );
    expect(workflow, contains(r'grep -q "^\+version:" <<<"$changes"'));
    // The skip branch must survive the manual branch in front of it, or every
    // push touching pubspec.yaml — a dependency bump — ships a build.
    expect(workflow, contains('changed=false'));
  });

  test('a git that cannot run fails the check instead of skipping', () {
    // On a runner without the command line tools `git` exits non-zero; piped
    // into grep, or tested inside an `if`, that read as "no bump" and the run
    // went green without building. As a plain assignment, `bash -e` stops.
    final check = _step(workflow, 'Check for version change');
    expect(check, contains('\n          changes=\$(git diff'));
    expect(check, isNot(contains('| grep')));
    expect(check, isNot(contains('elif')));
  });

  test('a manual run builds without a version bump', () {
    expect(workflow, contains('workflow_dispatch:'));
    expect(
      workflow,
      contains(r'if [ "${{ github.event_name }}" = "workflow_dispatch" ]'),
    );
  });

  test('missing secrets fail the run instead of skipping the upload', () {
    final check = _step(
      workflow,
      'The signing key and the Play service account must exist',
    );
    for (final secret in const [
      'ANDROID_KEYSTORE_BASE64',
      'ANDROID_KEYSTORE_PASSWORD',
      'ANDROID_KEY_ALIAS',
      'ANDROID_KEY_PASSWORD',
      'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON',
    ]) {
      expect(check, contains('secrets.$secret'), reason: secret);
    }
    expect(check, contains('exit 1'));
    // A gate on the upload itself would bring the silent skip back.
    expect(upload, isNot(contains('HAS_PLAY')));
    expect(upload, isNot(contains('HAS_SIGNING')));
  });

  test('it runs only on the Mac runner, which can build Android', () {
    expect(
      RegExp(
        r'^    runs-on: (.*)$',
        multiLine: true,
      ).allMatches(workflow).map((m) => m.group(1)).toSet(),
      {'[self-hosted, macOS, ARM64]'},
    );
  });

  test("rustup's Rust is put ahead of Homebrew's", () {
    // Homebrew's rustc carries the host std only; when it wins on PATH,
    // flutter_vodozemac's cargokit build fails for every Android target.
    expect(workflow, contains(r'echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"'));
    expect(release, contains(r'echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"'));
  });

  test('the keystore does not outlive the job on the self-hosted runner', () {
    final cleanup = _step(workflow, 'Remove the keystore from the runner');
    expect(_input(cleanup, 'if'), 'always()');
    expect(cleanup, contains('upload-keystore.jks'));
    expect(cleanup, contains('key.properties'));
  });

  test('the deploy builds with the same Flutter and JDK as the release', () {
    String pin(String yaml, String pattern) {
      final match = RegExp(pattern).firstMatch(yaml);
      expect(match, isNotNull, reason: 'no $pattern');
      return match!.group(1)!;
    }

    const flutter = r"FLUTTER_VERSION: '([^']+)'";
    const java = r"java-version: '([^']+)'";
    expect(pin(workflow, flutter), pin(release, flutter));
    expect(pin(workflow, java), pin(release, java));
  });

  test('release.yml no longer uploads to Play itself', () {
    // Two workflows uploading would hand Play two versionCode schemes — the
    // pubspec build number and the run number — and the lower one is refused.
    expect(release, isNot(contains('upload-google-play')));
  });

  test(
    'no release job waits on the offline Linux runner it cannot do without',
    () {
      // Everything needs `verify`, so it pinned the Android build to a runner
      // that never came up. Only the Linux desktop build has to stay on Linux.
      final jobs = RegExp(
        r'^  ([a-z]+):\n(?:    .*\n|\n)*?    runs-on: (.*)$',
        multiLine: true,
      ).allMatches(release);
      final onLinux = {
        for (final m in jobs)
          if (m.group(2)!.contains('Linux')) m.group(1),
      };
      expect(onLinux, {'linux'});
    },
  );
}
