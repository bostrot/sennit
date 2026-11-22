import 'package:flutter/material.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/localisation.dart';

/// What a way of signing in asks of the person, which decides how it is
/// described and drawn. The bridge names its flows for developers — `qr`,
/// `phone`, `messenger-lite-android` — and this is the translation into
/// "scan a code with your phone" and "type your number".
enum LoginMethodKind {
  qr,

  /// Type your number, then type a code the *app* shows into the phone —
  /// WhatsApp's "link with phone number instead".
  pairingCode,

  /// Type your number, then type the code the network sends you.
  phone,

  password,

  /// A Google account sign-in that pairs by tapping an emoji.
  google,

  /// A sign-in that only works inside a web page.
  browser,

  /// A bot account, for developers.
  bot,

  /// A raw session token.
  token,

  other,
}

/// One way of signing in, as this app presents it.
@immutable
class LoginMethod {
  const LoginMethod({
    required this.flow,
    required this.kind,
    this.recommended = false,
    this.advanced = false,
    this.inAppBrowser = false,
  });

  final BridgeLoginFlow flow;
  final LoginMethodKind kind;

  /// Shown first, with a badge.
  final bool recommended;

  /// Kept behind "More ways to connect": real options, but not ones a person
  /// who just wants their chats should have to read past.
  final bool advanced;

  /// A browser sign-in this device can open, inside the app.
  final bool inAppBrowser;

  IconData get icon => switch (kind) {
    LoginMethodKind.qr => Icons.qr_code_2_rounded,
    LoginMethodKind.pairingCode => Icons.pin_outlined,
    LoginMethodKind.phone => Icons.smartphone_rounded,
    LoginMethodKind.password => Icons.password_rounded,
    LoginMethodKind.google => Icons.account_circle_outlined,
    LoginMethodKind.browser => Icons.public_rounded,
    LoginMethodKind.bot => Icons.smart_toy_outlined,
    LoginMethodKind.token => Icons.key_rounded,
    LoginMethodKind.other => Icons.login_rounded,
  };
}

/// How one network's sign-in is presented: which of the bridge's flows lead,
/// which hide, which are added.
///
/// Data, not screens. A network this table does not know still works — every
/// flow is shown with the bridge's own name and description and classified
/// by [classifyFlow] — so a new bridge needs a row here only to read better,
/// never to work at all.
@immutable
class NetworkLoginGuide {
  const NetworkLoginGuide({
    this.order = const [],
    this.advanced = const {},
    this.hidden = const {},
    this.kinds = const {},
    this.extra = const [],
  });

  /// Flow ids in the order to offer them; the first present is recommended.
  final List<String> order;

  /// Flow ids kept behind "More ways to connect".
  final Set<String> advanced;

  /// Flow ids never offered: they exist for operators and debugging.
  final Set<String> hidden;

  /// Flow ids whose kind the name alone would get wrong.
  final Map<String, LoginMethodKind> kinds;

  /// Flows the bridge accepts but does not list.
  ///
  /// Google Messages is the case: its bridge stopped *listing* QR pairing in
  /// favour of a Google account sign-in that needs a browser, but still
  /// accepts `login qr` — and QR is the one of the two this app can do.
  final List<BridgeLoginFlow> extra;
}

const Map<ChatNetwork, NetworkLoginGuide> networkLoginGuides = {
  ChatNetwork.whatsapp: NetworkLoginGuide(
    order: ['qr', 'phone'],
    kinds: {'phone': LoginMethodKind.pairingCode},
  ),
  ChatNetwork.signal: NetworkLoginGuide(order: ['qr']),
  ChatNetwork.telegram: NetworkLoginGuide(
    order: ['qr', 'phone', 'bot'],
    advanced: {'bot'},
    hidden: {'manual'},
    kinds: {'bot': LoginMethodKind.bot},
  ),
  ChatNetwork.gmessages: NetworkLoginGuide(
    order: ['qr', 'google'],
    advanced: {'google'},
    kinds: {'google': LoginMethodKind.google},
    extra: [BridgeLoginFlow(id: 'qr', name: 'QR')],
  ),
  ChatNetwork.discord: NetworkLoginGuide(
    order: ['qr', 'token'],
    advanced: {'token'},
  ),
  ChatNetwork.instagram: NetworkLoginGuide(
    order: ['instagram-password', 'instagram', 'android'],
    advanced: {'android'},
    kinds: {
      'instagram-password': LoginMethodKind.password,
      'android': LoginMethodKind.password,
      'instagram': LoginMethodKind.browser,
    },
  ),
  ChatNetwork.messenger: NetworkLoginGuide(
    order: [
      'messenger-lite',
      'messenger',
      'messenger-lite-android',
      'facebook',
    ],
    advanced: {'messenger-lite-android', 'facebook'},
    kinds: {
      'messenger-lite': LoginMethodKind.password,
      'messenger-lite-android': LoginMethodKind.password,
      'facebook': LoginMethodKind.browser,
      'messenger': LoginMethodKind.browser,
    },
  ),
  // Self-hosted, so most people sign in through their company's SSO: the
  // webview flow covers that and plain passwords alike. The token and pasted
  // cookie flows keep the bridge's own names — as two "paste a token" rows
  // they would read the same — and stay folded away.
  ChatNetwork.mattermost: NetworkLoginGuide(
    order: [
      'mm-login-webview',
      'mm-login-password',
      'mm-login-pat',
      'mm-login-cookie',
    ],
    advanced: {'mm-login-pat', 'mm-login-cookie'},
    kinds: {
      'mm-login-webview': LoginMethodKind.browser,
      'mm-login-password': LoginMethodKind.password,
      'mm-login-pat': LoginMethodKind.other,
      'mm-login-cookie': LoginMethodKind.other,
    },
  ),
};

/// A flow's kind from its id, name and description, for flows no guide names.
LoginMethodKind classifyFlow(BridgeLoginFlow flow) {
  final text = '${flow.id} ${flow.name} ${flow.description ?? ''}'
      .toLowerCase();
  if (text.contains('qr')) return LoginMethodKind.qr;
  if (text.contains('cookie') || text.contains('browser')) {
    return LoginMethodKind.browser;
  }
  if (text.contains('bot')) return LoginMethodKind.bot;
  if (text.contains('token')) return LoginMethodKind.token;
  if (text.contains('pairing code')) return LoginMethodKind.pairingCode;
  if (text.contains('phone') || text.contains('sms')) {
    return LoginMethodKind.phone;
  }
  if (text.contains('password') || text.contains('username')) {
    return LoginMethodKind.password;
  }
  return LoginMethodKind.other;
}

/// The bridge's flows as the methods to offer, best first.
///
/// [withUnlisted] adds the guide's [NetworkLoginGuide.extra] flows, which only
/// a backend that starts unlisted flows can use.
List<LoginMethod> loginMethodsFor(
  ChatNetwork network,
  List<BridgeLoginFlow> flows, {
  bool withUnlisted = true,
  bool browser = false,
}) {
  final guide = networkLoginGuides[network] ?? const NetworkLoginGuide();
  final all = [
    ...flows,
    if (withUnlisted)
      for (final extra in guide.extra)
        if (!flows.any((flow) => flow.id == extra.id)) extra,
  ].where((flow) => !guide.hidden.contains(flow.id)).toList();

  int rank(BridgeLoginFlow flow) {
    final index = guide.order.indexOf(flow.id);
    return index < 0 ? guide.order.length : index;
  }

  // Stable: flows the guide does not rank keep the bridge's order.
  final indexed = all.indexed.toList()
    ..sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });

  final methods = <LoginMethod>[];
  for (final (_, flow) in indexed) {
    final kind = guide.kinds[flow.id] ?? classifyFlow(flow);
    // A browser sign-in is folded away where this device cannot open one:
    // listed beside a QR code, it would be a dead end.
    final advanced =
        guide.advanced.contains(flow.id) ||
        (kind == LoginMethodKind.browser && !browser) ||
        kind == LoginMethodKind.token;
    methods.add(
      LoginMethod(
        flow: flow,
        kind: kind,
        advanced: advanced,
        inAppBrowser: browser && kind == LoginMethodKind.browser,
      ),
    );
  }
  if (methods.every((method) => method.advanced)) {
    return methods;
  }
  final first = methods.indexWhere((method) => !method.advanced);
  methods[first] = LoginMethod(
    flow: methods[first].flow,
    kind: methods[first].kind,
    inAppBrowser: methods[first].inAppBrowser,
    recommended: methods.where((m) => !m.advanced).length > 1,
  );
  return methods;
}

/// What a method is called on the chooser.
String methodTitle(AppL10n l10n, ChatNetwork network, LoginMethod method) =>
    switch (method.kind) {
      LoginMethodKind.qr => l10n.bridgeMethodQrTitle,
      LoginMethodKind.pairingCode => l10n.bridgeMethodPairingCodeTitle,
      LoginMethodKind.phone => l10n.bridgeMethodPhoneTitle,
      LoginMethodKind.password => l10n.bridgeMethodPasswordTitle,
      LoginMethodKind.google => l10n.bridgeMethodGoogleTitle,
      LoginMethodKind.browser => l10n.bridgeMethodBrowserTitle(network.label),
      LoginMethodKind.bot => l10n.bridgeMethodBotTitle,
      LoginMethodKind.token => l10n.bridgeMethodTokenTitle,
      LoginMethodKind.other => method.flow.name,
    };

/// The line under a method's title.
String? methodSubtitle(AppL10n l10n, ChatNetwork network, LoginMethod method) =>
    switch (method.kind) {
      LoginMethodKind.qr => l10n.bridgeMethodQrSubtitle(network.label),
      LoginMethodKind.pairingCode => l10n.bridgeMethodPairingCodeSubtitle(
        network.label,
      ),
      LoginMethodKind.phone => l10n.bridgeMethodPhoneSubtitle(network.label),
      LoginMethodKind.password => l10n.bridgeMethodPasswordSubtitle(
        network.label,
      ),
      LoginMethodKind.google => l10n.bridgeMethodGoogleSubtitle,
      LoginMethodKind.browser =>
        method.inAppBrowser
            ? l10n.bridgeMethodBrowserSubtitleInApp(network.label)
            : l10n.bridgeMethodBrowserSubtitle,
      LoginMethodKind.bot => l10n.bridgeMethodBotSubtitle,
      LoginMethodKind.token => l10n.bridgeMethodTokenSubtitle,
      LoginMethodKind.other => method.flow.description,
    };

/// What to do on the phone while a code is on screen, one line per step.
///
/// Null for a network this table does not know, and the screen then shows
/// the bridge's own instruction instead.
List<String>? phoneSteps(
  AppL10n l10n,
  ChatNetwork network,
  String displayType,
) {
  final type = displayType == 'code' ? 'code' : displayType;
  return switch ((network, type)) {
    (ChatNetwork.whatsapp, 'qr') => [
      l10n.bridgeStepWhatsappOpen,
      l10n.bridgeStepWhatsappLinkedDevices,
      l10n.bridgeStepWhatsappScan,
    ],
    (ChatNetwork.whatsapp, 'code') => [
      l10n.bridgeStepWhatsappOpen,
      l10n.bridgeStepWhatsappLinkedDevices,
      l10n.bridgeStepWhatsappLinkWithPhone,
      l10n.bridgeStepTypeCode,
    ],
    (ChatNetwork.signal, 'qr') => [
      l10n.bridgeStepSignalOpen,
      l10n.bridgeStepSignalLinkedDevices,
      l10n.bridgeStepSignalScan,
    ],
    (ChatNetwork.telegram, 'qr') => [
      l10n.bridgeStepTelegramOpen,
      l10n.bridgeStepTelegramDevices,
      l10n.bridgeStepTelegramScan,
    ],
    (ChatNetwork.gmessages, 'qr') => [
      l10n.bridgeStepGmessagesOpen,
      l10n.bridgeStepGmessagesPairing,
      l10n.bridgeStepGmessagesScan,
    ],
    (ChatNetwork.gmessages, 'emoji') => [
      l10n.bridgeStepGmessagesOpen,
      l10n.bridgeStepGmessagesEmoji,
    ],
    (ChatNetwork.discord, 'qr') => [
      l10n.bridgeStepDiscordOpen,
      l10n.bridgeStepDiscordScan,
      l10n.bridgeStepDiscordConfirm,
    ],
    (_, 'qr') => [l10n.bridgeStepGenericQr(network.label)],
    (_, 'code') => [l10n.bridgeStepGenericCode(network.label)],
    (_, 'emoji') => [l10n.bridgeStepGenericEmoji(network.label)],
    _ => null,
  };
}

/// A line of help under an input field, where the bridge's own is too terse.
String? fieldHint(AppL10n l10n, ChatNetwork network, LoginInputField field) =>
    switch ((network, field.type)) {
      (ChatNetwork.whatsapp, 'phone_number') => l10n.bridgeHintWhatsappPhone,
      (_, 'phone_number') => l10n.bridgeHintPhoneNumber,
      (ChatNetwork.telegram, '2fa_code') => l10n.bridgeHintTelegramCode,
      (ChatNetwork.telegram, 'password') => l10n.bridgeHintTelegramPassword,
      (ChatNetwork.telegram, 'token') => l10n.bridgeHintTelegramBotToken,
      (_, '2fa_code') => l10n.bridgeHintCode(network.label),
      _ => null,
    };

/// A friendly sentence for why an attempt failed.
///
/// Keyed by the bridge's error code first — those are stable and specific —
/// then by what the session itself knows. The bridge's own sentence is never
/// thrown away: the screen keeps it under "Details".
String friendlyLoginError(
  AppL10n l10n,
  ChatNetwork network, {
  String? errorCode,
  BridgeFailure? failure,
  BridgeLoginProblem? problem,
}) {
  final code = errorCode?.toUpperCase() ?? '';
  final name = network.label;
  if (problem == BridgeLoginProblem.timedOut ||
      code.endsWith('LOGIN_TIMEOUT') ||
      code.endsWith('LOGIN_TIMED_OUT') ||
      code.endsWith('PAIR_TIMEOUT') ||
      code.endsWith('PAIR_QR_TIMEOUT') ||
      code.endsWith('PHONE_CODE_EXPIRED') ||
      code.endsWith('DEVICE_LINK_CODE_INVALID')) {
    return l10n.bridgeErrorExpired;
  }
  if (code.contains('RATE_LIMIT') || code.contains('FLOOD')) {
    return l10n.bridgeErrorRateLimited(name);
  }
  if (code.contains('PHONE_NUMBER')) return l10n.bridgeErrorPhoneNumber;
  if (code.endsWith('PHONE_CODE_INVALID')) return l10n.bridgeErrorCode;
  if (code.endsWith('INVALID_PASSWORD')) return l10n.bridgeErrorPassword;
  if (code.endsWith('DEVICE_LIMIT_REACHED')) {
    return l10n.bridgeErrorDeviceLimit(name);
  }
  if (code.endsWith('PAIR_INCORRECT_EMOJI')) return l10n.bridgeErrorWrongEmoji;
  if (code.endsWith('PAIR_NO_DEVICES') ||
      code.endsWith('PAIR_PHONE_NOT_FOUND') ||
      code.endsWith('PAIR_PHONE_INACTIVE') ||
      code.endsWith('PAIR_INIT_TIMEOUT')) {
    return l10n.bridgeErrorNoPhone(name);
  }
  if (code == BridgeCommandClient.errorTooManyLogins ||
      code == 'FI.MAU.BRIDGE.TOO_MANY_LOGINS') {
    return l10n.bridgeErrorTooManyLogins(name);
  }
  if (code == BridgeCommandClient.errorAlreadyLoggedIn) {
    return l10n.bridgeErrorAlreadyConnected(name);
  }
  if (code == BridgeCommandClient.errorNeedsBrowser) {
    return l10n.bridgeFlowCookiesBody;
  }
  if (code.contains('CAPTCHA') || code.contains('CHECKPOINT')) {
    return l10n.bridgeErrorCaptcha(name);
  }
  if (code == BridgeCommandClient.errorNoPermission ||
      failure == BridgeFailure.rejected) {
    return l10n.bridgeErrorNotAllowed(name);
  }
  if (failure == BridgeFailure.unreachable ||
      failure == BridgeFailure.unavailable ||
      failure == BridgeFailure.timeout ||
      failure == BridgeFailure.notFound) {
    return l10n.bridgeErrorOffline(name);
  }
  if (problem == BridgeLoginProblem.unsupportedStep) {
    return l10n.bridgeErrorUnsupported(name);
  }
  return l10n.bridgeErrorGeneric(name);
}
