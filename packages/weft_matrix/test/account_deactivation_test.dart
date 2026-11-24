import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_matrix/weft_matrix.dart';

/// Answers the prompts from a script and records what was asked.
class _Reauth implements AccountReauth {
  _Reauth({this.passwords = const [], this.browser = true});

  final List<String?> passwords;
  final bool browser;
  final List<bool> retries = [];
  final List<Uri> opened = [];

  @override
  Future<String?> password({bool retry = false}) async {
    retries.add(retry);
    return passwords[retries.length - 1];
  }

  @override
  Future<bool> completeInBrowser(Uri url) async {
    opened.add(url);
    return browser;
  }
}

http.Response _challenge(
  List<List<String>> flows, {
  List<String> completed = const [],
  String? errcode,
}) => http.Response(
  jsonEncode({
    'session': 'S1',
    'flows': [
      for (final stages in flows) {'stages': stages},
    ],
    'completed': completed,
    'errcode': ?errcode,
  }),
  401,
);

final _ok = http.Response(
  jsonEncode({'id_server_unbind_result': 'no-support'}),
  200,
);

sdk.MatrixApi _api(
  Future<http.Response> Function(Map<String, Object?>) answer,
) {
  return sdk.MatrixApi(
    homeserver: Uri.parse('https://matrix.example.org'),
    accessToken: 'token',
    httpClient: MockClient((request) async {
      expect(request.url.path, '/_matrix/client/v3/account/deactivate');
      return answer(jsonDecode(request.body) as Map<String, Object?>);
    }),
  );
}

void main() {
  const password = sdk.AuthenticationTypes.password;
  const sso = sdk.AuthenticationTypes.sso;
  const dummy = sdk.AuthenticationTypes.dummy;

  group('nextDeactivationStage', () {
    test('prefers the password flow Sennit can draw', () {
      expect(
        nextDeactivationStage([
          [sso],
          [password],
        ]),
        password,
      );
    });

    test('falls back to single sign-on when there is no password', () {
      expect(
        nextDeactivationStage([
          [sso],
        ]),
        sso,
      );
    });

    test('continues the flow the completed stages belong to', () {
      expect(
        nextDeactivationStage(
          [
            [password, 'm.login.email.identity'],
          ],
          completed: [password],
        ),
        'm.login.email.identity',
      );
    });

    test('is null when every flow is finished or does not match', () {
      expect(
        nextDeactivationStage(
          [
            [password],
          ],
          completed: [password],
        ),
        isNull,
      );
    });
  });

  test('the fallback page sits under the homeserver base path', () {
    expect(
      authFallbackUrl(Uri.parse('https://example.org/matrix/'), sso, 'a b'),
      Uri.parse(
        'https://example.org/matrix/_matrix/client/v3/auth/m.login.sso/'
        'fallback/web?session=a+b',
      ),
    );
  });

  group('deactivateAccount', () {
    test('asks for the password and erases', () async {
      final bodies = <Map<String, Object?>>[];
      final api = _api((body) async {
        bodies.add(body);
        return bodies.length == 1
            ? _challenge([
                [password],
              ])
            : _ok;
      });
      final reauth = _Reauth(passwords: ['hunter2']);

      await deactivateAccount(api, userId: '@me:example.org', reauth: reauth);

      expect(bodies.first, {'erase': true});
      expect(bodies.last['erase'], true);
      expect(bodies.last['auth'], {
        'type': password,
        'session': 'S1',
        'password': 'hunter2',
        'identifier': {'type': 'm.id.user', 'user': '@me:example.org'},
      });
      expect(reauth.retries, [false]);
    });

    test('asks again, saying so, after a wrong password', () async {
      var calls = 0;
      final api = _api((body) async {
        calls++;
        if (calls == 1) {
          return _challenge([
            [password],
          ]);
        }
        final auth = body['auth']! as Map<String, Object?>;
        return auth['password'] == 'right'
            ? _ok
            : _challenge([
                [password],
              ], errcode: 'M_FORBIDDEN');
      });
      final reauth = _Reauth(passwords: ['wrong', 'right']);

      await deactivateAccount(api, userId: '@me:example.org', reauth: reauth);

      expect(reauth.retries, [false, true]);
    });

    test('sends single sign-on through the fallback page', () async {
      final bodies = <Map<String, Object?>>[];
      final api = _api((body) async {
        bodies.add(body);
        return bodies.length == 1
            ? _challenge([
                [sso],
              ])
            : _ok;
      });
      final reauth = _Reauth();

      await deactivateAccount(api, userId: '@me:example.org', reauth: reauth);

      expect(
        reauth.opened.single.path,
        '/_matrix/client/v3/auth/m.login.sso/fallback/web',
      );
      expect(reauth.opened.single.queryParameters, {'session': 'S1'});
      // The fallback finished the stage; the retry names only the session.
      expect(bodies.last['auth'], {'session': 'S1'});
    });

    test('completes a dummy stage without asking', () async {
      final bodies = <Map<String, Object?>>[];
      final api = _api((body) async {
        bodies.add(body);
        return bodies.length == 1
            ? _challenge([
                [dummy],
              ])
            : _ok;
      });

      await deactivateAccount(
        api,
        userId: '@me:example.org',
        reauth: _Reauth(),
      );

      expect(bodies.last['auth'], {'type': dummy, 'session': 'S1'});
    });

    test('a cancelled prompt deactivates nothing', () async {
      var calls = 0;
      final api = _api((_) async {
        calls++;
        return _challenge([
          [password],
        ]);
      });

      await expectLater(
        deactivateAccount(
          api,
          userId: '@me:example.org',
          reauth: _Reauth(passwords: [null]),
        ),
        throwsA(isA<AccountDeactivationCancelled>()),
      );
      expect(calls, 1);
    });

    test('a browser step left unfinished is a cancel', () async {
      final api = _api(
        (_) async => _challenge([
          [sso],
        ]),
      );

      await expectLater(
        deactivateAccount(
          api,
          userId: '@me:example.org',
          reauth: _Reauth(browser: false),
        ),
        throwsA(isA<AccountDeactivationCancelled>()),
      );
    });

    test('a refusal without a challenge reaches the caller', () async {
      final api = _api(
        (_) async => http.Response(
          jsonEncode({'errcode': 'M_FORBIDDEN', 'error': 'no'}),
          403,
        ),
      );

      await expectLater(
        deactivateAccount(api, userId: '@me:example.org', reauth: _Reauth()),
        throwsA(isA<sdk.MatrixException>()),
      );
    });

    test('gives up on a server that never stops challenging', () async {
      final api = _api(
        (_) async => _challenge([
          [dummy],
        ]),
      );

      await expectLater(
        deactivateAccount(api, userId: '@me:example.org', reauth: _Reauth()),
        throwsA(isA<AccountDeactivationUnsupported>()),
      );
    });
  });
}
