import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:weft_bridges/weft_bridges.dart';

/// Signing in to a network in the person's own browser, rather than in a page
/// inside Sennit.
///
/// The in-app page ([BridgeBrowserSignInPage]) reads the session out of its
/// own cookie store. A real browser keeps its cookies to itself, so this only
/// works where the site hands the session to an app on purpose, at the end of
/// the sign-in, in the address it redirects to. Mattermost does, for its
/// single sign-on: the mobile flow ends on `mmauth://callback?MMAUTHTOKEN=…`.
/// It does not for a plain password — that never leaves the browser — so a
/// server without SSO is signed in to the way it always was, with the
/// password typed into Sennit or into the in-app page.
///
/// Why bother, when the in-app page can do SSO too: Google refuses to sign in
/// inside an embedded web view at all, and the person's browser usually is
/// signed in to their company's SSO already, so it does not ask again.
@immutable
class ExternalSignInProvider {
  const ExternalSignInProvider({
    required this.id,
    required this.label,
    required this.url,
  });

  /// `gitlab`, `google`, `office365`, `openid` or `saml`.
  final String id;

  /// What the server calls it on its own login page.
  final String label;

  /// Where the sign-in starts.
  final Uri url;
}

/// Finds a network's browser sign-ins and runs one.
///
/// An interface so the login screen can be tested without a browser or a
/// server.
abstract interface class ExternalSignIn {
  /// The sign-ins [params] can be done with in the browser, or none.
  Future<List<ExternalSignInProvider>> providers(LoginCookiesParams params);

  /// Runs [provider] in the browser and returns what the bridge asked for,
  /// or null when the person closed the browser first.
  ///
  /// Throws [ExternalSignInException] when the sign-in finished without a
  /// session Sennit can use.
  Future<Map<String, String>?> signIn(
    LoginCookiesParams params,
    ExternalSignInProvider provider,
  );
}

class ExternalSignInException implements Exception {
  const ExternalSignInException(this.message);

  final String message;

  @override
  String toString() => 'ExternalSignInException: $message';
}

/// Whether this platform can open a sign-in in the browser and be handed
/// back where it finished.
///
/// Android (an Auth Tab, or a Custom Tab and a redirect receiver) and iOS
/// (`ASWebAuthenticationSession`). macOS keeps the in-app page, which signs
/// in with a password too; Windows and Linux have no way to catch the
/// `mmauth://` redirect without registering the scheme system-wide.
bool get externalSignInAvailable {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS;
}

/// Opens [url] in the browser and returns the address it finished on, or
/// null when the person closed it.
typedef BrowserAuthenticate =
    Future<Uri?> Function(Uri url, {required String callbackScheme});

const _channel = MethodChannel('com.bostrot.weft/browser_auth');

/// The real [BrowserAuthenticate]: `BrowserAuth.kt` on Android,
/// `WeftBrowserAuth` in `AppDelegate.swift` on iOS.
Future<Uri?> authenticateInBrowser(
  Uri url, {
  required String callbackScheme,
}) async {
  try {
    final result = await _channel.invokeMethod<String>('authenticate', {
      'url': url.toString(),
      'callbackScheme': callbackScheme,
    });
    return result == null ? null : Uri.parse(result);
  } on PlatformException catch (e) {
    throw ExternalSignInException(e.message ?? e.code);
  }
}

/// Mattermost's single sign-on, in the browser.
///
/// The mobile apps' flow: `/oauth/<provider>/mobile_login` (GitLab, Google,
/// Office 365, OpenID Connect) or `/login/sso/saml?action=mobile`, each with
/// `redirect_to=mmauth://callback`. Mattermost signs the person in, creates a
/// session that is not attached to the browser, and redirects to the callback
/// with the session's token as `MMAUTHTOKEN` and its own address as `srv`.
/// That token is what the bridge's webview flow collects as a cookie, so the
/// bridge cannot tell the two apart.
///
/// The callback scheme is fixed: Mattermost redirects only to schemes in its
/// `NativeAppSettings.AppCustomURLSchemes`, which by default are `mmauth://`
/// and `mmauthbeta://`, and a self-hosted server's admin has no reason to
/// have added Sennit's.
class MattermostExternalSignIn implements ExternalSignIn {
  MattermostExternalSignIn({
    http.Client? httpClient,
    BrowserAuthenticate? authenticate,
  }) : _http = httpClient,
       _authenticate = authenticate ?? authenticateInBrowser;

  final http.Client? _http;
  final BrowserAuthenticate _authenticate;

  static const callbackScheme = 'mmauth';
  static const callback = 'mmauth://callback';

  /// The cookie Mattermost's session lives in, and the name the token has in
  /// the callback.
  static const sessionCookie = 'MMAUTHTOKEN';

  /// Whether [params] is a Mattermost sign-in: the bridge asks for the
  /// session cookie.
  static bool handles(LoginCookiesParams params) => params.fields.any(
    (field) => field.sources.any(
      (source) => source.type == 'cookie' && source.name == sessionCookie,
    ),
  );

  /// The server, from the sign-in page the bridge named (`…/login`).
  static Uri serverOf(LoginCookiesParams params) {
    final page = Uri.parse(params.url);
    var path = page.path;
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    if (path.endsWith('/login')) {
      path = path.substring(0, path.length - '/login'.length);
    }
    return Uri(
      scheme: page.scheme,
      host: page.host,
      port: page.hasPort ? page.port : null,
      path: path,
    );
  }

  /// The address a sign-in starts at.
  static Uri startUrl(Uri server, String provider) {
    final base = server.toString();
    return provider == 'saml'
        ? Uri.parse('$base/login/sso/saml').replace(
            queryParameters: {'action': 'mobile', 'redirect_to': callback},
          )
        : Uri.parse(
            '$base/oauth/$provider/mobile_login',
          ).replace(queryParameters: {'redirect_to': callback});
  }

  /// The SSO providers a server's public client config switches on, in the
  /// order its login page lists them.
  static List<ExternalSignInProvider> providersFromConfig(
    Uri server,
    Map<String, Object?> config,
  ) {
    bool on(String key) => config[key] == 'true';
    String label(String key, String fallback) {
      final text = config[key];
      return text is String && text.trim().isNotEmpty ? text.trim() : fallback;
    }

    return [
      if (on('EnableSignUpWithGitLab'))
        ExternalSignInProvider(
          id: 'gitlab',
          label: label('GitLabButtonText', 'GitLab'),
          url: startUrl(server, 'gitlab'),
        ),
      if (on('EnableSignUpWithGoogle'))
        ExternalSignInProvider(
          id: 'google',
          // l10n-ignore: a product name, as Mattermost's login page shows it.
          label: 'Google',
          url: startUrl(server, 'google'),
        ),
      if (on('EnableSignUpWithOffice365'))
        ExternalSignInProvider(
          id: 'office365',
          // l10n-ignore: a product name, as Mattermost's login page shows it.
          label: 'Entra ID',
          url: startUrl(server, 'office365'),
        ),
      if (on('EnableSignUpWithOpenId'))
        ExternalSignInProvider(
          id: 'openid',
          label: label('OpenIdButtonText', 'OpenID'),
          url: startUrl(server, 'openid'),
        ),
      if (on('EnableSaml'))
        ExternalSignInProvider(
          id: 'saml',
          label: label('SamlLoginButtonText', 'SAML'),
          url: startUrl(server, 'saml'),
        ),
    ];
  }

  /// The session token in [callback], checked against the [server] the
  /// sign-in was started on.
  ///
  /// Mattermost adds `srv`, its own address, so a client can tell a callback
  /// from the server it asked apart from one some other page produced. A
  /// callback without a token is a failed sign-in: Mattermost's error page
  /// links back to the bare callback.
  static String? tokenFrom(Uri callback, Uri server) {
    if (callback.scheme != callbackScheme) return null;
    final token = callback.queryParameters[sessionCookie];
    if (token == null || token.isEmpty) return null;
    final srv = callback.queryParameters['srv'];
    if (srv != null && srv.isNotEmpty) {
      final from = Uri.tryParse(srv);
      if (from == null ||
          from.host.toLowerCase() != server.host.toLowerCase()) {
        return null;
      }
    }
    return token;
  }

  @override
  Future<List<ExternalSignInProvider>> providers(
    LoginCookiesParams params,
  ) async {
    if (!handles(params)) return const [];
    final server = serverOf(params);
    final client = _http ?? http.Client();
    try {
      final response = await client
          .get(
            Uri.parse(
              '$server/api/v4/config/client',
            ).replace(queryParameters: {'format': 'old'}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return const [];
      final config = jsonDecode(response.body);
      if (config is! Map<String, Object?>) return const [];
      return providersFromConfig(server, config);
    } on Object {
      // A server that cannot be asked offers the in-app page, as before.
      return const [];
    } finally {
      if (_http == null) client.close();
    }
  }

  @override
  Future<Map<String, String>?> signIn(
    LoginCookiesParams params,
    ExternalSignInProvider provider,
  ) async {
    final callback = await _authenticate(
      provider.url,
      callbackScheme: callbackScheme,
    );
    if (callback == null) return null;
    final token = tokenFrom(callback, serverOf(params));
    if (token == null) {
      throw const ExternalSignInException('No session in the callback');
    }
    final values = params.collect({sessionCookie: token});
    if (values == null) {
      throw const ExternalSignInException('The bridge wants more than a token');
    }
    return values;
  }
}
