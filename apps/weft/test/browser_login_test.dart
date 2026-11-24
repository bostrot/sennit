import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:weft/features/auth/browser_login.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// The two ways a Matrix sign-in in the browser is caught on its way back.
void main() {
  group('LoopbackBrowserLogin', () {
    test(
      'catches the redirect on a loopback port and answers the tab',
      () async {
        late Uri redirect;
        http.Response? tab;
        final login = LoopbackBrowserLogin(
          // Stands in for the browser: it follows the page straight to the
          // redirect, the way an OAuth server ends a sign-in.
          open: (page) async {
            tab = await http.get(
              redirect.replace(queryParameters: {'code': 'c', 'state': 's'}),
            );
            return true;
          },
        );

        final callback = await login.run((r) async {
          redirect = r;
          return Uri.parse('https://example.org/authorize');
        }, doneText: 'Signed in <for real>.');

        expect(redirect.scheme, 'http');
        expect(redirect.host, '127.0.0.1');
        expect(redirect.path, '/callback');
        expect(callback?.queryParameters, {'code': 'c', 'state': 's'});
        expect(tab?.statusCode, 200);
        expect(tab?.body, contains('Signed in &lt;for real&gt;.'));
      },
    );

    test('the port is closed once the sign-in is over', () async {
      late Uri redirect;
      final login = LoopbackBrowserLogin(
        open: (page) async {
          await http.get(redirect);
          return true;
        },
      );
      await login.run((r) async {
        redirect = r;
        return Uri.parse('https://example.org/authorize');
      }, doneText: 'done');

      await expectLater(
        http.get(redirect),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('cancel gives up waiting', () async {
      final login = LoopbackBrowserLogin(open: (_) async => true);
      final result = login.run(
        (r) async => Uri.parse('https://example.org/authorize'),
        doneText: 'done',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      login.cancel();
      expect(await result, isNull);
    });

    test('a browser that cannot be opened is a closed sign-in', () async {
      final login = LoopbackBrowserLogin(open: (_) async => false);
      expect(
        await login.run(
          (r) async => Uri.parse('https://example.org/authorize'),
          doneText: 'done',
        ),
        isNull,
      );
    });
  });

  test('SheetBrowserLogin waits for the Matrix sign-in scheme', () async {
    String? scheme;
    Uri? opened;
    final login = SheetBrowserLogin(
      authenticate: (url, {required callbackScheme}) async {
        opened = url;
        scheme = callbackScheme;
        return Uri.parse('$kOAuthRedirectUri?code=c&state=s');
      },
    );
    late Uri redirect;
    final callback = await login.run((r) async {
      redirect = r;
      return Uri.parse('https://example.org/authorize');
    }, doneText: 'done');

    expect(redirect, kOAuthRedirectUri);
    expect(scheme, kOAuthRedirectScheme);
    expect(opened, Uri.parse('https://example.org/authorize'));
    expect(callback?.queryParameters['code'], 'c');
  });
}
