import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards on the macOS build the release page serves, which is also what
/// `brew install --cask bostrot/tap/sennit` installs.
///
/// Homebrew quarantines what it installs, so an ad hoc or unnotarized zip
/// behind the cask opens as "damaged" for everyone; and a zip replaced under a
/// released tag fails every install on its checksum. All of it is wired by
/// string in YAML, where a dropped flag is a green run.
File _repoFile(String relative) {
  for (final prefix in const ['', '../../']) {
    final file = File('$prefix$relative');
    if (file.existsSync()) return file;
  }
  throw StateError(
    '$relative not found — run from apps/weft or from the workspace root',
  );
}

String _job(String workflow, String name) {
  final start = workflow.indexOf('\n  $name:\n');
  expect(start, isNot(-1), reason: 'no $name job');
  final next = RegExp(
    r'\n  [a-z_]+:\n',
  ).firstMatch(workflow.substring(start + 1));
  return next == null
      ? workflow.substring(start)
      : workflow.substring(start, start + 1 + next.start);
}

void main() {
  late String release;
  setUpAll(() {
    release = _repoFile('.github/workflows/release.yml').readAsStringSync();
  });

  test('a version bump on main releases, not only a pushed tag', () {
    expect(release, contains("    branches: [main]\n"));
    expect(release, contains("    paths: ['apps/weft/pubspec.yaml']\n"));
    expect(release, contains("    tags: ['v*.*.*']\n"));
    // The tag is created on the commit that was built.
    expect(
      release,
      contains(r'tag_name: v${{ needs.verify.outputs.version }}'),
    );
  });

  test('an existing release is never rebuilt', () {
    final verify = _job(release, 'verify');
    expect(verify, contains(r'gh release view "v$VERSION"'));
    for (final job in ['android', 'linux', 'windows', 'macos', 'ios']) {
      expect(
        _job(release, job),
        contains("if: needs.verify.outputs.build == 'true'"),
        reason: job,
      );
    }
    expect(
      _job(release, 'publish'),
      contains("if: needs.verify.outputs.publish == 'true'"),
    );
  });

  test('the app is signed with its entitlements and the hardened runtime', () {
    final macos = _job(release, 'macos');
    expect(
      macos,
      contains('APP_ENTITLEMENTS: apps/weft/macos/Runner/Release.entitlements'),
    );
    expect(
      macos,
      contains(r'-o "$RUNNER_TEMP/app.entitlements" "$APP_ENTITLEMENTS"'),
    );
    expect(
      macos,
      contains(r'--entitlements "$RUNNER_TEMP/app.entitlements" "$APP"'),
    );
    expect(macos, contains('--options runtime --timestamp'));
    expect(macos, isNot(contains('codesign --deep --force')));
  });

  test('notarization is checked the way Gatekeeper checks it', () {
    final macos = _job(release, 'macos');
    expect(macos, contains('xcrun notarytool submit'));
    expect(macos, contains(r'xcrun stapler staple "$APP"'));
    expect(
      macos,
      contains(r'spctl --assess --type execute --verbose=2 "$APP"'),
    );
    // The zip is made after stapling, so the ticket travels with it.
    expect(
      macos.indexOf('- name: Package'),
      greaterThan(macos.indexOf(r'xcrun stapler staple "$APP"')),
    );
  });

  test('the cask follows only a notarized zip, by what the release serves', () {
    final homebrew = _job(release, 'homebrew');
    expect(homebrew, contains("needs.macos.outputs.notarized == 'true'"));
    expect(homebrew, contains('gh release download'));
    expect(homebrew, contains('tooling/scripts/update_homebrew_cask.sh'));
  });
}
