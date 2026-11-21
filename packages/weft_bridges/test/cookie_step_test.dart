import 'package:test/test.dart';
import 'package:weft_bridges/weft_bridges.dart';

/// The `cookies` step, as mautrix-meta's Instagram connector sends it.
///
/// The step is copied from a live bridge (mautrix-instagram, 2026-11) with
/// the optional fields trimmed: what the browser has to read, and the address
/// that means the person is signed in.
void main() {
  final step = LoginStep.fromJson({
    'login_id': 'lg',
    'type': 'cookies',
    'step_id': 'fi.mau.meta.cookies',
    'cookies': {
      'url': 'https://www.instagram.com/accounts/login/',
      'wait_for_url_pattern':
          r'^https://www\.instagram\.com/(?:direct/(?:inbox/|t/[0-9]+/)?|accounts/onetap/)?(?:\?.*)?$',
      'fields': [
        for (final id in ['sessionid', 'csrftoken', 'ds_user_id'])
          {
            'id': id,
            'required': true,
            'sources': [
              {'type': 'cookie', 'name': id, 'cookie_domain': 'instagram.com'},
            ],
          },
        {
          'id': 'rur',
          'required': false,
          'sources': [
            {'type': 'cookie', 'name': 'rur', 'cookie_domain': 'instagram.com'},
          ],
        },
        {
          'id': 'token',
          'required': false,
          'sources': [
            {'type': 'request_header', 'name': 'X-Token'},
            {'type': 'local_storage', 'name': 'token'},
          ],
        },
      ],
    },
  });
  final cookies = step.cookies!;

  test('reads the fields and their sources', () {
    expect(cookies.url, 'https://www.instagram.com/accounts/login/');
    expect(cookies.fieldIds, [
      'sessionid',
      'csrftoken',
      'ds_user_id',
      'rur',
      'token',
    ]);
    expect(cookies.fields.first.required, isTrue);
    expect(cookies.fields.first.sources.single.type, 'cookie');
    expect(cookies.fields.first.sources.single.cookieDomain, 'instagram.com');
    expect(cookies.localStorageKeys, ['token']);
  });

  test('the login page is not done; the inbox and one-tap pages are', () {
    expect(
      cookies.isDone('https://www.instagram.com/accounts/login/'),
      isFalse,
    );
    expect(cookies.isDone('https://www.instagram.com/'), isTrue);
    expect(cookies.isDone('https://www.instagram.com/direct/inbox/'), isTrue);
    expect(
      cookies.isDone('https://www.instagram.com/accounts/onetap/?next=%2F'),
      isTrue,
    );
    expect(cookies.isDone('https://www.facebook.com/'), isFalse);
  });

  test('nothing is collected while a required cookie is missing', () {
    expect(cookies.collect({'sessionid': 's', 'csrftoken': 'c'}), isNull);
  });

  test('required and present optional values are collected', () {
    expect(
      cookies.collect(
        {
          'sessionid': 's',
          'csrftoken': 'c',
          'ds_user_id': '42',
          'rur': 'r',
          'unrelated': 'x',
        },
        localStorage: {'token': 't'},
      ),
      {
        'sessionid': 's',
        'csrftoken': 'c',
        'ds_user_id': '42',
        'rur': 'r',
        'token': 't',
      },
    );
  });

  test('an empty cookie counts as missing', () {
    expect(
      cookies.collect({'sessionid': '', 'csrftoken': 'c', 'ds_user_id': '1'}),
      isNull,
    );
  });

  test('without a pattern, the page is never done by address alone', () {
    const bare = LoginCookiesParams(url: 'https://example.org/');
    expect(bare.isDone('https://example.org/'), isFalse);
    expect(bare.collect(const {}), isEmpty);
  });
}
