import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/features/bridges/bridge_login_flow.dart';

/// Signing in to a bridge, end to end.
///
/// The flow used to be two screens and a sheet: an untitled list of login
/// methods in a bottom sheet, then a column of bare text fields somewhere
/// else, then nothing between "Continue" and either a QR or an error. What is
/// asserted here is the journey a person actually takes — pick a method, type
/// a phone number, get told when it is wrong *and where*, read back the code,
/// arrive somewhere that says it worked — because every one of those steps is
/// a place the old screen dropped them.
///
/// The bridge is a scripted HTTP endpoint rather than a stubbed session: the
/// step decoding, the validation patterns and the request bodies are exactly
/// the ones a real mautrix bridge would see.
class _ScriptedBridge {
  _ScriptedBridge(this.responses);

  /// One response per request, in order. The last repeats, which is what a
  /// bridge does while it waits for the other side.
  final List<Map<String, Object?>> responses;

  int calls = 0;
  final List<String> paths = [];
  final List<Object?> bodies = [];

  /// Set to fail every request with this message.
  String? failure;

  BridgeProvisioningClient get client => BridgeProvisioningClient(
    baseUrl: Uri.parse('https://bridge.example.org/_matrix/provision'),
    accessToken: 't',
    httpClient: MockClient((request) async {
      paths.add(request.url.path);
      bodies.add(request.body.isEmpty ? null : jsonDecode(request.body));
      if (failure != null) {
        return http.Response(
          jsonEncode({'error': failure}),
          502,
        );
      }
      final index = calls < responses.length ? calls : responses.length - 1;
      calls++;
      return http.Response(jsonEncode(responses[index]), 200);
    }),
  );
}

Map<String, Object?> _phoneStep() => {
  'step_id': 'phone',
  'type': 'user_input',
  'login_id': 'lg1',
  'instructions': 'Enter the number this account uses.',
  'user_input': {
    'fields': [
      {
        'id': 'phone',
        'type': 'phone_number',
        'name': 'Phone number',
        'pattern': r'^\+?[0-9]{8,15}$',
      },
    ],
  },
};

Map<String, Object?> _codeStep() => {
  'step_id': 'code',
  'type': 'user_input',
  'login_id': 'lg1',
  'instructions': 'We sent you a six-digit code.',
  'user_input': {
    'fields': [
      {
        'id': 'code',
        'type': '2fa_code',
        'name': 'Verification code',
        'pattern': r'^[0-9]{6}$',
      },
    ],
  },
};

Map<String, Object?> _completeStep() => {
  'step_id': 'done',
  'type': 'complete',
  'complete': {'login_id': 'lg1'},
};

Map<String, Object?> _qrStep() => {
  'step_id': 'qr',
  'type': 'display_and_wait',
  'login_id': 'lg1',
  'instructions': 'Scan this with the phone that has the account.',
  'display_and_wait': {'type': 'qr', 'data': 'weft-pair-abc123'},
};

void main() {
  const flows = [
    BridgeLoginFlow(
      id: 'qr',
      name: 'Scan a QR code',
      description: 'Use the phone that already has the account.',
    ),
    BridgeLoginFlow(
      id: 'phone',
      name: 'Phone number',
      description: 'We text you a code.',
    ),
  ];

  Future<void> pump(
    WidgetTester tester,
    _ScriptedBridge bridge, {
    List<BridgeLoginFlow> offered = flows,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(),
        home: BridgeLoginFlowScreen(
          client: bridge.client,
          network: ChatNetwork.whatsapp,
          flows: offered,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('offers the ways this bridge can sign in', (tester) async {
    final bridge = _ScriptedBridge([_phoneStep()]);
    await pump(tester, bridge);

    expect(find.text('How do you want to sign in?'), findsOneWidget);
    expect(find.text('Scan a QR code'), findsOneWidget);
    expect(find.text('Phone number'), findsOneWidget);
    expect(
      find.text('We text you a code.'),
      findsOneWidget,
      reason: "the bridge's own words are what tell the methods apart",
    );
    expect(bridge.calls, 0, reason: 'nothing starts until one is picked');
  });

  testWidgets('a bridge with one way skips the choice', (tester) async {
    final bridge = _ScriptedBridge([_phoneStep()]);
    await pump(tester, bridge, offered: [flows.last]);
    await tester.pumpAndSettle();

    expect(find.text('How do you want to sign in?'), findsNothing);
    expect(find.text('What is your phone number?'), findsOneWidget);
  });

  testWidgets('picking a method starts that flow', (tester) async {
    final bridge = _ScriptedBridge([_phoneStep()]);
    await pump(tester, bridge);

    await tester.tap(find.text('Phone number'));
    await tester.pumpAndSettle();

    expect(find.text('What is your phone number?'), findsOneWidget);
    expect(
      find.text('Enter the number this account uses.'),
      findsOneWidget,
      reason: "the bridge's instructions are shown verbatim",
    );
    expect(bridge.paths.single, endsWith('/v3/login/start/phone'));
  });

  testWidgets('an empty field says so, and nothing is sent', (tester) async {
    final bridge = _ScriptedBridge([_phoneStep(), _completeStep()]);
    await pump(tester, bridge, offered: [flows.last]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Phone number is required.'), findsOneWidget);
    expect(bridge.calls, 1, reason: 'only the start call; nothing submitted');
  });

  testWidgets('a malformed number is explained where it was typed', (
    tester,
  ) async {
    final bridge = _ScriptedBridge([_phoneStep(), _completeStep()]);
    await pump(tester, bridge, offered: [flows.last]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '123');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('does not look like a full phone number'),
      findsOneWidget,
    );
    expect(bridge.calls, 1);
  });

  testWidgets('a good number moves on to the code, with an empty field', (
    tester,
  ) async {
    final bridge = _ScriptedBridge([
      _phoneStep(),
      _codeStep(),
      _completeStep(),
    ]);
    await pump(tester, bridge, offered: [flows.last]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '+491701234567');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Enter the code you were sent'), findsOneWidget);
    expect(bridge.bodies.last, {'phone': '+491701234567'});
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
      reason: 'the phone number must not be carried into the code field',
    );
  });

  testWidgets('the code completes the flow', (tester) async {
    final bridge = _ScriptedBridge([
      _phoneStep(),
      _codeStep(),
      _completeStep(),
    ]);
    await pump(tester, bridge, offered: [flows.last]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '+491701234567');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('WhatsApp is connected'), findsOneWidget);
    expect(
      find.textContaining('pulling your conversations across'),
      findsOneWidget,
      reason: 'a login that succeeded has to say what happens next',
    );
  });

  testWidgets('a code field takes digits only', (tester) async {
    final bridge = _ScriptedBridge([_codeStep(), _completeStep()]);
    await pump(tester, bridge, offered: [flows.last]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '12a34b56');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '123456',
    );
  });

  testWidgets('a QR step shows the code and offers to copy it', (
    tester,
  ) async {
    final bridge = _ScriptedBridge([_qrStep()]);
    await pump(tester, bridge, offered: [flows.first]);
    // Not pumpAndSettle: the expiry clock ticks once a second for as long as
    // this step is on screen, so nothing about it ever settles.
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('Scan this with the phone that has the account.'),
      findsOneWidget,
    );
    expect(find.text('weft-pair-abc123'), findsOneWidget);
    expect(find.text('Copy code'), findsOneWidget);
    expect(find.textContaining('Expires in'), findsOneWidget);

    // Let the widget go before the timer does, which is what the teardown
    // check is for.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a bridge that refuses says so and offers another go', (
    tester,
  ) async {
    final bridge = _ScriptedBridge([_phoneStep()])..failure = 'nope';
    await pump(tester, bridge, offered: [flows.last]);
    await tester.pumpAndSettle();

    expect(find.text('Could not sign in'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    bridge.failure = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('What is your phone number?'), findsOneWidget);
  });
}
