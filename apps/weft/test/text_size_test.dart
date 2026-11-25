import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_store/weft_store.dart';
import 'package:weft_sync/weft_sync.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/app/text_size.dart';
import 'package:weft/features/settings/appearance_sheet.dart';

import 'support/a11y_harness.dart';

/// Settings → Appearance → Text size: a factor on top of the phone's own text
/// size, stored, synced, and applied at the app root and to message text.
void main() {
  WeftStores freshStores() {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    return stores;
  }

  group('MultipliedTextScaler', () {
    test('multiplies the system scaler rather than replacing it', () {
      const scaler = MultipliedTextScaler(TextScaler.linear(1.5), 1.2);
      expect(scaler.scale(10), closeTo(18, 1e-9));
    });

    test('keeps a non-linear system curve', () {
      final scaler = MultipliedTextScaler(_Halving(), 2);
      // The base grows 10 to 15; times two is 30, not 10 × (1.5 × 2).
      expect(scaler.scale(10), 30);
      expect(scaler.scale(40), 2 * (40 + 20));
    });

    test('can still be clamped by a widget that needs to', () {
      const scaler = MultipliedTextScaler(TextScaler.linear(2), 1.6);
      expect(scaler.clamp(maxScaleFactor: 1.3).scale(10), closeTo(13, 1e-9));
    });

    test('compares by value, so an unchanged setting rebuilds nothing', () {
      expect(
        const MultipliedTextScaler(TextScaler.noScaling, 1.2),
        const MultipliedTextScaler(TextScaler.noScaling, 1.2),
      );
    });
  });

  group('the setting', () {
    test('follows the phone until it is moved', () {
      final stores = freshStores();
      final container = ProviderContainer(
        overrides: [storesProvider.overrideWithValue(stores)],
      );
      addTearDown(container.dispose);
      expect(container.read(textScaleProvider), 1.0);
      expect(container.read(messageTextScaleProvider), 1.0);
    });

    test('holds a stored value to the slider range', () {
      final stores = freshStores();
      final container = ProviderContainer(
        overrides: [storesProvider.overrideWithValue(stores)],
      );
      addTearDown(container.dispose);
      stores.settings.setDouble(WeftSettings.textScale, 0);
      stores.settings.setDouble(WeftSettings.messageTextScale, 9);
      expect(container.read(textScaleProvider), kTextScaleMin);
      expect(container.read(messageTextScaleProvider), kTextScaleMax);
    });

    test('is 1.0 with no database rather than an error', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(textScaleProvider), 1.0);
    });

    test('travels with device sync', () {
      expect(SyncPolicy.syncsSetting(WeftSettings.textScale), isTrue);
      expect(SyncPolicy.syncsSetting(WeftSettings.messageTextScale), isTrue);
    });
  });

  testWidgets('the app scale and the message scale multiply the system', (
    tester,
  ) async {
    final stores = freshStores();
    stores.settings.setDouble(WeftSettings.textScale, 1.5);
    stores.settings.setDouble(WeftSettings.messageTextScale, 1.2);
    late TextScaler app;
    late TextScaler message;
    await pumpScreen(
      tester,
      AppTextScale(
        child: Builder(
          builder: (context) {
            app = MediaQuery.textScalerOf(context);
            return MessageTextScale(
              child: Builder(
                builder: (context) {
                  message = MediaQuery.textScalerOf(context);
                  return const SizedBox();
                },
              ),
            );
          },
        ),
      ),
      stores: stores,
      textScale: 1.3,
    );
    expect(app.scale(10), closeTo(10 * 1.3 * 1.5, 1e-9));
    expect(message.scale(10), closeTo(10 * 1.3 * 1.5 * 1.2, 1e-9));
  });

  testWidgets('the slider stores its value when it is let go', (tester) async {
    final stores = freshStores();
    final container = await pumpScreen(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showAppearanceSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      size: const Size(412, 915),
      stores: stores,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final slider = find.byType(Slider).at(1);
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    // The first text size slider, from 100 % to the far end: 160 %.
    await tester.drag(slider, const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(stores.settings.getDouble(WeftSettings.textScale), kTextScaleMax);
    expect(container.read(textScaleProvider), kTextScaleMax);
    expect(find.byType(TextSizePreview), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// A curve like Android 14's: big text grows less than small text.
class _Halving extends TextScaler {
  @override
  double scale(double fontSize) => fontSize + fontSize / 2;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => 1.5;
}
