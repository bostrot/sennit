import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/build_info.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/settings_screen.dart';
import 'package:weft/services/backup/backup_service.dart' show kSennitVersion;

import 'support/golden_harness.dart';

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
  group('BuildInfo.summary', () {
    test('an untagged CI build names its commit, branch and build time', () {
      const info = BuildInfo(
        commit: 'a1b2c3d',
        ref: 'main',
        builtAt: '2026-10-15T05:42:09Z',
        mode: 'release',
      );
      expect(info.summary, 'a1b2c3d · main · 2026-10-15 05:42 UTC · release');
    });

    test('a tagged build says nothing beyond its version', () {
      const info = BuildInfo(
        commit: 'a1b2c3d',
        ref: 'v1.0.3',
        tag: 'v1.0.3',
        builtAt: '2026-10-15T05:42:09Z',
        mode: 'release',
      );
      expect(info.summary, isNull);
    });

    test('a release build without defines says nothing', () {
      expect(const BuildInfo(mode: 'release').summary, isNull);
    });

    test('a local debug build still says it is one', () {
      expect(const BuildInfo(mode: 'debug').summary, 'debug');
    });

    test('a build time that does not parse is left out, not shown raw', () {
      const info = BuildInfo(commit: 'a1b2c3d', builtAt: 'yesterday');
      expect(info.summary, isNot(contains('yesterday')));
      expect(info.summary, startsWith('a1b2c3d · '));
    });

    test('a time with an offset is shown in UTC', () {
      const info = BuildInfo(
        commit: 'a1b2c3d',
        builtAt: '2026-10-15T07:42:00+02:00',
        mode: 'profile',
      );
      expect(info.summary, 'a1b2c3d · 2026-10-15 05:42 UTC · profile');
    });
  });

  testWidgets('Settings → About shows the version and the build line', (
    tester,
  ) async {
    await pumpWeft(
      tester,
      const SettingsScreen(),
      stores: WeftStores.inMemory(),
    );
    final about = find.text('About Sennit');
    await tester.scrollUntilVisible(about, 200);
    await tester.tap(about);
    await tester.pumpAndSettle();

    expect(find.byType(AboutDialog), findsOneWidget);
    expect(find.text(kSennitVersion), findsOneWidget);
    // A test runs in debug mode with no defines, so the line is just that.
    final line = BuildInfo.current.summary;
    expect(line, isNotNull);
    expect(find.widgetWithText(SelectableText, line!), findsOneWidget);
  });

  group('tooling/scripts/build_info.sh', () {
    test(
      'prints the JSON the defines are read from',
      () {
        final root = _repoFile(
          'tooling/scripts/build_info.sh',
        ).parent.parent.parent;
        final result = Process.runSync(
          'bash',
          ['tooling/scripts/build_info.sh'],
          workingDirectory: root.path,
          environment: {'GITHUB_REF_NAME': 'main', 'GITHUB_REF_TYPE': 'branch'},
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final json = jsonDecode(result.stdout as String) as Map;
        expect(json.keys, {'GIT_SHA', 'GIT_REF', 'GIT_TAG', 'BUILD_TIME'});
        expect(json['GIT_SHA'], matches(RegExp(r'^[0-9a-f]{7,}$')));
        expect(json['GIT_REF'], 'main');
        expect(DateTime.tryParse(json['BUILD_TIME'] as String), isNotNull);
      },
      skip: Platform.isWindows ? 'needs bash' : null,
    );

    test(
      'a tag push is recorded as a tagged build',
      () {
        final root = _repoFile(
          'tooling/scripts/build_info.sh',
        ).parent.parent.parent;
        final result = Process.runSync(
          'bash',
          ['tooling/scripts/build_info.sh'],
          workingDirectory: root.path,
          environment: {'GITHUB_REF_NAME': 'v9.9.9', 'GITHUB_REF_TYPE': 'tag'},
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          (jsonDecode(result.stdout as String) as Map)['GIT_TAG'],
          'v9.9.9',
        );
      },
      skip: Platform.isWindows ? 'needs bash' : null,
    );
  });

  test('both store uploads build with the details', () {
    const define = r'--dart-define-from-file="$RUNNER_TEMP/build_info.json"';
    for (final name in const ['deploy_internal.yml', 'deploy_testflight.yml']) {
      final workflow = _repoFile('.github/workflows/$name').readAsStringSync();
      expect(
        workflow,
        contains('build_info.sh > "\$RUNNER_TEMP/build_info.json"'),
        reason: name,
      );
      expect(workflow, contains(define), reason: name);
    }
  });
}
