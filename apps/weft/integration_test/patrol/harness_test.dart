import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

/// Proves the harness, and nothing else.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/harness_test.dart
///
/// Every other file in this directory will test Weft. This one tests the
/// machinery that lets those files run at all, which on a device is five
/// separate things that can each fail on their own:
///
/// 1. `patrol_cli` bundles the Dart tests in this directory into
///    `test_bundle.dart` and builds it against the app,
/// 2. Gradle assembles the instrumentation APK with `PatrolJUnitRunner`
///    (`android/app/src/androidTest/.../MainActivityTest.java`), or `xcodebuild`
///    the `RunnerUITests` bundle,
/// 3. the runner launches Weft and the Dart test process attaches to it,
/// 4. `listDartTests` finds these tests and reports each as its own case,
/// 5. the platform automator — the thing `integration_test` does not have — is
///    reachable from Dart.
///
/// The first four are proven by this file being *reported* at all. Only the
/// fifth needs an assertion, and it is the whole reason Patrol is here: without
/// it the suite is `flutter test integration_test` with extra steps.
///
/// Deliberately free of Matrix, of the homeserver and of Weft's own widgets.
/// When `login_test.dart` fails the first question is whether the device, the
/// build or the app broke, and a harness test that touches a homeserver cannot
/// answer it.
void main() {
  patrolTest('the test bundle runs on the device', ($) async {
    await $.pumpWidgetAndSettle(const _HarnessProbe());

    expect($(_kProbeText), findsOneWidget);
  });

  // Skipped rather than absent on macOS, so the report says "no automator here"
  // instead of quietly listing one test fewer than the other rows. Patrol's own
  // documentation is the authority: *"Platform automation is currently
  // available on Android, iOS, and Web."* `docs/quality/e2e-matrix.md` records
  // what that costs the MAC row — six of thirteen scenarios.
  patrolTest(
    'the platform automator answers outside the Flutter view',
    ($) async {
      await $.pumpWidgetAndSettle(const _HarnessProbe());

      // Home and back is the smallest round trip that leaves the Flutter view
      // entirely and returns to it. With no automator attached this throws
      // rather than silently no-opping, which is the behaviour wanted: a
      // harness reporting green without one would let every native assertion
      // in this suite become a lie.
      await $.platform.mobile.pressHome();
      await $.platform.mobile.openApp();

      expect($(_kProbeText), findsOneWidget);
    },
    skip: !_hasPlatformAutomator,
  );
}

const _kProbeText = 'Weft E2E harness';

/// The smallest thing that can be pumped and found again after a trip through
/// the launcher. Not Weft: booting the real app pulls in the session, the
/// notification plugin and the share channel, and a failure in any of those is
/// a failure this file must not be the one to report.
class _HarnessProbe extends StatelessWidget {
  const _HarnessProbe();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: Center(child: Text(_kProbeText))),
    );
  }
}

/// Whether this row has a platform automator at all.
///
/// Deliberately a runtime `Platform` check and not a `--dart-define`: one
/// bundle is built once and run across the matrix, and a row that has to be
/// told what it is will eventually be told wrong.
bool get _hasPlatformAutomator => Platform.isAndroid || Platform.isIOS;
