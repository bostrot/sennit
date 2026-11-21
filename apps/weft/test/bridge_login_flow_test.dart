import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/features/bridges/bridge_browser_sign_in.dart';
import 'package:weft/features/bridges/bridge_login_flow.dart';
import 'package:weft/app/localisation.dart';

/// Connecting a messenger, end to end, once per network.
///
/// What is asserted is the journey a person takes who has never heard of a
/// bridge: which ways in are offered and which one leads, what to tap on the
/// phone while a code is on screen, where a wrong code or an expired QR is
/// explained, and that it ends somewhere that says it worked. The bridge is a
/// scripted [BridgeLoginBackend] — the same interface the provisioning API and
/// the bot chat both stand behind — so each network's real step sequence can
/// be replayed, refusals and timeouts included.
class _FakeBridge implements BridgeLoginBackend {
  _FakeBridge(this.script, {this.flows = const []});

  /// One entry per start, submit or wait, in order: a [LoginStep] to return,
  /// a [BridgeException] to throw, or a [Completer] the test finishes itself.
  final List<Object> script;
  final List<BridgeLoginFlow> flows;

  /// Thrown by [loginFlows] when set.
  BridgeException? flowsError;

  final List<String> calls = [];
  final List<Map<String, Object?>?> bodies = [];
  final List<String> stepTypes = [];
  String? reloginId;
  int _next = 0;

  Future<LoginStep> _take() {
    if (_next >= script.length) return Completer<LoginStep>().future;
    final entry = script[_next++];
    return switch (entry) {
      final LoginStep step => Future.value(step),
      final BridgeException error => Future.error(error),
      final Completer<LoginStep> later => later.future,
      _ => throw StateError('bad script entry $entry'),
    };
  }

  @override
  Future<BridgeWhoami> whoami() async => const BridgeWhoami();

  @override
  Future<List<BridgeLoginFlow>> loginFlows() async {
    calls.add('flows');
    if (flowsError != null) throw flowsError!;
    return flows;
  }

  @override
  Future<LoginStep> startLogin(String flowId, {String? reloginId}) {
    calls.add('start $flowId');
    this.reloginId = reloginId;
    return _take();
  }

  @override
  Future<LoginStep> submitStep({
    required String loginId,
    required String stepId,
    required String stepType,
    Map<String, Object?>? body,
  }) {
    calls.add('submit $stepId');
    stepTypes.add(stepType);
    bodies.add(body);
    return _take();
  }

  @override
  Future<LoginStep> waitForStep({
    required String loginId,
    required String stepId,
  }) {
    calls.add('wait $stepId');
    return _take();
  }

  @override
  Future<void> cancelLogin(String loginId) async => calls.add('cancel');

  @override
  Future<void> logout(String loginId) async {}

  @override
  bool supportsCookies = false;

  @override
  bool acceptsUnlistedFlows = true;

  @override
  void dispose() {}
}

LoginStep _input(
  String id,
  List<LoginInputField> fields, {
  String? instructions,
}) => LoginStep(
  stepId: id,
  type: LoginStepType.userInput,
  loginId: 'lg1',
  instructions: instructions,
  fields: fields,
);

LoginStep _display(String id, String type, String data) => LoginStep(
  stepId: id,
  type: LoginStepType.displayAndWait,
  loginId: 'lg1',
  displayType: type,
  displayData: data,
);

const _complete = LoginStep(
  stepId: 'done',
  type: LoginStepType.complete,
  loginId: 'lg1',
);

const _phoneField = LoginInputField(
  id: 'phone',
  type: 'phone_number',
  name: 'Phone number',
  pattern: r'^\+[1-9]\d{6,14}$',
);

const _codeField = LoginInputField(id: 'code', type: '2fa_code', name: 'Code');

const _passwordField = LoginInputField(
  id: 'password',
  type: 'password',
  name: 'Password',
);

const _waFlows = [
  BridgeLoginFlow(id: 'qr', name: 'QR'),
  BridgeLoginFlow(id: 'phone', name: 'Pairing code'),
];

const _tgFlows = [
  BridgeLoginFlow(id: 'phone', name: 'Phone Number'),
  BridgeLoginFlow(id: 'qr', name: 'QR Code'),
  BridgeLoginFlow(id: 'bot', name: 'Bot token'),
  BridgeLoginFlow(id: 'manual', name: 'Manual'),
];

const _igFlows = [
  BridgeLoginFlow(id: 'instagram', name: 'instagram.com'),
  BridgeLoginFlow(id: 'instagram-password', name: 'Instagram password'),
  BridgeLoginFlow(id: 'android', name: 'Instagram Android'),
];

Future<void> _pump(
  WidgetTester tester,
  _FakeBridge bridge,
  ChatNetwork network, {
  List<BridgeLoginFlow>? flows,
  String? reloginId,
  BrowserSignIn? browserSignIn,
}) async {
  // Tall enough that a QR step's every line is built, as on a phone held
  // upright; the default test window is a landscape 800×600.
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: weftLocalizationsDelegates,
      theme: WeftTheme.build(),
      home: BridgeLoginFlowScreen(
        client: bridge,
        network: network,
        flows: flows,
        reloginId: reloginId,
        browserSignIn: browserSignIn,
      ),
    ),
  );
  await _settle(tester);
}

/// Lets the scripted bridge answer and the screen redraw. Not
/// `pumpAndSettle`: a step that waits on the phone spins until it is told
/// otherwise, and so never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
  await _settle(tester);
}

void main() {
  group('WhatsApp', () {
    testWidgets('leads with the QR code and offers the pairing code', (
      tester,
    ) async {
      final bridge = _FakeBridge(const []);
      await _pump(tester, bridge, ChatNetwork.whatsapp, flows: _waFlows);

      expect(find.text('How do you want to connect WhatsApp?'), findsOneWidget);
      expect(find.text('Scan a QR code'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      expect(find.text('Use a code instead of scanning'), findsOneWidget);
      expect(bridge.calls, isEmpty, reason: 'nothing starts until picked');
    });

    testWidgets('the QR code comes with what to tap on the phone', (
      tester,
    ) async {
      final refreshed = Completer<LoginStep>();
      final bridge = _FakeBridge([
        _display('fi.mau.whatsapp.login.qr', 'qr', '2@first'),
        refreshed,
      ]);
      await _pump(tester, bridge, ChatNetwork.whatsapp, flows: _waFlows);
      await tester.tap(find.text('Scan a QR code'));
      await _settle(tester);

      expect(find.text('Scan this code with WhatsApp'), findsOneWidget);
      expect(find.text('Open WhatsApp on your phone'), findsOneWidget);
      expect(
        find.text('Tap Link a device and point your phone at this code'),
        findsOneWidget,
      );
      expect(
        find.text('The code renews itself — just keep this screen open.'),
        findsOneWidget,
      );

      // WhatsApp replaces its code every twenty seconds or so.
      refreshed.complete(_display('fi.mau.whatsapp.login.qr', 'qr', '2@next'));
      await tester.pump();
      await tester.pump();
      expect(find.text('New code — scan this one.'), findsOneWidget);
    });

    testWidgets('the pairing code is shown big and can be copied', (
      tester,
    ) async {
      final bridge = _FakeBridge([
        _input('fi.mau.whatsapp.login.phone', [_phoneField]),
        _display('fi.mau.whatsapp.login.code', 'code', 'ABCD-EFGH'),
      ]);
      await _pump(tester, bridge, ChatNetwork.whatsapp, flows: _waFlows);
      await tester.tap(find.text('Use a code instead of scanning'));
      await _settle(tester);

      expect(find.text('What’s your phone number?'), findsOneWidget);
      expect(
        find.text(
          'The number your WhatsApp uses, with the country code — like '
          '+49 151 1234567.',
        ),
        findsOneWidget,
      );

      await _type(tester, '+4915112345678');
      expect(bridge.bodies.single, {'phone': '+4915112345678'});
      expect(find.text('Enter this code in WhatsApp'), findsOneWidget);
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      expect(find.text('Copy code'), findsOneWidget);
      expect(
        find.text('Tap Link a device, then Link with phone number instead'),
        findsOneWidget,
      );
    });

    testWidgets('a number without a country code is explained in place', (
      tester,
    ) async {
      final bridge = _FakeBridge([
        _input('fi.mau.whatsapp.login.phone', [_phoneField]),
      ]);
      await _pump(tester, bridge, ChatNetwork.whatsapp, flows: _waFlows);
      await tester.tap(find.text('Use a code instead of scanning'));
      await _settle(tester);

      await _type(tester, '0151 123');
      expect(
        find.textContaining('doesn’t look like a full phone number'),
        findsOneWidget,
      );
      expect(
        bridge.calls.where((c) => c.startsWith('submit')),
        isEmpty,
        reason: 'a value the bridge would refuse is never sent',
      );
    });

    testWidgets('an unscanned code that expires offers a fresh one', (
      tester,
    ) async {
      final bridge = _FakeBridge([
        _display('fi.mau.whatsapp.login.qr', 'qr', '2@first'),
        const BridgeException(
          'Entering code or scanning QR timed out. Please try again.',
          errorCode: 'FI.MAU.WHATSAPP.LOGIN_TIMEOUT',
        ),
        _display('fi.mau.whatsapp.login.qr', 'qr', '2@again'),
      ]);
      await _pump(tester, bridge, ChatNetwork.whatsapp, flows: _waFlows);
      await tester.tap(find.text('Scan a QR code'));
      await _settle(tester);

      expect(find.text('Could not sign in'), findsOneWidget);
      expect(
        find.text(
          'The code expired before it was used. Try again — you’ll get a '
          'fresh one.',
        ),
        findsOneWidget,
      );
      // The bridge's own words stay one tap away, not on the main screen.
      expect(find.textContaining('scanning QR timed out'), findsNothing);
      await tester.tap(find.text('Details'));
      await _settle(tester);
      expect(find.textContaining('scanning QR timed out'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await _settle(tester);
      expect(find.text('Scan this code with WhatsApp'), findsOneWidget);
      expect(bridge.calls.where((c) => c == 'start qr'), hasLength(2));
    });
  });

  group('Signal', () {
    testWidgets('one way in skips the choice and shows the QR', (tester) async {
      final bridge = _FakeBridge(
        [_display('fi.mau.signal.login.qr', 'qr', 'sgnl://linkdevice?x')],
        flows: const [BridgeLoginFlow(id: 'qr', name: 'QR')],
      );
      await _pump(tester, bridge, ChatNetwork.signal);

      expect(bridge.calls.first, 'flows');
      expect(find.textContaining('How do you want'), findsNothing);
      expect(find.text('Scan this code with Signal'), findsOneWidget);
      expect(
        find.text('Tap Link new device and scan this code'),
        findsOneWidget,
      );
      expect(
        find.text('Try another way'),
        findsNothing,
        reason: 'there is no other way to offer',
      );
    });

    testWidgets('a full device list says what to remove', (tester) async {
      final bridge = _FakeBridge(
        [
          _display('fi.mau.signal.login.qr', 'qr', 'sgnl://linkdevice?x'),
          const BridgeException(
            'You have reached the maximum number of linked devices.',
            errorCode: 'FI.MAU.SIGNAL.DEVICE_LIMIT_REACHED',
          ),
        ],
        flows: const [BridgeLoginFlow(id: 'qr', name: 'QR')],
      );
      await _pump(tester, bridge, ChatNetwork.signal);

      expect(
        find.textContaining('already has the most linked devices'),
        findsOneWidget,
      );
    });

    testWidgets('a scan completes the connection', (tester) async {
      final bridge = _FakeBridge(
        [
          _display('fi.mau.signal.login.qr', 'qr', 'sgnl://linkdevice?x'),
          _complete,
        ],
        flows: const [BridgeLoginFlow(id: 'qr', name: 'QR')],
      );
      await _pump(tester, bridge, ChatNetwork.signal);

      expect(find.text('Signal is connected'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });
  });

  group('Telegram', () {
    testWidgets('hides the operator-only way and folds away the bot one', (
      tester,
    ) async {
      await _pump(
        tester,
        _FakeBridge(const []),
        ChatNetwork.telegram,
        flows: _tgFlows,
      );

      expect(find.text('Scan a QR code'), findsOneWidget);
      expect(find.text('Sign in with your phone number'), findsOneWidget);
      expect(find.text('Connect a bot account'), findsNothing);
      expect(find.textContaining('Manual'), findsNothing);

      await tester.tap(find.text('More ways to connect'));
      await _settle(tester);
      expect(find.text('Connect a bot account'), findsOneWidget);
      expect(find.textContaining('Manual'), findsNothing);
    });

    testWidgets('number, wrong code, right code, two-step password', (
      tester,
    ) async {
      final bridge = _FakeBridge([
        _input('fi.mau.telegram.login.phone_number', [_phoneField]),
        _input('fi.mau.telegram.login.code', [_codeField]),
        _input(
          'fi.mau.telegram.login.code_retry',
          [_codeField],
          instructions: 'Incorrect code, please try again.',
        ),
        _input('fi.mau.telegram.login.password', [_passwordField]),
        _complete,
      ]);
      await _pump(tester, bridge, ChatNetwork.telegram, flows: _tgFlows);
      await tester.tap(find.text('Sign in with your phone number'));
      await _settle(tester);

      await _type(tester, '+4917012345678');
      expect(find.text('Enter the code you were sent'), findsOneWidget);
      expect(find.textContaining('look for a message from'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
        reason: 'the phone number must not carry over into the code field',
      );

      await _type(tester, '11111');
      expect(
        find.text('Incorrect code, please try again.'),
        findsOneWidget,
        reason: 'a refused code is called out, not left as small print',
      );

      await _type(tester, '22222');
      expect(find.text('Enter your password'), findsOneWidget);
      expect(find.textContaining('two-step verification'), findsOneWidget);
      final password = tester.widget<TextField>(find.byType(TextField));
      expect(password.obscureText, isTrue);

      await _type(tester, 'hunter2');
      expect(find.text('Telegram is connected'), findsOneWidget);
      expect(bridge.bodies.last, {'password': 'hunter2'});
    });

    testWidgets('a flood wait is said in words', (tester) async {
      final bridge = _FakeBridge([
        const BridgeException(
          'FLOOD_WAIT_300',
          errorCode: 'FI.MAU.TELEGRAM.FLOOD_WAIT',
        ),
      ]);
      await _pump(tester, bridge, ChatNetwork.telegram, flows: _tgFlows);
      await tester.tap(find.text('Sign in with your phone number'));
      await _settle(tester);

      expect(
        find.text(
          'Telegram wants us to slow down. Wait a few minutes, then try again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Try another way'), findsOneWidget);
    });
  });

  group('Instagram', () {
    testWidgets('leads with the password and keeps the browser way back', (
      tester,
    ) async {
      await _pump(
        tester,
        _FakeBridge(const []),
        ChatNetwork.instagram,
        flows: _igFlows,
      );

      // One everyday way in: straight to it, without a chooser.
      expect(find.text('Sign in to Instagram'), findsOneWidget);
      expect(find.text('Username'), findsNothing, reason: 'not started yet');
    });

    testWidgets('username and password, then the 2FA code', (tester) async {
      final bridge = _FakeBridge([
        _input('fi.mau.meta.instagram.credentials', const [
          LoginInputField(id: 'username', type: 'username', name: 'Username'),
          _passwordField,
        ]),
        _input('fi.mau.meta.instagram.web_two_factor', [_codeField]),
        _complete,
      ], flows: _igFlows);
      await _pump(tester, bridge, ChatNetwork.instagram);

      expect(bridge.calls, ['flows', 'start instagram-password']);
      await tester.enterText(find.byType(TextField).at(0), 'someone');
      await tester.enterText(find.byType(TextField).at(1), 'secret');
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await _settle(tester);
      expect(bridge.bodies.single, {
        'username': 'someone',
        'password': 'secret',
      });

      expect(find.text('Enter the code you were sent'), findsOneWidget);
      await _type(tester, '123456');
      expect(find.text('Instagram is connected'), findsOneWidget);
    });

    testWidgets('a checkpoint challenge points at another way', (tester) async {
      final bridge = _FakeBridge([
        const BridgeException(
          'checkpoint_required',
          errorCode: 'FI.MAU.META.INSTAGRAM.CHECKPOINT_REQUIRED',
        ),
      ], flows: _igFlows);
      await _pump(tester, bridge, ChatNetwork.instagram);

      expect(
        find.textContaining('wants to check you’re human'),
        findsOneWidget,
      );
      expect(find.text('Try another way'), findsOneWidget);
    });

    testWidgets('the browser way says plainly it cannot be done here', (
      tester,
    ) async {
      final bridge = _FakeBridge([
        _input('fi.mau.meta.instagram.credentials', [_passwordField]),
        const LoginStep(
          stepId: 'fi.mau.meta.cookies',
          type: LoginStepType.cookies,
          loginId: 'lg1',
          cookies: LoginCookiesParams(url: 'https://www.instagram.com/'),
        ),
      ]);
      await _pump(tester, bridge, ChatNetwork.instagram, flows: _igFlows);
      await tester.tap(find.text('Try another way'));
      await _settle(tester);
      await tester.tap(find.text('More ways to connect'));
      await _settle(tester);
      await tester.tap(find.text('Sign in on the Instagram website'));
      await _settle(tester);

      expect(find.text('This way needs a web browser'), findsOneWidget);
      expect(find.text('Try another way'), findsOneWidget);
    });
  });

  group('browser sign-in', () {
    const igCookies = LoginStep(
      stepId: 'fi.mau.meta.cookies',
      type: LoginStepType.cookies,
      loginId: 'lg1',
      cookies: LoginCookiesParams(
        url: 'https://www.instagram.com/accounts/login/',
        fieldIds: ['sessionid', 'csrftoken', 'ds_user_id'],
      ),
    );

    testWidgets('the website is offered beside the password', (tester) async {
      final bridge = _FakeBridge(const [])..supportsCookies = true;
      await _pump(
        tester,
        bridge,
        ChatNetwork.instagram,
        flows: _igFlows,
        browserSignIn: (_, _, _) async => null,
      );

      expect(find.text('Sign in with username and password'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      expect(find.text('Sign in on the Instagram website'), findsOneWidget);
      expect(
        find.text('Sign in on Instagram’s own page, right here in Sennit.'),
        findsOneWidget,
      );
    });

    testWidgets('says whose page opens, then hands the session over', (
      tester,
    ) async {
      final bridge = _FakeBridge([igCookies, _complete])
        ..supportsCookies = true;
      LoginCookiesParams? opened;
      await _pump(
        tester,
        bridge,
        ChatNetwork.instagram,
        flows: _igFlows,
        browserSignIn: (_, params, name) async {
          opened = params;
          expect(name, 'Instagram');
          return {'sessionid': 's', 'csrftoken': 'c', 'ds_user_id': '42'};
        },
      );
      await tester.tap(find.text('Sign in on the Instagram website'));
      await _settle(tester);

      expect(find.textContaining('never reads your password'), findsOneWidget);
      expect(opened, isNull, reason: 'the page opens only when asked');
      await tester.tap(find.text('Continue to Instagram'));
      await _settle(tester);

      expect(opened?.url, 'https://www.instagram.com/accounts/login/');
      expect(bridge.calls, contains('submit fi.mau.meta.cookies'));
      expect(bridge.stepTypes.last, 'cookies');
      expect(bridge.bodies.last, {
        'sessionid': 's',
        'csrftoken': 'c',
        'ds_user_id': '42',
      });
      expect(find.text('Instagram is connected'), findsOneWidget);
    });

    testWidgets('closing the page sends nothing and stays put', (tester) async {
      final bridge = _FakeBridge([igCookies])..supportsCookies = true;
      await _pump(
        tester,
        bridge,
        ChatNetwork.instagram,
        flows: _igFlows,
        browserSignIn: (_, _, _) async => null,
      );
      await tester.tap(find.text('Sign in on the Instagram website'));
      await _settle(tester);
      await tester.tap(find.text('Continue to Instagram'));
      await _settle(tester);

      expect(bridge.calls.where((c) => c.startsWith('submit')), isEmpty);
      expect(find.text('Continue to Instagram'), findsOneWidget);
    });

    testWidgets('through the bot chat it still says it needs a browser', (
      tester,
    ) async {
      final bridge = _FakeBridge([
        _input('fi.mau.meta.instagram.credentials', [_passwordField]),
        igCookies,
      ]);
      await _pump(
        tester,
        bridge,
        ChatNetwork.instagram,
        flows: _igFlows,
        browserSignIn: (_, _, _) async => fail('no browser without cookies'),
      );
      await tester.tap(find.text('Try another way'));
      await _settle(tester);
      await tester.tap(find.text('More ways to connect'));
      await _settle(tester);
      await tester.tap(find.text('Sign in on the Instagram website'));
      await _settle(tester);
      expect(find.text('This way needs a web browser'), findsOneWidget);
    });
  });

  group('Google Messages', () {
    testWidgets('offers the QR code the bridge stopped listing', (
      tester,
    ) async {
      final bridge = _FakeBridge(
        [_display('fi.mau.gmessages.qr', 'qr', 'https://support.google.com/x')],
        flows: const [BridgeLoginFlow(id: 'google', name: 'Google account')],
      );
      await _pump(tester, bridge, ChatNetwork.gmessages);

      expect(bridge.calls.take(2), ['flows', 'start qr']);
      expect(find.text('Scan this code with Google Messages'), findsOneWidget);
      expect(
        find.text('Tap your profile picture, then Device pairing'),
        findsOneWidget,
      );
    });

    testWidgets('through the bot chat, only what the bot lists', (
      tester,
    ) async {
      final bridge = _FakeBridge(
        [
          const LoginStep(
            stepId: 'fi.mau.gmessages.google_account',
            type: LoginStepType.cookies,
            loginId: 'lg1',
            cookies: LoginCookiesParams(url: 'https://accounts.google.com/'),
          ),
        ],
        flows: const [BridgeLoginFlow(id: 'google', name: 'Google account')],
      )..acceptsUnlistedFlows = false;
      await _pump(tester, bridge, ChatNetwork.gmessages);

      // The one way left needs a browser, and the screen says so plainly
      // rather than offering a QR the bot would refuse.
      expect(find.text('Scan a QR code'), findsNothing);
      expect(bridge.calls, ['flows', 'start google']);
      expect(find.text('This way needs a web browser'), findsOneWidget);
    });

    testWidgets('the emoji to tap is shown large', (tester) async {
      final bridge = _FakeBridge([
        _display('fi.mau.gmessages.emoji', 'emoji', '🦊'),
      ]);
      await _pump(
        tester,
        bridge,
        ChatNetwork.gmessages,
        flows: const [BridgeLoginFlow(id: 'qr', name: 'QR')],
      );

      expect(find.text('Tap this emoji on your phone'), findsOneWidget);
      expect(find.text('🦊'), findsOneWidget);
    });
  });

  group('Discord', () {
    testWidgets('QR first, the token kept behind the fold', (tester) async {
      final bridge = _FakeBridge([
        _display('chat.sennit.qr', 'qr', 'https://discord.com/ra/abc'),
      ]);
      await _pump(
        tester,
        bridge,
        ChatNetwork.discord,
        flows: const [
          BridgeLoginFlow(id: 'qr', name: 'QR code'),
          BridgeLoginFlow(id: 'token', name: 'Token'),
        ],
      );

      expect(find.text('Scan this code with Discord'), findsOneWidget);
      expect(
        find.text('Scan this code and confirm with Yes, log me in'),
        findsOneWidget,
      );
      await tester.tap(find.text('Try another way'));
      await _settle(tester);
      expect(find.text('Paste a login token'), findsNothing);
      await tester.tap(find.text('More ways to connect'));
      await _settle(tester);
      expect(find.text('Paste a login token'), findsOneWidget);
    });
  });

  group('any network', () {
    testWidgets('a bridge that is down says so, and can be asked again', (
      tester,
    ) async {
      final bridge = _FakeBridge(const [])
        ..flowsError = const BridgeException(
          'The bridge bot did not answer.',
          failure: BridgeFailure.timeout,
        );
      await _pump(tester, bridge, ChatNetwork.whatsapp);

      expect(
        find.text(
          'The WhatsApp service on your server isn’t responding. It may be '
          'restarting — try again in a minute.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Try again'));
      await _settle(tester);
      expect(bridge.calls, ['flows', 'flows']);
    });

    testWidgets('reconnecting names the account to sign in again', (
      tester,
    ) async {
      final bridge = _FakeBridge([
        _display('fi.mau.signal.login.qr', 'qr', 'sgnl://linkdevice?x'),
      ]);
      await _pump(
        tester,
        bridge,
        ChatNetwork.signal,
        flows: const [BridgeLoginFlow(id: 'qr', name: 'QR')],
        reloginId: 'signal-acct',
      );

      expect(find.text('Reconnect Signal'), findsOneWidget);
      expect(bridge.reloginId, 'signal-acct');
    });

    testWidgets('leaving mid-scan cancels the attempt', (tester) async {
      final bridge = _FakeBridge([
        _display('fi.mau.signal.login.qr', 'qr', 'sgnl://linkdevice?x'),
      ]);
      await _pump(
        tester,
        bridge,
        ChatNetwork.signal,
        flows: const [BridgeLoginFlow(id: 'qr', name: 'QR')],
      );

      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(bridge.calls, contains('cancel'));
    });

    testWidgets('a network nobody wrote a guide for still works', (
      tester,
    ) async {
      final bridge = _FakeBridge([_display('x.qr', 'qr', 'pair-me')]);
      await _pump(
        tester,
        bridge,
        ChatNetwork.slack,
        flows: const [BridgeLoginFlow(id: 'qr', name: 'QR')],
      );

      expect(find.text('Scan this code with Slack'), findsOneWidget);
      expect(
        find.text(
          'Open Slack on your phone, find linked devices or Scan QR code, '
          'and scan this code',
        ),
        findsOneWidget,
      );
    });
  });
}
