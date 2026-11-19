import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards on `.github/workflows/deploy_testflight.yml`, the TestFlight upload.
///
/// The same reasoning as `play_deploy_workflow_test.dart`: it is wired by
/// string in a file nothing else opens, and the ways it breaks are quiet.
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
  late String workflow;
  late String play;

  setUpAll(() {
    workflow = _repoFile(
      '.github/workflows/deploy_testflight.yml',
    ).readAsStringSync();
    play = _repoFile(
      '.github/workflows/deploy_internal.yml',
    ).readAsStringSync();
  });

  test('both stores number a commit the same way', () {
    const scheme = r'--build-number="$(git rev-list --count HEAD)"';
    expect(workflow, contains(scheme));
    expect(play, contains(scheme));
    // A shallow clone counts one commit, every time.
    expect(workflow, contains('fetch-depth: 0'));
  });

  test('a missing secret fails the run instead of skipping the upload', () {
    for (final secret in const [
      'APP_STORE_CONNECT_KEY_ID',
      'APP_STORE_CONNECT_ISSUER_ID',
      'APP_STORE_CONNECT_KEY_P8_BASE64',
      'APPLE_TEAM_ID',
    ]) {
      expect(workflow, contains('secrets.$secret'), reason: secret);
    }
    expect(workflow, contains('exit 1'));
  });

  test('the build stays internal unless a manual run asks otherwise', () {
    expect(
      workflow,
      contains(
        '<key>testFlightInternalTestingOnly</key>'
        "<\${{ inputs.app_store && 'false' || 'true' }}/>",
      ),
    );
    expect(workflow, contains('default: false'));
    // A dry run exports to the runner; anything else is an upload.
    expect(
      workflow,
      contains(
        '<key>destination</key>'
        "<string>\${{ inputs.dry_run && 'export' || 'upload' }}</string>",
      ),
    );
  });

  test('it runs on a hosted Mac', () {
    expect(workflow, contains('    runs-on: macos-26\n'));
    expect(workflow, isNot(contains('TESTFLIGHT_RUNS_ON')));
  });

  test('it archives with Xcode 26, or not at all', () {
    // App Store Connect refuses an upload built with an SDK older than iOS
    // 26, and does so only after the whole archive: build 342 was the proof.
    final select = workflow.indexOf('      - name: Select Xcode 26');
    expect(select, isNot(-1));
    expect(select, lessThan(workflow.indexOf('      - name: Archive')));
    expect(workflow, contains("-name 'Xcode_26*.app'"));
    expect(workflow, contains('sudo xcode-select -s'));
    expect(workflow, contains(r'if [ "${sdk%%.*}" -lt 26 ]; then'));
  });

  test('an upload that went through is not failed by a missing IPA', () {
    // With `destination: upload` Xcode 26 writes no export directory; an
    // unconditional `ls` of it failed 1.0.13 after the upload and skipped
    // the notes. Only a dry run leaves something there to list.
    expect(
      workflow,
      isNot(contains('\n          ls -l "\$RUNNER_TEMP/export"\n')),
    );
    expect(
      workflow,
      contains(
        'if [ -d "\$RUNNER_TEMP/export" ]; then ls -l "\$RUNNER_TEMP/export"; fi',
      ),
    );
  });

  test('the key does not outlive the job', () {
    final cleanup = workflow.substring(
      workflow.indexOf('      - name: Remove the key from the runner'),
    );
    expect(cleanup, contains('if: always()'));
    expect(cleanup, contains(r'rm -rf "$RUNNER_TEMP/asc"'));
  });

  test('it builds with the Flutter the other workflows build with', () {
    String pin(String text) =>
        RegExp(r"FLUTTER_VERSION: '([^']+)'").firstMatch(text)!.group(1)!;
    expect(pin(workflow), pin(play));
  });
}
