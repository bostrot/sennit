import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_bridges/weft_bridges.dart';

import 'package:weft/features/bridges/bridge_external_sign_in.dart';

/// Mattermost's single sign-on in the person's own browser: where it starts,
/// which providers a server offers, and what a callback must carry before
/// its token goes to the bridge.
void main() {
  LoginCookiesParams cookies(String url) => LoginCookiesParams(
    url: url,
    fieldIds: const ['token'],
    fields: const [
      LoginCookieField(
        id: 'token',
        required: true,
        sources: [LoginCookieSource(type: 'cookie', name: 'MMAUTHTOKEN')],
      ),
    ],
  );

  final server = Uri.parse('https://mm.example.com');

  group('serverOf', () {
    test('drops the login page, keeps a port and a subpath', () {
      expect(
        MattermostExternalSignIn.serverOf(
          cookies('https://mm.example.com/login'),
        ).toString(),
        'https://mm.example.com',
      );
      expect(
        MattermostExternalSignIn.serverOf(
          cookies('http://chat.example.org:8065/mattermost/login'),
        ).toString(),
        'http://chat.example.org:8065/mattermost',
      );
    });
  });

  test('starts OAuth and SAML at the mobile endpoints', () {
    expect(
      MattermostExternalSignIn.startUrl(server, 'gitlab').toString(),
      'https://mm.example.com/oauth/gitlab/mobile_login'
      '?redirect_to=mmauth%3A%2F%2Fcallback',
    );
    expect(
      MattermostExternalSignIn.startUrl(server, 'saml').toString(),
      'https://mm.example.com/login/sso/saml'
      '?action=mobile&redirect_to=mmauth%3A%2F%2Fcallback',
    );
  });

  test('lists what the client config switches on, with its labels', () {
    final found = MattermostExternalSignIn.providersFromConfig(server, {
      'EnableSignUpWithGitLab': 'true',
      'GitLabButtonText': '',
      'EnableSignUpWithGoogle': 'false',
      'EnableSignUpWithOffice365': 'true',
      'EnableSignUpWithOpenId': 'true',
      'OpenIdButtonText': 'Keycloak',
      'EnableSaml': 'true',
      'SamlLoginButtonText': 'ACME login',
    });
    expect(
      [for (final p in found) '${p.id}:${p.label}'],
      [
        'gitlab:GitLab',
        'office365:Entra ID',
        'openid:Keycloak',
        'saml:ACME login',
      ],
    );
    expect(
      MattermostExternalSignIn.providersFromConfig(server, {
        'EnableSignInWithEmail': 'true',
      }),
      isEmpty,
    );
  });

  group('tokenFrom', () {
    test('takes the token from a callback of this server', () {
      expect(
        MattermostExternalSignIn.tokenFrom(
          Uri.parse(
            'mmauth://callback?MMAUTHTOKEN=t0k&MMCSRF=c&srv=https%3A%2F%2Fmm.example.com',
          ),
          server,
        ),
        't0k',
      );
    });

    test('refuses another server, another scheme, or no token', () {
      expect(
        MattermostExternalSignIn.tokenFrom(
          Uri.parse(
            'mmauth://callback?MMAUTHTOKEN=t0k&srv=https%3A%2F%2Fevil.example',
          ),
          server,
        ),
        isNull,
      );
      expect(
        MattermostExternalSignIn.tokenFrom(
          Uri.parse('weft://callback?MMAUTHTOKEN=t0k'),
          server,
        ),
        isNull,
      );
      // Mattermost's error page links back to the bare callback.
      expect(
        MattermostExternalSignIn.tokenFrom(
          Uri.parse('mmauth://callback'),
          server,
        ),
        isNull,
      );
    });
  });

  test('asks the server for its providers, and none when it cannot', () async {
    final asked = <Uri>[];
    final signIn = MattermostExternalSignIn(
      httpClient: MockClient((request) async {
        asked.add(request.url);
        return http.Response(
          jsonEncode({'EnableSignUpWithGitLab': 'true'}),
          200,
        );
      }),
    );
    final found = await signIn.providers(
      cookies('https://mm.example.com/login'),
    );
    expect(
      asked.single.toString(),
      endsWith('/api/v4/config/client?format=old'),
    );
    expect(found.single.id, 'gitlab');

    final down = MattermostExternalSignIn(
      httpClient: MockClient((_) async => http.Response('nope', 502)),
    );
    expect(
      await down.providers(cookies('https://mm.example.com/login')),
      isEmpty,
    );

    // Not a Mattermost step at all.
    expect(
      await signIn.providers(
        const LoginCookiesParams(url: 'https://www.instagram.com/'),
      ),
      isEmpty,
    );
  });

  test('signs in through the browser and hands the bridge its field', () async {
    Uri? openedAt;
    String? scheme;
    final signIn = MattermostExternalSignIn(
      authenticate: (url, {required callbackScheme}) async {
        openedAt = url;
        scheme = callbackScheme;
        return Uri.parse(
          'mmauth://callback?MMAUTHTOKEN=sess&MMCSRF=c&srv=https%3A%2F%2Fmm.example.com',
        );
      },
    );
    final params = cookies('https://mm.example.com/login');
    final provider = MattermostExternalSignIn.providersFromConfig(server, {
      'EnableSaml': 'true',
    }).single;

    expect(await signIn.signIn(params, provider), {'token': 'sess'});
    expect(openedAt, provider.url);
    expect(scheme, 'mmauth');

    final closed = MattermostExternalSignIn(
      authenticate: (_, {required callbackScheme}) async => null,
    );
    expect(await closed.signIn(params, provider), isNull);

    final empty = MattermostExternalSignIn(
      authenticate: (_, {required callbackScheme}) async =>
          Uri.parse('mmauth://callback'),
    );
    expect(
      () => empty.signIn(params, provider),
      throwsA(isA<ExternalSignInException>()),
    );
  });
}
