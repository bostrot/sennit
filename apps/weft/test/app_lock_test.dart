/// The app lock.
///
/// Three claims. A PIN is kept only as a salted hash that the right PIN, and
/// only the right PIN, matches. The lock comes back after the chosen time in
/// the background and not before. And the gate hides the app behind the PIN
/// screen until the PIN is typed, then shows it again where it was.
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/lock/app_lock.dart';
import 'package:weft/features/lock/lock_screen.dart';
import 'package:weft/features/settings/app_lock_screen.dart';
import 'package:weft_design/weft_design.dart';

class _MemoryPinStore implements AppLockPinStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? value) async => this.value = value;
}

class _FakeBiometrics implements AppLockBiometrics {
  _FakeBiometrics({this.answer = true});

  bool answer;
  int prompts = 0;

  @override
  Future<bool> available() async => true;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return answer;
  }
}

const _hasher = AppLockPinHasher(iterations: 10);

void main() {
  final en = lookupAppL10n(const Locale('en'));

  group('PIN hash', () {
    test('matches the PIN it was made from and no other', () async {
      final stored = await _hasher.hash('2468');
      expect(stored, isNot(contains('2468')));
      expect(await _hasher.verify('2468', stored), isTrue);
      expect(await _hasher.verify('2469', stored), isFalse);
      expect(await _hasher.verify('2468', 'garbage'), isFalse);
    });

    test('salts each hash', () async {
      expect(await _hasher.hash('2468'), isNot(await _hasher.hash('2468')));
    });

    test('accepts 4 to 8 digits only', () {
      expect(isValidAppLockPin('123'), isFalse);
      expect(isValidAppLockPin('1234'), isTrue);
      expect(isValidAppLockPin('12345678'), isTrue);
      expect(isValidAppLockPin('123456789'), isFalse);
      expect(isValidAppLockPin('12a4'), isFalse);
    });
  });

  group('lock after', () {
    AppLockSessionNotifier start(ProviderContainer container) =>
        container.read(appLockSessionProvider.notifier)..unlock();

    test('returns only once the app was away long enough', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var now = DateTime(2026, 11, 25, 18);
      withClock(Clock(() => now), () {
        final session = start(container)..wentAway(60);
        now = now.add(const Duration(seconds: 59));
        session.cameBack(60);
        expect(container.read(appLockSessionProvider).unlocked, isTrue);

        session.wentAway(60);
        now = now.add(const Duration(seconds: 60));
        session.cameBack(60);
        expect(container.read(appLockSessionProvider).unlocked, isFalse);
      });
    });

    test('at once locks as the app leaves', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      start(container).wentAway(0);
      expect(container.read(appLockSessionProvider).unlocked, isFalse);
    });
  });

  group('gate', () {
    late WeftStores stores;
    late _MemoryPinStore pins;
    late _FakeBiometrics biometrics;

    setUp(() async {
      stores = WeftStores.inMemory();
      pins = _MemoryPinStore()..value = await _hasher.hash('2468');
      biometrics = _FakeBiometrics(answer: false);
    });

    Widget app(Widget home) => ProviderScope(
      overrides: [
        storesBootstrapProvider.overrideWith((ref) async => stores),
        storesProvider.overrideWithValue(stores),
        appLockPinStoreProvider.overrideWithValue(pins),
        appLockPinHasherProvider.overrideWithValue(_hasher),
        appLockBiometricsProvider.overrideWithValue(biometrics),
      ],
      child: MaterialApp(
        localizationsDelegates: weftLocalizationsDelegates,
        theme: WeftTheme.build(),
        builder: (context, child) => AppLockGate(child: child!),
        home: home,
      ),
    );

    testWidgets('shows the app when the lock is off', (tester) async {
      await tester.pumpWidget(app(const Text('inbox')));
      await tester.pumpAndSettle();
      expect(find.text('inbox'), findsOneWidget);
      expect(find.byType(LockScreen), findsNothing);
    });

    testWidgets('asks for the PIN, refuses a wrong one, opens on the right', (
      tester,
    ) async {
      stores.settings.setBool(AppLockSettings.enabled, value: true);
      await tester.pumpWidget(app(const Text('inbox')));
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsOneWidget);
      expect(find.text(en.appLockLocked), findsOneWidget);

      await tester.enterText(find.byType(TextField), '1111');
      await tester.tap(find.text(en.appLockUnlock));
      await tester.pumpAndSettle();
      expect(find.text(en.appLockWrongPin), findsOneWidget);
      expect(find.byType(LockScreen), findsOneWidget);

      await tester.enterText(find.byType(TextField), '2468');
      await tester.tap(find.text(en.appLockUnlock));
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsNothing);
      expect(find.text('inbox'), findsOneWidget);
    });

    testWidgets('makes you wait after five wrong PINs', (tester) async {
      stores.settings.setBool(AppLockSettings.enabled, value: true);
      await tester.pumpWidget(app(const Text('inbox')));
      await tester.pumpAndSettle();
      for (var i = 0; i < kAppLockMaxTries; i++) {
        await tester.enterText(find.byType(TextField), '1111');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }
      expect(find.text(en.appLockWait(kAppLockWait.inSeconds)), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

      await tester.pump(kAppLockWait);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    });

    testWidgets('opens with biometrics when they are on', (tester) async {
      biometrics.answer = true;
      stores.settings
        ..setBool(AppLockSettings.enabled, value: true)
        ..setBool(AppLockSettings.biometrics, value: true);
      await tester.pumpWidget(app(const Text('inbox')));
      await tester.pumpAndSettle();
      expect(biometrics.prompts, 1);
      expect(find.byType(LockScreen), findsNothing);
      expect(find.text('inbox'), findsOneWidget);
    });

    testWidgets('locks again after the time in the background', (tester) async {
      stores.settings
        ..setBool(AppLockSettings.enabled, value: true)
        ..setInt(AppLockSettings.afterSeconds, 0);
      await tester.pumpWidget(app(const Text('inbox')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '2468');
      await tester.tap(find.text(en.appLockUnlock));
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('settings: turning it on asks for a PIN twice and keeps it', (
      tester,
    ) async {
      pins.value = null;
      await tester.pumpWidget(app(const AppLockSettingsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text(en.appLockSwitchTitle));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1357');
      await tester.pump();
      await tester.tap(find.text(en.appLockNext));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1357');
      await tester.pump();
      await tester.tap(find.text(en.commonSave));
      await tester.pumpAndSettle();

      expect(appLockEnabled(stores.settings), isTrue);
      expect(await _hasher.verify('1357', pins.value!), isTrue);
      // The person who just chose the PIN is not locked out by it.
      expect(find.byType(LockScreen), findsNothing);
      expect(find.text(en.appLockChangePin), findsOneWidget);

      await tester.tap(find.text(en.appLockSwitchTitle));
      await tester.pumpAndSettle();
      expect(appLockEnabled(stores.settings), isFalse);
      expect(pins.value, isNull);
    });

    testWidgets('settings: a second PIN that differs starts over', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(),
            home: const AppLockPinSetupScreen(),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '1357');
      await tester.pump();
      await tester.tap(find.text(en.appLockNext));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '7531');
      await tester.pump();
      await tester.tap(find.text(en.commonSave));
      await tester.pumpAndSettle();
      expect(find.text(en.appLockPinMismatch), findsOneWidget);
      expect(find.text(en.appLockChoosePin), findsOneWidget);
    });
  });
}
