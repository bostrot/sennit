import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/lock/app_lock.dart';
import 'package:weft/features/lock/lock_screen.dart';
import 'package:weft/features/settings/app_lock_screen.dart';
import 'package:weft_design/weft_design.dart';

import '../support/golden_harness.dart';

/// Goldens for the app lock: the screen that stands in front of the chats,
/// and its settings with the lock on.
///
/// `app_lock_test.dart` pins what the lock does; these pin that the PIN field
/// is the first thing on the lock screen and that the settings show the time
/// choices only once there is a lock to time.
void main() {
  setUpAll(loadGoldenFonts);

  const phone = Size(620, 1180);

  Future<void> expectGolden(
    WidgetTester tester,
    String name,
    Widget Function(Key key) screen,
  ) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      final stores = WeftStores.inMemory();
      stores.settings.setBool(AppLockSettings.enabled, value: true);
      await pumpWeft(
        tester,
        screen(ValueKey(suffix)),
        size: phone,
        mode: mode,
        stores: stores,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('app_lock_${name}_$suffix.png'),
      );
    }
  }

  testWidgets('lock screen', (tester) async {
    await expectGolden(tester, 'locked', (key) => LockScreen(key: key));
  });

  testWidgets('settings with the lock on', (tester) async {
    await expectGolden(
      tester,
      'settings',
      (key) => AppLockSettingsScreen(key: key),
    );
  });
}
