import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/bridges/bridge_guides.dart';
import 'package:weft/l10n/gen/app_l10n_en.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_domain/weft_domain.dart';

/// The table that turns a bridge's flow ids into plain choices.
///
/// Data, so tested as data: each network's real flow list, as its bridge
/// reports it, in and the methods a person sees out.
void main() {
  final l10n = AppL10nEn();

  List<(String, LoginMethodKind, bool, bool)> methods(
    ChatNetwork network,
    List<String> ids, {
    bool browser = false,
  }) => [
    for (final m in loginMethodsFor(network, [
      for (final id in ids) BridgeLoginFlow(id: id, name: id),
    ], browser: browser))
      (m.flow.id, m.kind, m.recommended, m.advanced),
  ];

  test('WhatsApp: QR recommended, the phone flow is a pairing code', () {
    expect(methods(ChatNetwork.whatsapp, ['phone', 'qr']), [
      ('qr', LoginMethodKind.qr, true, false),
      ('phone', LoginMethodKind.pairingCode, false, false),
    ]);
  });

  test('Signal: the one QR, nothing to recommend it over', () {
    expect(methods(ChatNetwork.signal, ['qr']), [
      ('qr', LoginMethodKind.qr, false, false),
    ]);
  });

  test('Telegram: manual hidden, bot token advanced', () {
    expect(methods(ChatNetwork.telegram, ['phone', 'qr', 'bot', 'manual']), [
      ('qr', LoginMethodKind.qr, true, false),
      ('phone', LoginMethodKind.phone, false, false),
      ('bot', LoginMethodKind.bot, false, true),
    ]);
  });

  test('Google Messages: QR added back, the Google sign-in advanced', () {
    expect(methods(ChatNetwork.gmessages, ['google']), [
      ('qr', LoginMethodKind.qr, false, false),
      ('google', LoginMethodKind.google, false, true),
    ]);
  });

  test('Google Messages through the chat: no unlisted QR', () {
    expect(
      loginMethodsFor(ChatNetwork.gmessages, const [
        BridgeLoginFlow(id: 'google', name: 'google'),
      ], withUnlisted: false).map((m) => m.flow.id),
      ['google'],
    );
  });

  test('Instagram without a browser: password only, the rest folded', () {
    expect(
      methods(ChatNetwork.instagram, [
        'instagram',
        'instagram-password',
        'android',
      ]),
      [
        ('instagram-password', LoginMethodKind.password, false, false),
        ('instagram', LoginMethodKind.browser, false, true),
        ('android', LoginMethodKind.password, false, true),
      ],
    );
  });

  test('Instagram with a browser: password first, the website beside it', () {
    final offered = loginMethodsFor(ChatNetwork.instagram, const [
      BridgeLoginFlow(id: 'instagram', name: 'Cookies'),
      BridgeLoginFlow(id: 'instagram-password', name: 'Native Web'),
      BridgeLoginFlow(id: 'android', name: 'Native Android'),
    ], browser: true);
    expect(
      [
        for (final m in offered)
          (m.flow.id, m.recommended, m.advanced, m.inAppBrowser),
      ],
      [
        ('instagram-password', true, false, false),
        ('instagram', false, false, true),
        ('android', false, true, false),
      ],
    );
    expect(
      methodSubtitle(l10n, ChatNetwork.instagram, offered[1]),
      l10n.bridgeMethodBrowserSubtitleInApp('Instagram'),
    );
  });

  test('Messenger with a browser: messenger.com is an everyday way', () {
    expect(
      methods(ChatNetwork.messenger, [
        'facebook',
        'messenger',
        'messenger-lite',
        'messenger-lite-android',
      ], browser: true).map((m) => (m.$1, m.$4)),
      [
        ('messenger-lite', false),
        ('messenger', false),
        ('messenger-lite-android', true),
        ('facebook', true),
      ],
    );
  });

  test('Messenger: the Lite password flow leads', () {
    expect(
      methods(ChatNetwork.messenger, [
        'facebook',
        'messenger',
        'messenger-lite',
        'messenger-lite-android',
      ]).first,
      ('messenger-lite', LoginMethodKind.password, false, false),
    );
  });

  test('Discord: QR first, token advanced', () {
    expect(methods(ChatNetwork.discord, ['qr', 'token']), [
      ('qr', LoginMethodKind.qr, false, false),
      ('token', LoginMethodKind.token, false, true),
    ]);
  });

  // The bridge's own order, as mautrix-mattermost lists its flows.
  const mmFlows = ['mm-login-pat', 'mm-login-password', 'mm-login-cookie'];

  test('Mattermost with a browser: its own page leads, tokens folded', () {
    expect(
      methods(ChatNetwork.mattermost, [
        ...mmFlows,
        'mm-login-webview',
      ], browser: true),
      [
        ('mm-login-webview', LoginMethodKind.browser, true, false),
        ('mm-login-password', LoginMethodKind.password, false, false),
        ('mm-login-pat', LoginMethodKind.other, false, true),
        ('mm-login-cookie', LoginMethodKind.other, false, true),
      ],
    );
  });

  test('Mattermost without a browser: the password, the page folded', () {
    expect(methods(ChatNetwork.mattermost, [...mmFlows, 'mm-login-webview']), [
      ('mm-login-webview', LoginMethodKind.browser, false, true),
      ('mm-login-password', LoginMethodKind.password, false, false),
      ('mm-login-pat', LoginMethodKind.other, false, true),
      ('mm-login-cookie', LoginMethodKind.other, false, true),
    ]);
  });

  test('Mattermost: the pasted cookie is not a second browser sign-in', () {
    final offered = loginMethodsFor(ChatNetwork.mattermost, const [
      BridgeLoginFlow(
        id: 'mm-login-pat',
        name: 'Login with Personal Access Token',
      ),
      BridgeLoginFlow(
        id: 'mm-login-cookie',
        name: 'Login with Browser Cookie (SSO)',
      ),
      BridgeLoginFlow(id: 'mm-login-webview', name: 'Browser Window (SSO)'),
    ], browser: true);
    expect(
      [for (final m in offered) methodTitle(l10n, ChatNetwork.mattermost, m)],
      [
        'Sign in on the Mattermost website',
        'Login with Personal Access Token',
        'Login with Browser Cookie (SSO)',
      ],
    );
    expect(offered.where((m) => m.inAppBrowser).map((m) => m.flow.id), [
      'mm-login-webview',
    ]);
  });

  test('a network with only browser sign-ins still shows them', () {
    expect(methods(ChatNetwork.linkedin, ['cookies']), [
      ('cookies', LoginMethodKind.browser, false, true),
    ]);
  });

  test('flows nobody named are classified from their words', () {
    LoginMethodKind kind(String name, [String? description]) => classifyFlow(
      BridgeLoginFlow(id: 'x', name: name, description: description),
    );
    expect(kind('QR code'), LoginMethodKind.qr);
    expect(kind('Cookies'), LoginMethodKind.browser);
    expect(kind('Phone number'), LoginMethodKind.phone);
    expect(kind('Password', 'Log in with username'), LoginMethodKind.password);
    expect(kind('Bot'), LoginMethodKind.bot);
    expect(kind('Something new'), LoginMethodKind.other);
  });

  group('errors', () {
    String say({String? code, BridgeFailure? failure}) => friendlyLoginError(
      l10n,
      ChatNetwork.telegram,
      errorCode: code,
      failure: failure,
    );

    test('expired codes', () {
      expect(
        say(code: 'FI.MAU.WHATSAPP.LOGIN_TIMEOUT'),
        l10n.bridgeErrorExpired,
      );
      expect(
        say(code: 'FI.MAU.TELEGRAM.PHONE_CODE_EXPIRED'),
        l10n.bridgeErrorExpired,
      );
    });

    test('wrong input', () {
      expect(
        say(code: 'FI.MAU.TELEGRAM.PHONE_CODE_INVALID'),
        l10n.bridgeErrorCode,
      );
      expect(
        say(code: 'FI.MAU.WHATSAPP.PHONE_NUMBER_TOO_SHORT'),
        l10n.bridgeErrorPhoneNumber,
      );
      expect(
        say(code: 'FI.MAU.TELEGRAM.INVALID_PASSWORD'),
        l10n.bridgeErrorPassword,
      );
    });

    test('limits and refusals', () {
      expect(
        say(code: 'FI.MAU.TELEGRAM.FLOOD_WAIT'),
        l10n.bridgeErrorRateLimited('Telegram'),
      );
      expect(
        say(code: BridgeCommandClient.errorTooManyLogins),
        l10n.bridgeErrorTooManyLogins('Telegram'),
      );
      expect(
        say(failure: BridgeFailure.rejected),
        l10n.bridgeErrorNotAllowed('Telegram'),
      );
    });

    test('a bridge that is down', () {
      for (final failure in [
        BridgeFailure.unreachable,
        BridgeFailure.unavailable,
        BridgeFailure.timeout,
      ]) {
        expect(say(failure: failure), l10n.bridgeErrorOffline('Telegram'));
      }
    });

    test('anything else gets the generic sentence', () {
      expect(say(code: 'M_UNKNOWN'), l10n.bridgeErrorGeneric('Telegram'));
    });
  });

  test('every guided network has phone steps for its QR', () {
    for (final network in [
      ChatNetwork.whatsapp,
      ChatNetwork.signal,
      ChatNetwork.telegram,
      ChatNetwork.gmessages,
      ChatNetwork.discord,
    ]) {
      expect(phoneSteps(l10n, network, 'qr'), hasLength(greaterThan(1)));
    }
    expect(phoneSteps(l10n, ChatNetwork.slack, 'qr'), hasLength(1));
    expect(phoneSteps(l10n, ChatNetwork.slack, 'nothing'), isNull);
  });
}
