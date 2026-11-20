import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/bridges/bridge_login_flow.dart';
import 'package:weft/features/bridges/bridges_screen.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft/app/localisation.dart';

/// A bridge that answers `whoami` with a fixed account list.
class _StatusBridge implements BridgeLoginBackend {
  _StatusBridge({this.logins = const [], this.error});

  final List<BridgeLogin> logins;
  final BridgeException? error;
  final List<String> loggedOut = [];
  String? reloginId;

  @override
  Future<BridgeWhoami> whoami() async {
    if (error != null) throw error!;
    return BridgeWhoami(logins: logins);
  }

  @override
  Future<List<BridgeLoginFlow>> loginFlows() async => const [
    BridgeLoginFlow(id: 'qr', name: 'QR'),
  ];

  @override
  Future<LoginStep> startLogin(String flowId, {String? reloginId}) async {
    this.reloginId = reloginId;
    return const LoginStep(
      stepId: 'qr',
      type: LoginStepType.displayAndWait,
      loginId: 'lg',
      displayType: 'qr',
      displayData: 'pair-me',
    );
  }

  @override
  Future<LoginStep> waitForStep({
    required String loginId,
    required String stepId,
  }) => Completer<LoginStep>().future;

  @override
  Future<LoginStep> submitStep({
    required String loginId,
    required String stepId,
    required String stepType,
    Map<String, Object?>? body,
  }) => throw UnimplementedError();

  @override
  Future<void> cancelLogin(String loginId) async {}

  @override
  Future<void> logout(String loginId) async => loggedOut.add(loginId);

  @override
  bool get supportsCookies => false;

  @override
  bool get acceptsUnlistedFlows => true;

  @override
  void dispose() {}
}

Future<void> _pump(
  WidgetTester tester, {
  List<DetectedBridge> detected = const [],
  Map<ChatNetwork, _StatusBridge> bridges = const {},
}) async {
  final stores = WeftStores.inMemory();
  addTearDown(stores.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storesProvider.overrideWithValue(stores),
        detectedBridgesProvider.overrideWithValue(detected),
        bridgeEndpointsProvider.overrideWith((ref) async => const {}),
        bridgeBackendFactoryProvider.overrideWithValue(
          (network, {botUserId, provisioningUrl}) => bridges[network],
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: weftLocalizationsDelegates,
        theme: WeftTheme.build(),
        home: const BridgesScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Regression hunt for the on-device crash: popping the bridges screen threw
  // `'dependents.isEmpty': is not true` from InheritedElement.debugDeactivated.
  testWidgets('opening and closing the screen does not throw', (tester) async {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storesProvider.overrideWithValue(stores)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const BridgesScreen(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Messengers'), findsOneWidget);

    // Pop exactly the way the user did.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a messenger nobody connected yet offers Connect', (
    tester,
  ) async {
    await _pump(
      tester,
      detected: const [
        DetectedBridge(
          network: ChatNetwork.discord,
          botUserId: '@discordbot:example.org',
        ),
      ],
      bridges: {ChatNetwork.discord: _StatusBridge()},
    );

    expect(find.text('Discord'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.textContaining('0 '), findsNothing);
    expect(
      find.textContaining('@discordbot'),
      findsNothing,
      reason: 'the bot is plumbing, not something to read',
    );
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BridgeLoginFlowScreen), findsOneWidget);
    expect(find.text('Scan this code with Discord'), findsOneWidget);
  });

  testWidgets('a connected messenger names the account, without a button', (
    tester,
  ) async {
    await _pump(
      tester,
      detected: const [
        DetectedBridge(
          network: ChatNetwork.whatsapp,
          botUserId: '@whatsappbot:example.org',
          roomCount: 12,
        ),
      ],
      bridges: {
        ChatNetwork.whatsapp: _StatusBridge(
          logins: const [
            BridgeLogin(
              id: '4915112345678',
              name: '+49 151 12345678',
              state: BridgeLoginState.connected,
            ),
          ],
        ),
      },
    );

    expect(find.text('Connected as +49 151 12345678'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Reconnect'), findsNothing);
  });

  testWidgets('disconnecting asks first, then signs the account out', (
    tester,
  ) async {
    final whatsapp = _StatusBridge(
      logins: const [
        BridgeLogin(
          id: '4915112345678',
          name: '+49 151 12345678',
          state: BridgeLoginState.connected,
        ),
      ],
    );
    await _pump(
      tester,
      detected: const [
        DetectedBridge(
          network: ChatNetwork.whatsapp,
          botUserId: '@whatsappbot:example.org',
        ),
      ],
      bridges: {ChatNetwork.whatsapp: whatsapp},
    );

    await tester.tap(find.byTooltip('More for WhatsApp'));
    await tester.pumpAndSettle();
    expect(find.text('Add another account'), findsOneWidget);
    expect(find.text('Open the WhatsApp bridge chat'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(
      find.text('Disconnect WhatsApp (+49 151 12345678)?'),
      findsOneWidget,
    );
    expect(whatsapp.loggedOut, isEmpty, reason: 'nothing happens unasked');
    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(whatsapp.loggedOut, ['4915112345678']);
  });

  testWidgets('a signed-out account offers to reconnect that account', (
    tester,
  ) async {
    final signal = _StatusBridge(
      logins: const [
        BridgeLogin(
          id: 'signal-uuid',
          name: '+49 170 1234567',
          state: BridgeLoginState.badCredentials,
        ),
      ],
    );
    await _pump(
      tester,
      detected: const [
        DetectedBridge(
          network: ChatNetwork.signal,
          botUserId: '@signalbot:example.org',
        ),
      ],
      bridges: {ChatNetwork.signal: signal},
    );

    expect(
      find.text(
        '+49 170 1234567 was signed out — reconnect to keep getting messages',
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Reconnect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Reconnect Signal'), findsOneWidget);
    expect(signal.reloginId, 'signal-uuid');
  });

  testWidgets('a bridge that does not answer says so and can be asked again', (
    tester,
  ) async {
    await _pump(
      tester,
      detected: const [
        DetectedBridge(
          network: ChatNetwork.telegram,
          botUserId: '@telegrambot:example.org',
        ),
      ],
      bridges: {
        ChatNetwork.telegram: _StatusBridge(
          error: const BridgeException(
            'The bridge bot did not answer.',
            failure: BridgeFailure.timeout,
          ),
        ),
      },
    );

    expect(find.text('Not responding right now'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Try again'), findsOneWidget);
  });

  testWidgets('a server with no messengers to offer says so', (tester) async {
    await _pump(tester);
    expect(
      find.text(
        'Your server doesn’t offer any other messengers to connect yet.',
      ),
      findsOneWidget,
    );
  });
}
