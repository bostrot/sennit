import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'package:weft/features/settings/devices_screen.dart';
import 'package:weft/features/settings/security_screen.dart';

import '../support/golden_harness.dart';
import '../support/session_fakes.dart';

/// Goldens for the two account screens built in Phase 06.
///
/// Both draw something no other surface in Weft does: a *fact about the
/// account* rather than a room's contents. The devices screen is three trust
/// states stacked in one list — verified, not verified, no encryption keys —
/// where the whole design problem is that the middle one has to read as a
/// warning without the third one reading as a catastrophe. The security screen
/// is the one place Weft says an outcome is irreversible, and the sentence that
/// says so has to survive being pushed around by a status row above it.
/// Neither is judgeable from an assertion that a string is on screen.
///
/// The fakes are the same ones the widget tests use. That matters more here
/// than usual: an account cannot be *put into* "no backup and nowhere else
/// signed in" on demand — reaching it against a real homeserver means an
/// account that has never set recovery up and has exactly one login, which is a
/// state that stops existing the moment anyone uses it.
void main() {
  setUpAll(loadGoldenFonts);

  /// Fixed, and read through [clock] by `describeLastSeen`.
  ///
  /// Every row on the devices screen renders a *relative* last-seen time, so
  /// without this the image disagrees with itself an hour later and the golden
  /// fails in a run that changed nothing.
  final now = DateTime.utc(2026, 8, 18, 12);

  final devices = [
    WeftDevice(
      deviceId: 'QKQZWXYZTA',
      displayName: 'Weft on Pixel',
      lastSeenIp: '10.0.0.4',
      lastSeenAt: now.subtract(const Duration(minutes: 1)),
      isCurrent: true,
      trust: DeviceTrust.verified,
    ),
    WeftDevice(
      deviceId: 'MNBVCXZLKJ',
      displayName: 'Weft on laptop',
      lastSeenIp: '203.0.113.9',
      lastSeenAt: now.subtract(const Duration(days: 2)),
      trust: DeviceTrust.unverified,
    ),
    // No display name and no address: the row falls back to the device id, and
    // the second line has to stay a line rather than collapsing the tile.
    WeftDevice(
      deviceId: 'POIUYTREWQ',
      lastSeenAt: now.subtract(const Duration(days: 400)),
      trust: DeviceTrust.noKeys,
    ),
  ];

  /// Pumps [child] under a fixed clock and captures it in both themes.
  ///
  /// One helper rather than two tests, for the reason the other golden suites
  /// state: the failure mode is a chip or a warning box that reads on one
  /// surface and vanishes on the other, and that is only visible when both
  /// images come from an identical fixture.
  Future<void> expectScreenGolden(
    WidgetTester tester,
    String name,
    Widget Function() child, {
    Size size = const Size(560, 820),
    List<WeftDevice> account = const [],
    KeyBackupStatus backup = KeyBackupStatus.none,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      await withClock(Clock.fixed(now), () async {
        await pumpWeft(
          tester,
          child(),
          size: size,
          mode: mode,
          deviceManager: FakeDeviceManager(account),
          keyBackup: FakeKeyBackup(status0: backup),
        );

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('${name}_$suffix.png'),
        );
      });
    }
  }

  testWidgets('the device list, both themes', (tester) async {
    // All three trust states in one frame, plus the current-device marker and
    // the sign-out-others action at the foot. The chips are the point: they are
    // the only thing separating a session that can read your messages from one
    // that cannot, and they are three words in three colours.
    await expectScreenGolden(
      tester,
      'devices_list',
      DevicesScreen.new,
      account: devices,
    );
  });

  testWidgets('no backup and nowhere else signed in, both themes', (
    tester,
  ) async {
    // The copy that earns the screen. Every other state is a status row; this
    // one is the sentence saying the account is one dropped phone away from
    // losing every encrypted message, and it is in the red [PrivacyNotice]
    // rather than the quiet box. Needs no fixed clock of its own — nothing here
    // renders a relative time — but takes one anyway from the shared helper.
    await expectScreenGolden(
      tester,
      'security_absent',
      SecurityScreen.new,
      account: [devices.first],
    );
  });

  testWidgets('a healthy backup, both themes', (tester) async {
    // The counterweight, and the reason the first image is worth having: the
    // same screen with nothing to warn about must look calm rather than merely
    // less alarming. Also the only state where the destructive action is the
    // only action, so it is where "Replace the recovery key" has to read as a
    // cost.
    await expectScreenGolden(
      tester,
      'security_backed_up',
      SecurityScreen.new,
      account: devices,
      backup: const KeyBackupStatus(
        state: KeyBackupState.upToDate,
        crossSigningEnabled: true,
        version: '3',
        keyCount: 412,
      ),
    );
  });
}
