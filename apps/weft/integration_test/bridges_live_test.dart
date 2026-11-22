import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/bridges/bridge_login_flow.dart';
import 'package:weft/features/bridges/bridges_screen.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// The Messengers screen against real bridges, photographed step by step.
///
///   cd apps/weft
///   flutter test integration_test/bridges_live_test.dart -d macos \
///     --dart-define=WEFT_LIVE_HOMESERVER=matrix.example.org \
///     --dart-define=WEFT_LIVE_USER=someone \
///     --dart-define=WEFT_LIVE_PASSWORD=… \
///     [--dart-define=WEFT_LIVE_ENDPOINTS=none | whatsapp=http://localhost:29318/_matrix/provision,…]
///     [--dart-define=WEFT_LIVE_MATTERMOST=mattermost.example.org]
///
/// Without `WEFT_LIVE_ENDPOINTS` the app finds the bridges the way it does for
/// everyone, in the server's well-known; `none` forces every network through
/// its bot's chat; a list names the provisioning APIs by hand.
///
/// Skipped without credentials, so the integration glob never runs it. It
/// stops at every step that needs a real phone — a QR to scan, a code to
/// receive — photographs it and cancels: what happens after the scan is the
/// bridge's business, and an unattended run cannot do it.
///
/// Screenshots land in the app's temporary directory (the sandbox container
/// on macOS); the path is printed.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  const homeserver = String.fromEnvironment('WEFT_LIVE_HOMESERVER');
  const user = String.fromEnvironment('WEFT_LIVE_USER');
  const password = String.fromEnvironment('WEFT_LIVE_PASSWORD');
  const endpointsDefine = String.fromEnvironment('WEFT_LIVE_ENDPOINTS');
  const only = String.fromEnvironment('WEFT_LIVE_ONLY');
  const pass = String.fromEnvironment('WEFT_LIVE_PASS', defaultValue: 'chat');
  const mattermostServer = String.fromEnvironment('WEFT_LIVE_MATTERMOST');

  final endpoints = <String, Uri>{
    for (final entry in endpointsDefine.split(','))
      if (entry.contains('='))
        entry.split('=').first: Uri.parse(entry.split('=').skip(1).join('=')),
  };

  final boundary = GlobalKey();
  late Directory shots;

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 300));
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(p.join(shots.path, '$pass-$name.png'));
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    debugPrint('SHOT ${file.path}');
  }

  Future<void> until(
    WidgetTester tester,
    Finder finder, {
    Duration within = const Duration(seconds: 60),
  }) async {
    final end = DateTime.now().add(within);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await shot(tester, 'timeout-${DateTime.now().millisecondsSinceEpoch}');
    throw TestFailure('Timed out waiting for $finder');
  }

  Future<void> wait(WidgetTester tester, Duration duration) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Finder rowButton(String network, String label) => find.descendant(
    of: find.ancestor(of: find.text(network), matching: find.byType(Row)).first,
    matching: find.text(label),
  );

  testWidgets('live bridges', (tester) async {
    if (user.isEmpty) {
      markTestSkipped('no WEFT_LIVE_USER');
      return;
    }
    shots = Directory(
      p.join((await getTemporaryDirectory()).path, 'bridge-shots'),
    )..createSync(recursive: true);

    final dir = Directory.systemTemp.createTempSync('weft-live-');
    final session = WeftMatrixSession(
      clientName: 'weft-live',
      deviceDisplayName: 'Sennit bridge live test',
      databaseOverride: () async => sdk.MatrixSdkDatabase.init(
        'weft-live',
        database: await openWeftSqfliteDatabase(p.join(dir.path, 'db.sqlite')),
      ),
    );
    await session.initialize();
    await session.checkHomeserver(homeserver);
    await session.loginWithPassword(username: user, password: password);
    await session.client.roomsLoading;
    await session.client.oneShotSync();

    session.client.onTimelineEvent.stream.listen((event) {
      debugPrint(
        'EVENT ${event.senderId} ${event.type} ${event.messageType} '
        '${event.body.replaceAll('\n', ' | ')}',
      );
    });
    final stores = WeftStores.inMemory();
    tester.view.physicalSize = const Size(900, 1700);
    tester.view.devicePixelRatio = 2;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storesProvider.overrideWithValue(stores),
          matrixSessionProvider.overrideWithValue(session),
          if (endpointsDefine.isNotEmpty)
            bridgeEndpointsProvider.overrideWith((ref) async => endpoints),
        ],
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(),
            home: const BridgesScreen(),
          ),
        ),
      ),
    );
    await until(
      tester,
      find.text('WhatsApp'),
      within: const Duration(seconds: 30),
    );
    await wait(tester, const Duration(seconds: 25));
    await shot(tester, '00-messengers');

    Future<void> back() async {
      final cancel = find.widgetWithText(TextButton, 'Cancel');
      if (cancel.evaluate().isNotEmpty) {
        await tester.tap(cancel.first);
      } else {
        await tester.tap(find.byType(BackButton).first);
      }
      await wait(tester, const Duration(seconds: 3));
    }

    Future<void> connect(String network) async {
      final button = rowButton(network, 'Connect');
      if (button.evaluate().isEmpty) {
        await tester.tap(rowButton(network, 'Reconnect'));
      } else {
        await tester.tap(button);
      }
      await wait(tester, const Duration(seconds: 1));
    }

    bool want(String key) => only.isEmpty || only.split(',').contains(key);

    // WhatsApp: QR, then the pairing code up to the phone number.
    if (want('whatsapp')) {
      await connect('WhatsApp');
      await until(tester, find.text('How do you want to connect WhatsApp?'));
      await shot(tester, 'whatsapp-1-choose');
      await tester.tap(find.text('Scan a QR code'));
      await until(tester, find.text('Scan this code with WhatsApp'));
      await shot(tester, 'whatsapp-2-qr');
      await tester.tap(find.text('Try another way'));
      await until(tester, find.text('Use a code instead of scanning'));
      await tester.tap(find.text('Use a code instead of scanning'));
      await until(tester, find.text('What’s your phone number?'));
      await shot(tester, 'whatsapp-3-phone');
      await tester.enterText(find.byType(TextField).first, '0151');
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await wait(tester, const Duration(seconds: 1));
      await shot(tester, 'whatsapp-4-phone-invalid');
      await back();
      await wait(tester, const Duration(seconds: 3));
    }

    if (want('signal')) {
      await connect('Signal');
      await until(tester, find.text('Scan this code with Signal'));
      await shot(tester, 'signal-1-qr');
      await back();
    }

    if (want('telegram')) {
      await connect('Telegram');
      await until(tester, find.text('How do you want to connect Telegram?'));
      await shot(tester, 'telegram-1-choose');
      await tester.tap(find.text('Scan a QR code'));
      await until(tester, find.text('Scan this code with Telegram'));
      await shot(tester, 'telegram-2-qr');
      await tester.tap(find.text('Try another way'));
      await until(tester, find.text('Sign in with your phone number'));
      await tester.tap(find.text('Sign in with your phone number'));
      await until(tester, find.text('What’s your phone number?'));
      await shot(tester, 'telegram-3-phone');
      await back();
    }

    if (want('gmessages')) {
      await connect('Google Messages');
      // Through the API the unlisted QR is offered; through the chat only
      // the Google account sign-in, which needs a browser.
      await until(
        tester,
        endpointsDefine != 'none' &&
                (endpointsDefine.isEmpty || endpoints.containsKey('gmessages'))
            ? find.text('Scan this code with Google Messages')
            : find.text('This way needs a web browser'),
        within: const Duration(seconds: 90),
      );
      await shot(tester, 'gmessages-1');
      await back();
    }

    if (want('instagram')) {
      await connect('Instagram');
      await until(
        tester,
        find.text('How do you want to connect Instagram?'),
        within: const Duration(seconds: 60),
      );
      await shot(tester, 'instagram-1-choose');
      await tester.tap(find.text('Sign in with username and password'));
      await until(tester, find.text('Sign in to Instagram').last);
      await until(tester, find.text('Email or username'));
      await shot(tester, 'instagram-2-password');
      await tester.tap(find.text('Try another way'));
      await until(tester, find.text('Sign in on the Instagram website'));
      await tester.tap(find.text('Sign in on the Instagram website'));
      await until(tester, find.text('Continue to Instagram'));
      await shot(tester, 'instagram-3-browser-intro');
      await tester.tap(find.text('Continue to Instagram'));
      // The page itself is a native web view, which a Flutter screenshot
      // draws blank: the run says READY and holds, so the window can be
      // captured from outside.
      await wait(tester, const Duration(seconds: 12));
      debugPrint('READY instagram-webview');
      // What proves the page is instagram.com, loaded and live: the cookies
      // its login page sets, read from the same native store the sign-in
      // harvests from. Names only — never values.
      final store = CookieManager.instance();
      final open = await store.getCookies(
        url: WebUri('https://www.instagram.com/'),
      );
      debugPrint('WEBVIEW cookies while open: ${open.map((c) => c.name)}');
      expect(open, isNotEmpty, reason: 'instagram.com did not load');
      await wait(tester, const Duration(seconds: 2));
      await tester.tap(find.byType(CloseButton).first);
      await wait(tester, const Duration(seconds: 3));
      final left = await store.getCookies(
        url: WebUri('https://www.instagram.com/'),
      );
      debugPrint('WEBVIEW cookies after close: ${left.map((c) => c.name)}');
      expect(left, isEmpty, reason: 'the page left a session behind');
      await shot(tester, 'instagram-4-after-close');
      await back();
    }

    // Mattermost is self-hosted: the server is asked for first, then its own
    // login page opens, which is where an unattended run has to stop.
    if (want('mattermost') && mattermostServer.isNotEmpty) {
      await connect('Mattermost');
      await until(
        tester,
        find.text('How do you want to connect Mattermost?'),
        within: const Duration(seconds: 60),
      );
      await shot(tester, 'mattermost-1-choose');
      await tester.tap(find.text('Sign in on the Mattermost website'));
      await until(tester, find.byType(TextField));
      await shot(tester, 'mattermost-2-server');
      await tester.enterText(find.byType(TextField).first, mattermostServer);
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await until(tester, find.text('Continue to Mattermost'));
      await shot(tester, 'mattermost-3-browser-intro');
      await tester.tap(find.text('Continue to Mattermost'));
      await wait(tester, const Duration(seconds: 12));
      debugPrint('READY mattermost-webview');
      final host = Uri.parse(
        mattermostServer.contains('://')
            ? mattermostServer
            : 'https://$mattermostServer',
      ).host;
      final store = CookieManager.instance();
      // Mattermost's login page sets no cookie of its own, so this only
      // shows what is there; the window capture is the proof it loaded.
      final open = await store.getCookies(url: WebUri('https://$host/'));
      debugPrint('WEBVIEW cookies while open: ${open.map((c) => c.name)}');
      await tester.tap(find.byType(CloseButton).first);
      await wait(tester, const Duration(seconds: 3));
      final left = await store.getCookies(url: WebUri('https://$host/'));
      debugPrint('WEBVIEW cookies after close: ${left.map((c) => c.name)}');
      expect(left, isEmpty, reason: 'the page left a session behind');
      await shot(tester, 'mattermost-4-after-close');
      await back();
    }

    if (want('discord')) {
      await connect('Discord');
      await until(
        tester,
        find.text('Scan this code with Discord'),
        within: const Duration(seconds: 90),
      );
      await shot(tester, 'discord-1-qr');
      await tester.tap(find.text('Try another way'));
      await until(tester, find.text('More ways to connect'));
      await tester.tap(find.text('More ways to connect'));
      await wait(tester, const Duration(seconds: 1));
      await tester.tap(find.text('Paste a login token'));
      await until(tester, find.text('Paste your token'));
      await shot(tester, 'discord-2-token');
      await back();
    }

    await wait(tester, const Duration(seconds: 3));
    await tester.tap(find.byTooltip('Refresh'));
    await wait(tester, const Duration(seconds: 25));
    await shot(tester, '99-messengers-after');

    // Signs this run's device out again, so repeated runs do not pile up
    // sessions on the test account.
    await session.logout();
    await session.dispose();
  }, timeout: const Timeout(Duration(minutes: 20)));

  // The networks no server here runs, and the states no throwaway account
  // can reach, drawn from scripted bridges by the same real rasteriser.
  testWidgets('scripted bridges', (tester) async {
    if (!const bool.fromEnvironment('WEFT_LIVE_MOCK')) {
      markTestSkipped('no WEFT_LIVE_MOCK');
      return;
    }
    shots = Directory(
      p.join((await getTemporaryDirectory()).path, 'bridge-shots'),
    )..createSync(recursive: true);
    tester.view.physicalSize = const Size(900, 1700);
    tester.view.devicePixelRatio = 2;

    /// Pumps [home]; with [states], the Messengers screen's bridges answer
    /// from those scripts.
    Future<void> show(
      Widget home, {
      Map<ChatNetwork, BridgeLoginBackend>? states,
    }) => tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          storesProvider.overrideWithValue(WeftStores.inMemory()),
          if (states != null) ...[
            detectedBridgesProvider.overrideWithValue([
              for (final network in states.keys)
                DetectedBridge(network: network, botUserId: '@bot:example.org'),
            ]),
            bridgeEndpointsProvider.overrideWith((ref) async => const {}),
            bridgeBackendFactoryProvider.overrideWithValue(
              (network, {botUserId, provisioningUrl}) => states[network],
            ),
          ],
        ],
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            // Fresh each time: [boundary] carries the subtree across pumps,
            // and a navigator kept that way keeps its first route.
            key: UniqueKey(),
            debugShowCheckedModeBanner: false,
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(),
            home: home,
          ),
        ),
      ),
    );

    const igFlows = [
      BridgeLoginFlow(id: 'instagram', name: 'instagram.com'),
      BridgeLoginFlow(id: 'instagram-password', name: 'Instagram password'),
      BridgeLoginFlow(id: 'android', name: 'Instagram Android'),
    ];
    const code = LoginInputField(id: 'code', type: '2fa_code', name: 'Code');

    // Instagram: username and password, then the 2FA code, then done.
    final instagram = _Scripted([
      const LoginStep(
        stepId: 'fi.mau.meta.instagram.credentials',
        type: LoginStepType.userInput,
        loginId: 'lg',
        fields: [
          LoginInputField(id: 'username', type: 'username', name: 'Username'),
          LoginInputField(id: 'password', type: 'password', name: 'Password'),
        ],
      ),
      const LoginStep(
        stepId: 'fi.mau.meta.instagram.web_two_factor',
        type: LoginStepType.userInput,
        loginId: 'lg',
        fields: [code],
      ),
      const LoginStep(
        stepId: 'done',
        type: LoginStepType.complete,
        loginId: 'lg',
      ),
    ], igFlows);
    await show(
      BridgeLoginFlowScreen(client: instagram, network: ChatNetwork.instagram),
    );
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'instagram-1-credentials');
    await tester.enterText(find.byType(TextField).at(0), 'someone');
    await tester.enterText(find.byType(TextField).at(1), 'secret');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'instagram-2-code');
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'instagram-3-connected');

    // Instagram asking for a checkpoint the app cannot show.
    await show(
      BridgeLoginFlowScreen(
        client: _Scripted([
          const BridgeException(
            'checkpoint_required',
            errorCode: 'FI.MAU.META.INSTAGRAM.CHECKPOINT_REQUIRED',
          ),
        ], igFlows),
        network: ChatNetwork.instagram,
      ),
    );
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'instagram-4-checkpoint');

    // The browser-only way, picked from the fold.
    await show(
      BridgeLoginFlowScreen(
        client: _Scripted([
          const LoginStep(
            stepId: 'fi.mau.meta.instagram.credentials',
            type: LoginStepType.userInput,
            loginId: 'lg',
            fields: [code],
          ),
          const LoginStep(
            stepId: 'fi.mau.meta.cookies',
            type: LoginStepType.cookies,
            loginId: 'lg',
            cookies: LoginCookiesParams(url: 'https://www.instagram.com/'),
          ),
        ], igFlows),
        network: ChatNetwork.instagram,
      ),
    );
    await wait(tester, const Duration(seconds: 1));
    await tester.tap(find.text('Try another way'));
    await wait(tester, const Duration(seconds: 1));
    await tester.tap(find.text('More ways to connect'));
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'instagram-5-more-ways');
    await tester.tap(find.text('Sign in on the Instagram website'));
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'instagram-6-browser');

    // Telegram's two-step password, after the code.
    await show(
      BridgeLoginFlowScreen(
        client: _Scripted(
          [
            const LoginStep(
              stepId: 'fi.mau.telegram.login.password',
              type: LoginStepType.userInput,
              loginId: 'lg',
              fields: [
                LoginInputField(
                  id: 'password',
                  type: 'password',
                  name: 'Password',
                ),
              ],
            ),
          ],
          const [BridgeLoginFlow(id: 'phone', name: 'Phone')],
        ),
        network: ChatNetwork.telegram,
      ),
    );
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'telegram-4-password');

    // A wrong Telegram code, as the bridge words it.
    await show(
      BridgeLoginFlowScreen(
        client: _Scripted(
          [
            const LoginStep(
              stepId: 'fi.mau.telegram.login.code',
              type: LoginStepType.userInput,
              loginId: 'lg',
              instructions: 'Incorrect code, please try again.',
              fields: [code],
            ),
          ],
          const [BridgeLoginFlow(id: 'phone', name: 'Phone')],
        ),
        network: ChatNetwork.telegram,
      ),
    );
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'telegram-5-wrong-code');

    // WhatsApp's pairing code on screen.
    await show(
      BridgeLoginFlowScreen(
        client: _Scripted(
          [
            const LoginStep(
              stepId: 'fi.mau.whatsapp.login.code',
              type: LoginStepType.displayAndWait,
              loginId: 'lg',
              displayType: 'code',
              displayData: 'K7Q2-9XWD',
            ),
          ],
          const [BridgeLoginFlow(id: 'phone', name: 'Pairing code')],
        ),
        network: ChatNetwork.whatsapp,
      ),
    );
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'whatsapp-5-pairing-code');

    // A Signal account with no room left for another linked device.
    await show(
      BridgeLoginFlowScreen(
        client: _Scripted(
          [
            const BridgeException(
              'You have reached the maximum number of linked devices.',
              errorCode: 'FI.MAU.SIGNAL.DEVICE_LIMIT_REACHED',
            ),
          ],
          const [BridgeLoginFlow(id: 'qr', name: 'QR')],
        ),
        network: ChatNetwork.signal,
      ),
    );
    await wait(tester, const Duration(seconds: 1));
    await shot(tester, 'signal-2-device-limit');

    // The Messengers screen with every state a row can be in.
    final states = <ChatNetwork, BridgeLoginBackend>{
      ChatNetwork.whatsapp: _Scripted(
        const [],
        const [],
        logins: const [
          BridgeLogin(
            id: '1',
            name: '+49 151 12345678',
            state: BridgeLoginState.connected,
          ),
        ],
      ),
      ChatNetwork.signal: _Scripted(
        const [],
        const [],
        logins: const [
          BridgeLogin(
            id: '2',
            name: '+49 170 1234567',
            state: BridgeLoginState.badCredentials,
          ),
        ],
      ),
      ChatNetwork.telegram: _Scripted(
        const [],
        const [],
        logins: const [
          BridgeLogin(
            id: '3',
            name: 'Anna',
            state: BridgeLoginState.transientDisconnect,
          ),
        ],
      ),
      ChatNetwork.instagram: _Scripted(const [], const []),
      ChatNetwork.discord: _Scripted(
        const [],
        const [],
        whoamiError: const BridgeException(
          'The bridge bot did not answer.',
          failure: BridgeFailure.timeout,
        ),
      ),
    };
    await show(const BridgesScreen(), states: states);
    await wait(tester, const Duration(seconds: 2));
    await shot(tester, 'messengers-states');
  });
}

/// A bridge that plays back a fixed script, for [main]'s scripted pass.
class _Scripted implements BridgeLoginBackend {
  _Scripted(
    this.script,
    this.flows, {
    this.logins = const [],
    this.whoamiError,
  });

  final List<Object> script;
  final List<BridgeLoginFlow> flows;
  final List<BridgeLogin> logins;
  final BridgeException? whoamiError;
  int _next = 0;

  Future<LoginStep> _take() {
    if (_next >= script.length) return Completer<LoginStep>().future;
    final entry = script[_next++];
    if (entry is BridgeException) return Future.error(entry);
    return Future.value(entry as LoginStep);
  }

  @override
  Future<BridgeWhoami> whoami() async {
    if (whoamiError != null) throw whoamiError!;
    return BridgeWhoami(logins: logins);
  }

  @override
  Future<List<BridgeLoginFlow>> loginFlows() async => flows;

  @override
  Future<LoginStep> startLogin(String flowId, {String? reloginId}) => _take();

  @override
  Future<LoginStep> submitStep({
    required String loginId,
    required String stepId,
    required String stepType,
    Map<String, Object?>? body,
  }) => _take();

  @override
  Future<LoginStep> waitForStep({
    required String loginId,
    required String stepId,
  }) => _take();

  @override
  Future<void> cancelLogin(String loginId) async {}

  @override
  Future<void> logout(String loginId) async {}

  @override
  bool get supportsCookies => false;

  @override
  bool get acceptsUnlistedFlows => true;

  @override
  void dispose() {}
}
