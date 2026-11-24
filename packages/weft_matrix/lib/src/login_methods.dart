import 'package:matrix/matrix.dart' as sdk;
import 'package:meta/meta.dart';

/// The address the browser is sent back to after an OAuth sign-in on a phone.
///
/// A private-use scheme has to start with the client's own domain reversed
/// (RFC 8252 §7.1, which Continuwuity and MAS both enforce at client
/// registration), so it follows [kOAuthClientUri] rather than the bundle id.
/// No authority: Continuwuity refuses a private-use redirect that has one.
const String kOAuthRedirectScheme = 'com.erictrenkel.sennit';
final Uri kOAuthRedirectUri = Uri.parse('$kOAuthRedirectScheme:/oauth');

/// What the homeserver's consent page links to as "the app asking".
final Uri kOAuthClientUri = Uri.parse('https://erictrenkel.com/apps/sennit/');
final Uri kOAuthPolicyUri = Uri.parse(
  'https://erictrenkel.com/apps/sennit/privacy.html',
);

/// The UIA stage a server sends an OAuth-signed-in client to the browser
/// with, and the name older servers used for the same thing.
const String kOAuthStage = 'm.oauth';
const String kCrossSigningResetStage = 'org.matrix.cross_signing_reset';

/// One button on a server's single sign-on list.
@immutable
class SsoProvider {
  const SsoProvider({required this.id, required this.name, this.brand});

  final String id;
  final String name;

  /// `github`, `google`, … when the server says which brand it is.
  final String? brand;

  @override
  bool operator ==(Object other) =>
      other is SsoProvider &&
      other.id == id &&
      other.name == name &&
      other.brand == brand;

  @override
  int get hashCode => Object.hash(id, name, brand);
}

/// How a homeserver lets someone sign in, read from `GET /login` and the
/// OAuth 2.0 server metadata together.
///
/// The two answer different questions and either can be missing: a server
/// that hands sign-in to an OAuth server (Continuwuity with an identity
/// provider configured, Synapse behind MAS without compatibility) refuses
/// `GET /login` outright with `M_UNRECOGNIZED`, and an older server has no
/// metadata at all.
@immutable
class LoginMethods {
  const LoginMethods({
    this.password = false,
    this.sso = false,
    this.ssoProviders = const [],
    this.oauth,
    this.unsupported = false,
  });

  /// A username and a password, typed into Sennit.
  final bool password;

  /// The legacy `m.login.sso` redirect, with [ssoProviders] when the server
  /// names them, or one generic button when it does not.
  final bool sso;
  final List<SsoProvider> ssoProviders;

  /// The server's OAuth 2.0 metadata, when it offers next-gen sign-in.
  final OAuthServer? oauth;

  /// The server named its ways in, and Sennit can do none of them — a CAS
  /// login, say, or only the token login another client hands over.
  final bool unsupported;

  /// Whether there is a way in at all.
  bool get any => password || sso || oauth != null;

  /// Whether the browser is the only way in: no password form to show.
  bool get browserOnly => !password && (sso || oauth != null);
}

/// The part of a server's OAuth 2.0 metadata Sennit acts on.
@immutable
class OAuthServer {
  const OAuthServer({
    required this.issuer,
    this.accountManagementUri,
    this.accountManagementActions = const {},
    this.promptValues = const {},
  });

  final Uri issuer;

  /// The page where the account is managed: devices, deactivation, a
  /// cross-signing reset. Null when the server has none.
  final Uri? accountManagementUri;
  final Set<String> accountManagementActions;

  /// `create` when the server's sign-in page can also make a new account.
  final Set<String> promptValues;

  bool get canRegister => promptValues.contains('create');

  /// Where to send someone to do [action] on the account page, or null when
  /// the server does not offer one.
  ///
  /// A server that lists no actions at all still gets the page: the list is
  /// optional, and the page is still the place the account is managed.
  Uri? accountManagementUrl(String action, {String? deviceId}) {
    final base = accountManagementUri;
    if (base == null) return null;
    if (accountManagementActions.isNotEmpty &&
        !accountManagementActions.contains(action)) {
      return base;
    }
    return base.replace(
      queryParameters: {
        ...base.queryParameters,
        'action': action,
        'device_id': ?deviceId,
      },
    );
  }

  static OAuthServer? fromJson(Map<String, Object?>? json) {
    final issuer = json?['issuer'];
    if (json == null || issuer is! String) return null;
    Set<String> strings(Object? value) => {
      if (value is List)
        for (final item in value)
          if (item is String) item,
    };
    final manage = json['account_management_uri'];
    return OAuthServer(
      issuer: Uri.parse(issuer),
      accountManagementUri: manage is String ? Uri.tryParse(manage) : null,
      accountManagementActions: strings(
        json['account_management_actions_supported'],
      ),
      promptValues: strings(json['prompt_values_supported']),
    );
  }
}

/// Account-page actions, as MSC4191 names them.
abstract final class AccountManagementAction {
  static const String deviceDelete = 'org.matrix.device_delete';
  static const String devicesList = 'org.matrix.devices_list';
  static const String accountDeactivate = 'org.matrix.account_deactivate';
  static const String crossSigningReset = 'org.matrix.cross_signing_reset';
}

/// Reads [flows] (null when `GET /login` was refused) and [authMetadata]
/// (null when the server has none) into what the login screen offers.
LoginMethods loginMethodsFrom({
  List<sdk.LoginFlow>? flows,
  Map<String, Object?>? authMetadata,
}) {
  final oauth = OAuthServer.fromJson(authMetadata);
  final all = flows ?? const <sdk.LoginFlow>[];
  final ssoFlows = all.where((f) => f.type == 'm.login.sso');
  final providers = <SsoProvider>[
    for (final flow in ssoFlows)
      for (final idp in _list(flow.additionalProperties['identity_providers']))
        if (idp case {'id': final String id, 'name': final String name})
          SsoProvider(
            id: id,
            name: name,
            brand: idp['brand'] is String ? idp['brand'] as String : null,
          ),
  ];
  final password = all.any((f) => f.type == 'm.login.password');
  return LoginMethods(
    password: password,
    // A server with OAuth often advertises `m.login.sso` as well, for clients
    // that do not speak OAuth — MAS's compatibility layer does. The OAuth
    // sign-in is the real one there, so it alone is offered.
    sso: oauth == null && ssoFlows.isNotEmpty,
    ssoProviders: oauth == null ? providers : const [],
    oauth: oauth,
    unsupported:
        all.isNotEmpty && !password && ssoFlows.isEmpty && oauth == null,
  );
}

List<Object?> _list(Object? value) => value is List ? value : const [];

/// The fields of a server's OAuth metadata the SDK parses strictly, with the
/// values it does not know dropped.
///
/// The SDK turns `account_management_actions_supported` into an enum with a
/// `!`, so one action newer than it — MAS lists several — would make every
/// OAuth call throw a `TypeError` before reaching the network.
Map<String, Object?> sanitizeAuthMetadata(Map<String, Object?> json) {
  final actions = json['account_management_actions_supported'];
  if (actions is! List) return json;
  final known = {
    for (final action in sdk.AccountManagementActionsSupported.values)
      action.name,
  };
  return {
    ...json,
    'account_management_actions_supported': [
      for (final action in actions)
        if (known.contains(action)) action,
    ],
  };
}

/// Why a browser sign-in did not end in a session.
enum BrowserLoginFailure {
  /// The person said no on the server's page, or closed it there.
  denied,

  /// The answer did not belong to the sign-in Sennit started.
  mismatch,

  /// The server's page ended without a code or token to sign in with.
  incomplete,
}

class BrowserLoginException implements Exception {
  const BrowserLoginException(this.reason, [this.detail]);

  final BrowserLoginFailure reason;

  /// What the server said, when it said anything.
  final String? detail;

  @override
  String toString() =>
      'BrowserLoginException(${reason.name}${detail == null ? '' : ': $detail'})';
}

/// The authorization code in [callback], the address the OAuth server sent
/// the browser back to, checked against the [state] the sign-in started
/// with.
///
/// The answer arrives in the query or in the fragment depending on the
/// response mode, so both are read.
String oauthCodeFrom(Uri callback, {required String state}) {
  final params = {
    ...callback.queryParameters,
    if (callback.fragment.isNotEmpty)
      ...Uri.splitQueryString(callback.fragment),
  };
  final error = params['error'];
  if (error != null) {
    throw BrowserLoginException(
      BrowserLoginFailure.denied,
      params['error_description'] ?? error,
    );
  }
  if (params['state'] != state) {
    throw const BrowserLoginException(BrowserLoginFailure.mismatch);
  }
  final code = params['code'];
  if (code == null || code.isEmpty) {
    throw const BrowserLoginException(BrowserLoginFailure.incomplete);
  }
  return code;
}

/// The login token a legacy SSO redirect hands back in [callback].
String ssoLoginTokenFrom(Uri callback) {
  final token = callback.queryParameters['loginToken'];
  if (token == null || token.isEmpty) {
    throw const BrowserLoginException(BrowserLoginFailure.incomplete);
  }
  return token;
}

/// The page a UIA challenge sends an OAuth-signed-in client to, when
/// [stages] include the browser stage and [params] carry its address.
Uri? oauthStageUrl(Iterable<String> stages, Map<String, Object?> params) {
  for (final stage in [kOAuthStage, kCrossSigningResetStage]) {
    if (!stages.contains(stage)) continue;
    final entry = params[stage];
    if (entry case {'url': final String url}) return Uri.tryParse(url);
  }
  return null;
}
