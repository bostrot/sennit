/// The AI settings' "On this device" half in every locale, at both ends of the
/// text scale, on a phone — the same check as `l10n_overflow_test.dart` for a
/// section that file cannot reach: it sits at the bottom of a long, lazily
/// built list.
///
/// Pumped with the least memory there is, so both memory warnings — the
/// longest text the panel can show — are on screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/endpoints_screen.dart';
import 'package:weft/features/settings/on_device_model_panel.dart';
import 'package:weft/services/ai/on_device/on_device_models.dart';

import 'support/golden_harness.dart';

void main() {
  setUpAll(loadGoldenFonts);

  const phone = Size(360, 800);

  for (final locale in weftSupportedLocales) {
    final tag = locale.toLanguageTag();
    for (final scale in const [1.0, 2.0]) {
      testWidgets('$tag at ${scale}x', (tester) async {
        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = previous);
        final stores = WeftStores.inMemory();
        addTearDown(stores.dispose);
        final context = TextEditingController();
        addTearDown(context.dispose);

        await pumpWeft(
          tester,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                OnDeviceModelPanel(
                  selected: OnDeviceLlmSpec.bonsai8b,
                  onSelect: (_) {},
                  mobileData: false,
                  onMobileData: (_) {},
                  contextField: context,
                  ramBytes: 3 * 1024 * 1024 * 1024 - 1,
                ),
              ],
            ),
          ),
          size: phone,
          variant: WeftGoldenVariant(
            name: tag,
            locale: locale,
            textScale: scale,
          ),
          stores: stores,
        );
        await tester.pump();

        expect(
          errors,
          isEmpty,
          reason:
              '$tag at ${scale}x reported ${errors.length} error(s). The '
              'first:\n'
              '${errors.isEmpty ? '' : errors.first.exceptionAsString()}',
        );
      });

      testWidgets('$tag server or device switch at ${scale}x', (tester) async {
        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = previous);
        final stores = WeftStores.inMemory();
        addTearDown(stores.dispose);

        await pumpWeft(
          tester,
          const EndpointsScreen(),
          size: phone,
          variant: WeftGoldenVariant(
            name: tag,
            locale: locale,
            textScale: scale,
          ),
          stores: stores,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('llm-provider')),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();

        expect(
          errors,
          isEmpty,
          reason:
              '$tag at ${scale}x reported ${errors.length} error(s). The '
              'first:\n'
              '${errors.isEmpty ? '' : errors.first.exceptionAsString()}',
        );
      });
    }
  }
}
