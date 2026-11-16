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
    expect(workflow, contains('<key>destination</key><string>upload</string>'));
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
