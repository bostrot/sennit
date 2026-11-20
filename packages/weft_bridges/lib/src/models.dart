import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// A bridge the user runs, as Weft knows it.
@immutable
class BridgeInfo {
  const BridgeInfo({
    required this.id,
    required this.network,
    required this.provisioningUrl,
    this.displayName,
    this.botUserId,
    this.logins = const [],
    this.reachable = true,
  });

  /// Stable local id, usually the bridge's own name.
  final String id;

  final ChatNetwork network;

  /// Base URL of the provisioning API, e.g.
  /// `https://bridge.example.org/_matrix/provision`.
  final Uri provisioningUrl;

  final String? displayName;

  /// The bridge bot, used by the admin-room fallback and for discovery.
  final String? botUserId;

  /// Remote accounts currently logged in through this bridge.
  final List<BridgeLogin> logins;

  /// Whether the last probe reached it. False renders as "offline" rather than
  /// silently showing zero logins, which would look like being signed out.
  final bool reachable;

  String get label => displayName ?? network.label;

  bool get hasLogin => logins.any((l) => l.isActive);

  BridgeInfo copyWith({
    List<BridgeLogin>? logins,
    bool? reachable,
    String? displayName,
    String? botUserId,
  }) {
    return BridgeInfo(
      id: id,
      network: network,
      provisioningUrl: provisioningUrl,
      displayName: displayName ?? this.displayName,
      botUserId: botUserId ?? this.botUserId,
      logins: logins ?? this.logins,
      reachable: reachable ?? this.reachable,
    );
  }

  @override
  bool operator ==(Object other) => other is BridgeInfo && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// State of one remote account on a bridge.
enum BridgeLoginState {
  connected,
  connecting,

  /// Reachable but not currently receiving — usually a transient disconnect.
  transientDisconnect,

  /// Needs the user to log in again.
  badCredentials,

  unknown;

  static BridgeLoginState fromWire(String? raw) => switch (raw?.toUpperCase()) {
    'CONNECTED' => BridgeLoginState.connected,
    'CONNECTING' => BridgeLoginState.connecting,
    'TRANSIENT_DISCONNECT' => BridgeLoginState.transientDisconnect,
    'BAD_CREDENTIALS' || 'LOGGED_OUT' => BridgeLoginState.badCredentials,
    // An unknown error with the bridge still holding the session: it retries
    // on its own, so it reads as a hiccup rather than a sign-out.
    'UNKNOWN_ERROR' => BridgeLoginState.transientDisconnect,
    'BACKFILLING' || 'RUNNING' => BridgeLoginState.connected,
    _ => BridgeLoginState.unknown,
  };

  bool get needsAttention =>
      this == BridgeLoginState.badCredentials ||
      this == BridgeLoginState.unknown;
}

/// One remote account bridged into Matrix.
@immutable
class BridgeLogin {
  const BridgeLogin({
    required this.id,
    required this.state,
    this.name,
    this.remoteProfileName,
    this.errorMessage,
  });

  final String id;
  final BridgeLoginState state;

  /// Display name of the remote account — the phone number or handle.
  final String? name;
  final String? remoteProfileName;

  /// Why the bridge is unhappy, when it says.
  final String? errorMessage;

  bool get isActive =>
      state == BridgeLoginState.connected ||
      state == BridgeLoginState.connecting ||
      state == BridgeLoginState.transientDisconnect;

  String get label => remoteProfileName ?? name ?? id;

  /// One entry of `/v3/whoami`'s `logins`.
  ///
  /// The state moved from top-level `state_event` into a `state` object in
  /// bridgev2; both shapes are still served, and a bridge new enough to drop
  /// the old one must not read as "unknown" — which asks the user to sign in
  /// again for no reason.
  factory BridgeLogin.fromJson(Map<Object?, Object?> json) {
    final state = json['state'];
    final stateMap = state is Map ? state : const <Object?, Object?>{};
    final rawState =
        stateMap['state_event'] as String? ??
        json['state_event'] as String? ??
        (state is String ? state : null);
    final profile = json['profile'];
    final error =
        json['error'] as String? ??
        stateMap['message'] as String? ??
        json['state_reason'] as String?;
    return BridgeLogin(
      id: json['id'] as String? ?? '',
      state: BridgeLoginState.fromWire(rawState),
      name: json['name'] as String?,
      remoteProfileName: profile is Map
          ? (profile['name'] as String?)?.nonEmpty ??
                (profile['username'] as String?)?.nonEmpty ??
                (profile['phone'] as String?)?.nonEmpty
          : null,
      errorMessage: error?.nonEmpty,
    );
  }
}

extension on String {
  String? get nonEmpty => trim().isEmpty ? null : this;
}

/// One way of logging in — QR, phone number, bot token…
///
/// Bridges advertise several; Google Messages offers QR *and* a Google account
/// flow, for instance, so the UI has to let the user pick rather than assuming.
@immutable
class BridgeLoginFlow {
  const BridgeLoginFlow({
    required this.id,
    required this.name,
    this.description,
  });

  final String id;
  final String name;
  final String? description;
}

/// What a login step is asking for.
enum LoginStepType {
  /// Collect typed values from the user.
  userInput,

  /// Show something (QR code, emoji) and wait for the remote side.
  displayAndWait,

  /// Extract cookies via an embedded browser.
  cookies,

  /// Done.
  complete,

  /// A type this build does not know about.
  unsupported;

  static LoginStepType fromWire(String? raw) => switch (raw) {
    'user_input' => LoginStepType.userInput,
    'display_and_wait' => LoginStepType.displayAndWait,
    'cookies' => LoginStepType.cookies,
    'complete' => LoginStepType.complete,
    _ => LoginStepType.unsupported,
  };
}

/// One field in a [LoginStepType.userInput] step.
@immutable
class LoginInputField {
  const LoginInputField({
    required this.id,
    required this.type,
    required this.name,
    this.description,
    this.pattern,
    this.defaultValue,
    this.placeholder,
    this.options = const [],
    this.optional = false,
    this.minLength = 0,
    this.maxLength = 0,
  });

  factory LoginInputField.fromJson(Map<Object?, Object?> json) {
    final options = json['options'];
    return LoginInputField(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'text',
      name: json['name'] as String? ?? json['id'] as String? ?? 'Value',
      description: (json['description'] as String?)?.nonEmpty,
      pattern: (json['pattern'] as String?)?.nonEmpty,
      defaultValue: (json['default_value'] as String?)?.nonEmpty,
      placeholder: (json['placeholder'] as String?)?.nonEmpty,
      options: options is List
          ? options.whereType<String>().toList(growable: false)
          : const [],
      optional: json['optional'] == true,
      minLength: (json['min_length'] as num?)?.toInt() ?? 0,
      maxLength: (json['max_length'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;

  /// Bridge-declared semantic type: `phone_number`, `email`, `password`,
  /// `token`, `username`, `2fa_code`, `select`, `url`, `domain`,
  /// `captcha_code`…
  final String type;

  final String name;
  final String? description;

  /// Validation regex the bridge supplies, applied before submitting so a
  /// typo is caught locally instead of costing a round trip.
  final String? pattern;

  /// What the field starts with, when the bridge suggests something.
  final String? defaultValue;

  /// Hint text for an empty field.
  final String? placeholder;

  /// For a `select` field, the only values the bridge accepts.
  final List<String> options;

  /// Whether the field may be left empty.
  final bool optional;

  /// Length bounds as a hint; zero means no bound.
  final int minLength;
  final int maxLength;

  bool get isSecret =>
      type == 'password' || type == 'token' || type.contains('2fa');

  bool get isSelect => type == 'select' && options.isNotEmpty;

  /// Best keyboard for this field.
  String get keyboardHint => switch (type) {
    'phone_number' => 'phone',
    'email' => 'email',
    '2fa_code' => 'number',
    'url' || 'domain' => 'url',
    _ => 'text',
  };

  /// Whether [value] satisfies [pattern]. Accepts anything when the bridge
  /// gave no pattern or gave one that does not compile.
  bool validate(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return optional;
    if (isSelect) return options.contains(trimmed);
    if (minLength > 0 && trimmed.length < minLength) return false;
    if (maxLength > 0 && trimmed.length > maxLength) return false;
    if (pattern == null || pattern!.isEmpty) return true;
    try {
      return RegExp(pattern!).hasMatch(_normalised(trimmed));
    } on FormatException {
      return true;
    }
  }

  /// What the bridge would see after its own clean-up.
  ///
  /// bridgev2 strips spaces, dashes and brackets out of a phone number before
  /// matching it, so `+49 170 123-4567` is valid there — and must be valid
  /// here, or the field refuses a number the bridge would have taken.
  String _normalised(String value) => type == 'phone_number'
      ? value.replaceAll(RegExp(r'[\s()\-]'), '')
      : value;

  /// [value] as it should be submitted.
  String clean(String value) => _normalised(value.trim());
}

/// What a [LoginStepType.cookies] step wants collected from a web session.
@immutable
class LoginCookiesParams {
  const LoginCookiesParams({
    required this.url,
    this.userAgent,
    this.fieldIds = const [],
    this.fields = const [],
    this.extractJs,
    this.waitForUrlPattern,
  });

  factory LoginCookiesParams.fromJson(Map<Object?, Object?> json) {
    final fields = [
      if (json['fields'] is List)
        for (final field in (json['fields'] as List).whereType<Map>())
          if (field['id'] is String) LoginCookieField.fromJson(field),
    ];
    return LoginCookiesParams(
      url: json['url'] as String? ?? '',
      userAgent: (json['user_agent'] as String?)?.nonEmpty,
      fieldIds: [for (final field in fields) field.id],
      fields: fields,
      extractJs: (json['extract_js'] as String?)?.nonEmpty,
      waitForUrlPattern: (json['wait_for_url_pattern'] as String?)?.nonEmpty,
    );
  }

  /// The page to sign in on.
  final String url;
  final String? userAgent;
  final List<String> fieldIds;

  /// What to read out of the browser once the person is signed in.
  final List<LoginCookieField> fields;
  final String? extractJs;

  /// The address the page reaches once sign-in is done.
  final String? waitForUrlPattern;

  /// Whether [url] is the page that means sign-in is done.
  ///
  /// With no pattern from the bridge, never: the browser then decides by
  /// [collect] succeeding instead.
  bool isDone(String url) {
    final pattern = waitForUrlPattern;
    if (pattern == null) return false;
    return RegExp(pattern).hasMatch(url);
  }

  /// The values to submit, read from what the browser holds — or null while
  /// a required one is still missing.
  ///
  /// [cookies] is every cookie the browser has for the sign-in site, by name;
  /// [localStorage] the page's local storage. A field is taken from the first
  /// of its sources that has a value. Sources this app cannot read (request
  /// headers and bodies, which need the page's network traffic) are skipped,
  /// and a field that only they could fill counts as missing if required.
  Map<String, String>? collect(
    Map<String, String> cookies, {
    Map<String, String> localStorage = const {},
  }) {
    final values = <String, String>{};
    for (final field in fields) {
      String? value;
      for (final source in field.sources) {
        value = switch (source.type) {
          'cookie' => cookies[source.name],
          'local_storage' => localStorage[source.name],
          _ => null,
        };
        if (value != null && value.isNotEmpty) break;
        value = null;
      }
      if (value != null) {
        values[field.id] = value;
      } else if (field.required) {
        return null;
      }
    }
    return values;
  }

  /// Local storage keys any field reads, so the browser asks only for those.
  List<String> get localStorageKeys => [
    for (final field in fields)
      for (final source in field.sources)
        if (source.type == 'local_storage') source.name,
  ];
}

/// One value a `cookies` step needs, and where in the browser it lives.
@immutable
class LoginCookieField {
  const LoginCookieField({
    required this.id,
    this.required = false,
    this.sources = const [],
  });

  factory LoginCookieField.fromJson(Map<Object?, Object?> json) =>
      LoginCookieField(
        id: json['id'] as String,
        required: json['required'] == true,
        sources: [
          if (json['sources'] is List)
            for (final source in (json['sources'] as List).whereType<Map>())
              if (source['type'] is String && source['name'] is String)
                LoginCookieSource(
                  type: source['type'] as String,
                  name: source['name'] as String,
                  cookieDomain: source['cookie_domain'] as String?,
                ),
        ],
      );

  final String id;
  final bool required;
  final List<LoginCookieSource> sources;
}

/// Where a [LoginCookieField] is read from: `cookie`, `local_storage`,
/// `request_header`, `request_body` or `special`.
@immutable
class LoginCookieSource {
  const LoginCookieSource({
    required this.type,
    required this.name,
    this.cookieDomain,
  });

  final String type;
  final String name;
  final String? cookieDomain;
}

/// A step in a login flow.
///
/// Rendered generically: a bridge that adds a new field or a new flow works
/// without a client change, which matters because Weft cannot ship an update
/// every time a bridge does.
@immutable
class LoginStep {
  const LoginStep({
    required this.stepId,
    required this.type,
    this.instructions,
    this.fields = const [],
    this.displayData,
    this.displayImageUrl,
    this.displayType,
    this.loginId,
    this.userLoginId,
    this.cookies,
    this.raw = const {},
  });

  final String stepId;
  final LoginStepType type;

  /// Bridge-authored instructions, shown verbatim.
  final String? instructions;

  /// For [LoginStepType.userInput].
  final List<LoginInputField> fields;

  /// For [LoginStepType.displayAndWait]: the QR payload or emoji string.
  final String? displayData;
  final String? displayImageUrl;

  /// `qr`, `emoji`, `code`, or `nothing`.
  final String? displayType;

  /// The login *process* this step belongs to — what the next request is
  /// addressed to.
  final String? loginId;

  /// Set on [LoginStepType.complete]: the remote account the bridge now holds,
  /// which is what logging out later is addressed to.
  final String? userLoginId;

  /// For [LoginStepType.cookies].
  final LoginCookiesParams? cookies;

  /// The undecoded step, so an unsupported type can still be shown for
  /// debugging rather than vanishing.
  final Map<String, Object?> raw;

  bool get isTerminal => type == LoginStepType.complete;

  factory LoginStep.fromJson(Map<String, Object?> json) {
    final type = LoginStepType.fromWire(json['type'] as String?);

    final userInput = json['user_input'];
    final fields = <LoginInputField>[];
    if (userInput is Map && userInput['fields'] is List) {
      for (final field in userInput['fields'] as List) {
        if (field is! Map) continue;
        fields.add(LoginInputField.fromJson(field));
      }
    }

    final display = json['display_and_wait'];
    final complete = json['complete'];
    final cookies = json['cookies'];

    return LoginStep(
      stepId: json['step_id'] as String? ?? '',
      type: type,
      instructions: (json['instructions'] as String?)?.nonEmpty,
      fields: fields,
      displayData: display is Map ? display['data'] as String? : null,
      displayImageUrl: display is Map ? display['image_url'] as String? : null,
      displayType: display is Map ? display['type'] as String? : null,
      // The process id is top-level on every response. Older test doubles and
      // bridges put it inside `complete` too, so that is the fallback.
      loginId:
          json['login_id'] as String? ??
          (complete is Map ? complete['login_id'] as String? : null),
      userLoginId: complete is Map
          ? complete['user_login_id'] as String? ??
                complete['login_id'] as String?
          : null,
      cookies: cookies is Map ? LoginCookiesParams.fromJson(cookies) : null,
      raw: json,
    );
  }
}

/// Raised when a bridge call fails in a way worth showing the user.
class BridgeException implements Exception {
  const BridgeException(
    this.message, {
    this.statusCode,
    this.errorCode,
    this.failure,
  });

  /// The bridge's own sentence when it sent one, and an English fallback when
  /// it did not.
  ///
  /// A bridge writes genuinely useful errors and they arrive in whatever
  /// language it was configured in — there is nothing to translate and nothing
  /// that should be. [failure] is the other case: a status code this package
  /// turned into a sentence itself, which the app re-words in the reader's
  /// language. When [failure] is set, prefer it.
  final String message;
  final int? statusCode;

  /// The bridge's own `errcode`, when it sent one.
  final String? errorCode;

  /// Set only when [message] is this package's own English, not the bridge's.
  final BridgeFailure? failure;

  /// [errorCode] for a value the bridge rejected while keeping the step open,
  /// so the form can be shown again with the reason under it.
  static const invalidInputCode = 'CHAT.SENNIT.INVALID_INPUT';

  @override
  String toString() => 'BridgeException: $message';
}

/// A transport failure this package described itself, for the app to word.
///
/// A package cannot hold translations — see
/// `docs/architecture/l10n-pipeline.md`, "Packages and their words" — so the
/// status code becomes a value here and a sentence in the app.
enum BridgeFailure {
  /// 401 or 403: the bridge will not serve this Matrix account.
  rejected,

  /// 404: nothing answering the provisioning API at that URL.
  notFound,

  /// 502, 503 or 504: starting up, or down.
  unavailable,

  /// No answer at all: the network failed before any status code arrived.
  unreachable,

  /// The bridge took too long to answer.
  timeout,

  /// Anything else, with [BridgeException.statusCode] carrying the number.
  other,
}
