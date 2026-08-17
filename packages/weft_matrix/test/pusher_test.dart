import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  group('WeftPusher', () {
    test('registers as an http pusher with the event_id_only format', () {
      final json = _pusher().toJson();

      expect(json['kind'], 'http');
      expect(json['app_id'], 'com.bostrot.weft.android');
      expect(json['pushkey'], 'fcm-token-1');
      expect(json['lang'], 'en');

      final data = json['data']! as Map<String, Object?>;
      expect(data['url'], 'https://push.weft.example/_matrix/push/v1/notify');
      // The decision this whole file exists to make: the homeserver sends an
      // event id, never a body, so no plaintext reaches the push gateway.
      expect(data['format'], 'event_id_only');
    });

    test('carries the gateway default payload inside data', () {
      final json = _pusher(
        defaultPayload: const {
          'aps': {'mutable-content': 1},
        },
      ).toJson();

      final data = json['data']! as Map<String, Object?>;
      expect(data['default_payload'], {
        'aps': {'mutable-content': 1},
      });
    });

    test('omits default_payload entirely when there is none', () {
      final data = _pusher().toJson()['data']! as Map<String, Object?>;
      expect(data.containsKey('default_payload'), isFalse);
    });

    test('does not append by default, so one token means one pusher', () {
      expect(_pusher().toJson()['append'], isFalse);
      expect(_pusher().toJson(append: true)['append'], isTrue);
    });

    test('deletion keeps the identity and nulls the kind', () {
      expect(_pusher().deletionJson(), {
        'app_id': 'com.bostrot.weft.android',
        'pushkey': 'fcm-token-1',
        'kind': null,
      });
    });

    test('reads an http pusher back off the server', () {
      final pusher = WeftPusher.fromJson(_serverPusher());

      expect(pusher, isNotNull);
      expect(pusher!.appId, 'com.bostrot.weft.android');
      expect(pusher.pushKey, 'fcm-token-1');
      expect(pusher.gatewayUrl.host, 'push.weft.example');
      expect(pusher, _pusher());
    });

    test('ignores a pusher with no gateway url', () {
      // An `email` pusher on the same account is not this app's.
      expect(
        WeftPusher.fromJson({
          'app_id': 'm.email',
          'pushkey': 'user@example.org',
          'kind': 'email',
          'data': <String, Object?>{},
        }),
        isNull,
      );
    });

    test('identity is app id plus push key, not the whole value', () {
      final a = _pusher();
      final b = _pusher(deviceDisplayName: 'Pixel 9');

      expect(a.hasSameIdentity(b), isTrue);
      expect(a == b, isFalse);
      expect(a.hasSameIdentity(_pusher(pushKey: 'fcm-token-2')), isFalse);
    });
  });

  group('MatrixPusherRegistry.register', () {
    test('posts the registration to the v3 pushers endpoint', () async {
      late http.Request seen;
      final registry = _registryWith(
        MockClient((request) async {
          seen = request;
          return http.Response('{}', 200);
        }),
      );

      await registry.register(_pusher());

      expect(seen.method, 'POST');
      expect(seen.url.path, '/_matrix/client/v3/pushers/set');
      expect(seen.headers['authorization'], 'Bearer token-1');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect((body['data']! as Map)['format'], 'event_id_only');
    });

    test('unregister posts a null kind rather than a DELETE', () async {
      late http.Request seen;
      final registry = _registryWith(
        MockClient((request) async {
          seen = request;
          return http.Response('{}', 200);
        }),
      );

      await registry.unregister(
        appId: 'com.bostrot.weft.android',
        pushKey: 'fcm-token-1',
      );

      expect(seen.method, 'POST');
      expect(seen.url.path, '/_matrix/client/v3/pushers/set');
      expect(jsonDecode(seen.body), {
        'app_id': 'com.bostrot.weft.android',
        'pushkey': 'fcm-token-1',
        'kind': null,
      });
    });

    test('reads the token per call rather than capturing it', () async {
      // The SDK refreshes access tokens underneath us on soft logout.
      final session = _FakeSession(
        MockClient((_) async => http.Response('{}', 200)),
      );
      final registry = MatrixPusherRegistry(session: session);

      session.accessToken = 'refreshed';
      await registry.register(_pusher());

      expect(session.lastAuthorization, 'Bearer refreshed');
    });

    test('refuses without a session and does not offer a retry', () async {
      final session = _FakeSession(
        MockClient((_) async => http.Response('{}', 200)),
      )..accessToken = null;

      await expectLater(
        MatrixPusherRegistry(session: session).register(_pusher()),
        throwsA(
          isA<PusherRegistrationException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.message, 'message', contains('signed in')),
        ),
      );
    });

    test('a rejected pushkey is terminal, a busy server is not', () async {
      final rejected = _registryWith(
        MockClient(
          (_) async => http.Response(
            jsonEncode({'errcode': 'M_UNKNOWN', 'error': 'Invalid pushkey'}),
            400,
          ),
        ),
      );
      await expectLater(
        rejected.register(_pusher()),
        throwsA(
          isA<PusherRegistrationException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.message, 'message', 'Invalid pushkey'),
        ),
      );

      final busy = _registryWith(
        MockClient((_) async => http.Response('{}', 429)),
      );
      await expectLater(
        busy.register(_pusher()),
        throwsA(
          isA<PusherRegistrationException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );

      final broken = _registryWith(
        MockClient((_) async => http.Response('<html>502</html>', 502)),
      );
      await expectLater(
        broken.register(_pusher()),
        throwsA(
          isA<PusherRegistrationException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });

    test('an expired session is reported as such, not as a retry', () async {
      final registry = _registryWith(
        MockClient((_) async => http.Response('{}', 401)),
      );

      await expectLater(
        registry.register(_pusher()),
        throwsA(
          isA<PusherRegistrationException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.message, 'message', contains('expired')),
        ),
      );
    });

    test('an unreachable server is retryable', () async {
      final registry = _registryWith(
        MockClient((_) async => throw http.ClientException('no route')),
      );

      await expectLater(
        registry.register(_pusher()),
        throwsA(
          isA<PusherRegistrationException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });
  });

  group('MatrixPusherRegistry.list', () {
    test('returns only the http pushers with a usable gateway', () async {
      final registry = _registryWith(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'pushers': [
                _serverPusher(),
                {
                  'app_id': 'm.email',
                  'pushkey': 'user@example.org',
                  'kind': 'email',
                  'data': <String, Object?>{},
                },
              ],
            }),
            200,
          ),
        ),
      );

      final pushers = await registry.list();

      expect(pushers, hasLength(1));
      expect(pushers.single.appId, 'com.bostrot.weft.android');
    });

    test('a server with no pushers is empty, not an error', () async {
      final registry = _registryWith(
        MockClient((_) async => http.Response('{"pushers": []}', 200)),
      );
      expect(await registry.list(), isEmpty);
    });
  });

  group('MatrixPusherRegistry.ensureRegistered', () {
    test('writes nothing when the server already agrees', () async {
      var posts = 0;
      final registry = _registryWith(
        MockClient((request) async {
          if (request.method == 'POST') posts++;
          return http.Response(
            jsonEncode({
              'pushers': [_serverPusher()],
            }),
            200,
          );
        }),
      );

      expect(await registry.ensureRegistered(_pusher()), isFalse);
      expect(posts, 0);
    });

    test('rewrites a pusher registered without event_id_only', () async {
      // An older Weft that let the homeserver send bodies to the gateway.
      final stale = _serverPusher()
        ..['data'] = {
          'url': 'https://push.weft.example/_matrix/push/v1/notify',
        };
      var posts = 0;
      final registry = _registryWith(
        MockClient((request) async {
          if (request.method == 'POST') posts++;
          return http.Response(
            jsonEncode({
              'pushers': [stale],
            }),
            200,
          );
        }),
      );

      expect(await registry.ensureRegistered(_pusher()), isTrue);
      expect(posts, 1);
    });

    test('rewrites when the gateway or display name changed', () async {
      var posts = 0;
      final registry = _registryWith(
        MockClient((request) async {
          if (request.method == 'POST') posts++;
          return http.Response(
            jsonEncode({
              'pushers': [_serverPusher()],
            }),
            200,
          );
        }),
      );

      expect(
        await registry.ensureRegistered(_pusher(deviceDisplayName: 'Pixel 9')),
        isTrue,
      );
      expect(posts, 1);
    });

    test('deletes the previous token before registering the new one', () async {
      // FCM reissues tokens; the old pusher does not go away by itself, and the
      // gateway keeps poking a device that will never answer.
      final bodies = <Map<String, Object?>>[];
      final registry = _registryWith(
        MockClient((request) async {
          if (request.method == 'POST') {
            bodies.add(jsonDecode(request.body) as Map<String, Object?>);
          }
          return http.Response(jsonEncode({'pushers': <Object?>[]}), 200);
        }),
      );

      final wrote = await registry.ensureRegistered(
        _pusher(pushKey: 'fcm-token-2'),
        previousPushKey: 'fcm-token-1',
      );

      expect(wrote, isTrue);
      expect(bodies, hasLength(2));
      expect(bodies.first['kind'], isNull);
      expect(bodies.first['pushkey'], 'fcm-token-1');
      expect(bodies.last['kind'], 'http');
      expect(bodies.last['pushkey'], 'fcm-token-2');
    });

    test('leaves other devices alone when the token is unchanged', () async {
      // Every device of the account registers under the same app id with its
      // own token: deleting "the others" would silence the user's other phone.
      final bodies = <Map<String, Object?>>[];
      final registry = _registryWith(
        MockClient((request) async {
          if (request.method == 'POST') {
            bodies.add(jsonDecode(request.body) as Map<String, Object?>);
          }
          return http.Response(
            jsonEncode({
              'pushers': [
                _serverPusher(pushKey: 'other-device-token'),
                _serverPusher(),
              ],
            }),
            200,
          );
        }),
      );

      expect(
        await registry.ensureRegistered(
          _pusher(),
          previousPushKey: 'fcm-token-1',
        ),
        isFalse,
      );
      expect(bodies, isEmpty);
    });
  });
}

WeftPusher _pusher({
  String pushKey = 'fcm-token-1',
  String deviceDisplayName = 'Weft',
  Map<String, Object?> defaultPayload = const {},
}) => WeftPusher(
  appId: 'com.bostrot.weft.android',
  pushKey: pushKey,
  gatewayUrl: Uri.parse('https://push.weft.example/_matrix/push/v1/notify'),
  deviceDisplayName: deviceDisplayName,
  defaultPayload: defaultPayload,
);

Map<String, Object?> _serverPusher({String pushKey = 'fcm-token-1'}) => {
  'app_id': 'com.bostrot.weft.android',
  'pushkey': pushKey,
  'kind': 'http',
  'app_display_name': 'Weft',
  'device_display_name': 'Weft',
  'lang': 'en',
  'data': {
    'url': 'https://push.weft.example/_matrix/push/v1/notify',
    'format': 'event_id_only',
  },
};

MatrixPusherRegistry _registryWith(http.Client client) =>
    MatrixPusherRegistry(session: _FakeSession(client));

class _FakeSession implements MatrixApiSession {
  _FakeSession(this._client);

  final http.Client _client;

  @override
  Uri? baseUrl = Uri.parse('https://matrix.example.org/');

  @override
  String? accessToken = 'token-1';

  String? lastAuthorization;

  @override
  http.Client get httpClient => _RecordingClient(_client, (value) {
    lastAuthorization = value;
  });
}

/// Notes the authorization header actually sent, so "read the token per call"
/// is assertable rather than assumed.
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._inner, this._onAuthorization);

  final http.Client _inner;
  final void Function(String?) _onAuthorization;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    _onAuthorization(request.headers['authorization']);
    return _inner.send(request);
  }
}
