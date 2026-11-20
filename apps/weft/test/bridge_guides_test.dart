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
    List<String> ids,
  ) => [
    for (final m in loginMethodsFor(network, [
      for (final id in ids) BridgeLoginFlow(id: id, name: id),
    ]))
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

  test('Instagram: password first, browser and app flows advanced', () {
    expect(
      methods(ChatNetwork.instagram, [
        'instagram',
        'instagram-password',
        'android',
      ]),
      [
        ('instagram-password', LoginMethodKind.password, false, false),
        ('android', LoginMethodKind.password, false, true),
        ('instagram', LoginMethodKind.browser, false, true),
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
