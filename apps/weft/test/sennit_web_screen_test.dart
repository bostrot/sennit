import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/localisation.dart';
import 'package:weft/app/sennit_web_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/components/qr_card.dart';
import 'package:weft/features/settings/sennit_web_screen.dart';
import 'package:weft/services/web/pairing_registry.dart';
import 'package:weft/services/web/web_bundle_store.dart';

/// The phone half of Sennit Web as the user sees it: the switch, where to
/// open it, the pairing code and the browsers that can come back.
void main() {
  late WeftStores stores;

  setUp(() {
    stores = WeftStores.inMemory();
    PairingRegistry(stores.settings).pair('browser-key', 'Firefox · macOS');
  });

  Future<void> pump(WidgetTester tester, {bool running = true}) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storesProvider.overrideWithValue(stores),
          webBundleProvider.overrideWith(_ReadyBundle.new),
          sennitWebServerProvider.overrideWith(
            () => _FakeServing(running: running),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: const SennitWebScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('while off, lists paired browsers but no address', (
    tester,
  ) async {
    await pump(tester, running: false);

    expect(find.text('Serve on this network'), findsOneWidget);
    expect(find.text('http://192.168.1.20:8787'), findsNothing);
    expect(find.text('Pair a browser'), findsNothing);
    expect(find.text('Firefox · macOS'), findsOneWidget);
  });

  testWidgets('while on, shows the address and who is connected', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('http://192.168.1.20:8787'), findsOneWidget);
    expect(find.text('1 browser connected'), findsOneWidget);
  });

  testWidgets('pairing shows the one-time link as a QR code', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Pair a browser'));
    await tester.pumpAndSettle();

    expect(find.byType(QrCard), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
  });

  testWidgets('revoking a browser takes it off the list', (tester) async {
    await pump(tester);

    await tester.tap(find.byTooltip('Unpair'));
    await tester.pumpAndSettle();

    expect(find.text('Firefox · macOS'), findsNothing);
    expect(PairingRegistry(stores.settings).isPaired('browser-key'), isFalse);
  });
}

class _ReadyBundle extends WebBundleController {
  @override
  WebBundleState build() => WebBundleReady(
    directory: Directory.systemTemp,
    sizeBytes: 9 * 1024 * 1024,
  );
}

class _FakeServing extends SennitWebController {
  _FakeServing({required this.running});

  final bool running;

  @override
  SennitWebServing build() => running
      ? const SennitWebServing(
          running: true,
          port: kSennitWebPort,
          addresses: ['192.168.1.20'],
          connected: 1,
          phoneKey: 'phone-key',
        )
      : const SennitWebServing();

  @override
  Uri? pairingUrl() =>
      Uri.parse('http://192.168.1.20:8787/#p=phone-key&t=one-time-token');
}
