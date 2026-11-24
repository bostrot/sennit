import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  sdk.LoginFlow flow(String type, [Map<String, Object?> extra = const {}]) =>
      sdk.LoginFlow.fromJson({'type': type, ...extra});

  // What Continuwuity 26.9 serves with `[global.oauth.oidc]` set.
  final continuwuity = <String, Object?>{
    'issuer': 'https://continuwuity-test.aachen.dev/',
    'account_management_uri':
        'https://continuwuity-test.aachen.dev/_continuwuity/account/deeplink',
    'account_management_actions_supported': [
      'org.matrix.account_deactivate',
      'org.matrix.cross_signing_reset',
      'org.matrix.device_delete',
      'org.matrix.devices_list',
    ],
    'authorization_endpoint':
        'https://continuwuity-test.aachen.dev/_continuwuity/oauth2/grant/authorization_code',
    'prompt_values_supported': ['create'],
  };

  group('loginMethodsFrom', () {
    test('a refused GET /login with OAuth metadata is OAuth only', () {
      // Continuwuity with an identity provider: `GET /login` answers
      // M_UNRECOGNIZED, which used to be the whole login screen.
      final methods = loginMethodsFrom(authMetadata: continuwuity);

      expect(methods.password, isFalse);
      expect(methods.sso, isFalse);
      expect(methods.oauth?.issuer.host, 'continuwuity-test.aachen.dev');
      expect(methods.oauth?.canRegister, isTrue);
      expect(methods.browserOnly, isTrue);
      expect(methods.unsupported, isFalse);
    });

    test('a password server with no metadata is a password form', () {
      final methods = loginMethodsFrom(
        flows: [flow('m.login.password'), flow('m.login.token')],
      );
      expect(methods.password, isTrue);
      expect(methods.oauth, isNull);
      expect(methods.browserOnly, isFalse);
    });

    test('hybrid: a password and OAuth side by side', () {
      final methods = loginMethodsFrom(
        flows: [flow('m.login.password')],
        authMetadata: continuwuity,
      );
      expect(methods.password, isTrue);
      expect(methods.oauth, isNotNull);
      expect(methods.browserOnly, isFalse);
    });

    test('legacy SSO names its providers', () {
      final methods = loginMethodsFrom(
        flows: [
          flow('m.login.sso', {
            'identity_providers': [
              {'id': 'oidc-keycloak', 'name': 'Keycloak'},
              {'id': 'github', 'name': 'GitHub', 'brand': 'github'},
              {'name': 'no id, skipped'},
            ],
          }),
          flow('m.login.token'),
        ],
      );
      expect(methods.sso, isTrue);
      expect(methods.ssoProviders, const [
        SsoProvider(id: 'oidc-keycloak', name: 'Keycloak'),
        SsoProvider(id: 'github', name: 'GitHub', brand: 'github'),
      ]);
      expect(methods.browserOnly, isTrue);
    });

    test('SSO beside OAuth is the compatibility layer, not a second way', () {
      final methods = loginMethodsFrom(
        flows: [flow('m.login.sso')],
        authMetadata: continuwuity,
      );
      expect(methods.sso, isFalse);
      expect(methods.ssoProviders, isEmpty);
      expect(methods.oauth, isNotNull);
    });

    test('only flows Sennit cannot do is unsupported, and says so', () {
      final methods = loginMethodsFrom(flows: [flow('m.login.cas')]);
      expect(methods.any, isFalse);
      expect(methods.unsupported, isTrue);
    });

    test('no flows at all is not called unsupported', () {
      final methods = loginMethodsFrom(flows: const []);
      expect(methods.any, isFalse);
      expect(methods.unsupported, isFalse);
    });

    test('metadata without an issuer is not OAuth', () {
      expect(loginMethodsFrom(authMetadata: const {}).oauth, isNull);
    });
  });

  group('OAuthServer.accountManagementUrl', () {
    final server = OAuthServer.fromJson(continuwuity)!;

    test('names the action and the device', () {
      final url = server.accountManagementUrl(
        AccountManagementAction.deviceDelete,
        deviceId: 'ABCDEF',
      )!;
      expect(url.path, '/_continuwuity/account/deeplink');
      expect(url.queryParameters, {
        'action': 'org.matrix.device_delete',
        'device_id': 'ABCDEF',
      });
    });

    test('an action the server does not list opens the plain page', () {
      final url = server.accountManagementUrl('org.matrix.profile')!;
      expect(url.queryParameters, isEmpty);
    });

    test('no account page, no url', () {
      final bare = OAuthServer(issuer: Uri.parse('https://example.org/'));
      expect(
        bare.accountManagementUrl(AccountManagementAction.accountDeactivate),
        isNull,
      );
    });
  });

  test('sanitizeAuthMetadata drops actions the SDK cannot parse', () {
    final json = sanitizeAuthMetadata({
      ...continuwuity,
      'account_management_actions_supported': [
        'org.matrix.profile',
        'org.matrix.sessions_list',
        'org.matrix.session_end',
      ],
    });
    expect(json['account_management_actions_supported'], [
      'org.matrix.profile',
    ]);
    expect(json['issuer'], continuwuity['issuer']);
  });

  group('oauthCodeFrom', () {
    test('reads the code from the query', () {
      expect(
        oauthCodeFrom(
          Uri.parse('com.erictrenkel.sennit:/oauth?state=s1&code=c1'),
          state: 's1',
        ),
        'c1',
      );
    });

    test('reads the code from the fragment', () {
      expect(
        oauthCodeFrom(
          Uri.parse('com.erictrenkel.sennit:/oauth#state=s1&code=c1'),
          state: 's1',
        ),
        'c1',
      );
    });

    test('an error from the server is a refusal, with its words', () {
      expect(
        () => oauthCodeFrom(
          Uri.parse(
            'http://127.0.0.1:4711/callback?error=access_denied'
            '&error_description=User+said+no&state=s1',
          ),
          state: 's1',
        ),
        throwsA(
          isA<BrowserLoginException>()
              .having((e) => e.reason, 'reason', BrowserLoginFailure.denied)
              .having((e) => e.detail, 'detail', 'User said no'),
        ),
      );
    });

    test('an answer to some other sign-in is refused', () {
      expect(
        () => oauthCodeFrom(
          Uri.parse('com.erictrenkel.sennit:/oauth?state=other&code=c1'),
          state: 's1',
        ),
        throwsA(
          isA<BrowserLoginException>().having(
            (e) => e.reason,
            'reason',
            BrowserLoginFailure.mismatch,
          ),
        ),
      );
    });

    test('no code is an unfinished sign-in', () {
      expect(
        () => oauthCodeFrom(
          Uri.parse('com.erictrenkel.sennit:/oauth?state=s1'),
          state: 's1',
        ),
        throwsA(
          isA<BrowserLoginException>().having(
            (e) => e.reason,
            'reason',
            BrowserLoginFailure.incomplete,
          ),
        ),
      );
    });
  });

  test('ssoLoginTokenFrom reads the login token', () {
    expect(
      ssoLoginTokenFrom(
        Uri.parse('com.erictrenkel.sennit:/oauth?loginToken=abc'),
      ),
      'abc',
    );
    expect(
      () => ssoLoginTokenFrom(Uri.parse('com.erictrenkel.sennit:/oauth')),
      throwsA(isA<BrowserLoginException>()),
    );
  });

  group('oauthStageUrl', () {
    test('finds the page for the browser stage', () {
      expect(
        oauthStageUrl(
          {'m.oauth'},
          {
            'm.oauth': {'url': 'https://example.org/reset'},
          },
        ),
        Uri.parse('https://example.org/reset'),
      );
    });

    test('accepts the older cross-signing reset name', () {
      expect(
        oauthStageUrl(
          {'org.matrix.cross_signing_reset'},
          {
            'org.matrix.cross_signing_reset': {
              'url': 'https://example.org/reset',
            },
          },
        ),
        Uri.parse('https://example.org/reset'),
      );
    });

    test('a password stage has no page', () {
      expect(oauthStageUrl({'m.login.password'}, const {}), isNull);
    });
  });

  test('the phone redirect is one an OAuth server accepts', () {
    // RFC 8252 §7.1: a private-use scheme starts with the client's domain
    // reversed, and Continuwuity refuses one with an authority.
    final reversed = kOAuthClientUri.host.split('.').reversed.join('.');
    expect(kOAuthRedirectScheme, startsWith(reversed));
    expect(kOAuthRedirectUri.hasAuthority, isFalse);
    expect(kOAuthPolicyUri.host, kOAuthClientUri.host);
  });
}
