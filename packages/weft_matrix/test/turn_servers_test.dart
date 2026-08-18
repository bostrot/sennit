import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  final fetchedAt = DateTime.utc(2026, 8, 19, 12);

  group('TurnCredentials', () {
    test('reads what the homeserver returns', () {
      final credentials = TurnCredentials.fromJson({
        'username': '1758283200:@me:example.org',
        'password': 'opensesame',
        'ttl': 86400,
        'uris': [
          'turn:turn.example.org:3478?transport=udp',
          'turns:turn.example.org:443?transport=tcp',
        ],
      }, fetchedAt: fetchedAt);

      expect(credentials, isNotNull);
      expect(credentials!.uris, hasLength(2));
      expect(credentials.ttl, const Duration(days: 1));
      expect(credentials.expiresAt, fetchedAt.add(const Duration(days: 1)));
    });

    test('one ice server entry carries every uri', () {
      // Splitting them per URI would make WebRTC allocate against each in turn,
      // and the credentials are identical for all of them anyway.
      final credentials = TurnCredentials.fromJson({
        'username': 'u',
        'password': 'p',
        'ttl': 3600,
        'uris': ['turn:a:3478', 'turn:b:3478'],
      }, fetchedAt: fetchedAt);

      expect(credentials!.iceServer, {
        'urls': ['turn:a:3478', 'turn:b:3478'],
        'username': 'u',
        'credential': 'p',
      });
    });

    test('stale a margin before expiry, not at it', () {
      final credentials = TurnCredentials.fromJson({
        'username': 'u',
        'password': 'p',
        'ttl': 3600,
        'uris': ['turn:a:3478'],
      }, fetchedAt: fetchedAt)!;

      const margin = Duration(minutes: 2);
      expect(
        credentials.isStaleAt(
          fetchedAt.add(const Duration(minutes: 57)),
          margin: margin,
        ),
        isFalse,
      );
      // Credentials that are valid now but expire in a minute will still be in
      // the peer connection when ICE restarts, and it does not re-ask.
      expect(
        credentials.isStaleAt(
          fetchedAt.add(const Duration(minutes: 59)),
          margin: margin,
        ),
        isTrue,
      );
    });

    test(
      'a body with no uris is a server with no relay, not a parse error',
      () {
        expect(
          TurnCredentials.fromJson(
            const <String, Object?>{},
            fetchedAt: fetchedAt,
          ),
          isNull,
        );
        expect(
          TurnCredentials.fromJson({
            'username': 'u',
            'password': 'p',
            'ttl': 3600,
            'uris': <String>[],
          }, fetchedAt: fetchedAt),
          isNull,
        );
        expect(
          TurnCredentials.fromJson('nonsense', fetchedAt: fetchedAt),
          isNull,
        );
      },
    );

    test('a missing ttl falls back to an hour rather than to no relay', () {
      final credentials = TurnCredentials.fromJson({
        'username': 'u',
        'password': 'p',
        'uris': ['turn:a:3478'],
      }, fetchedAt: fetchedAt);

      expect(credentials!.ttl, const Duration(hours: 1));
    });
  });

  group('MatrixTurnServers', () {
    test('fetches from the v3 voip endpoint with the current token', () async {
      final requests = <http.Request>[];
      final servers = _turnServers(
        clock: () => fetchedAt,
        handler: (request) async {
          requests.add(request);
          return _okResponse();
        },
      );

      final configuration = await servers.configuration();

      expect(configuration.availability, TurnAvailability.available);
      expect(configuration.hasTurn, isTrue);
      expect(configuration.warning, isNull);
      expect(configuration.servers.single['urls'], [
        'turn:turn.example.org:3478',
      ]);

      expect(requests.single.method, 'GET');
      expect(
        requests.single.url.toString(),
        'https://matrix.example.org/_matrix/client/v3/voip/turnServer',
      );
      expect(requests.single.headers['authorization'], 'Bearer token-1');
    });

    test('caches until the refresh margin, then refetches', () async {
      var calls = 0;
      var now = fetchedAt;
      final servers = _turnServers(
        clock: () => now,
        handler: (_) async {
          calls++;
          return _okResponse(ttl: 3600);
        },
      );

      await servers.configuration();
      now = fetchedAt.add(const Duration(minutes: 30));
      await servers.configuration();
      expect(calls, 1, reason: 'still fresh');

      // Two minutes before the hour is up, which is the margin.
      now = fetchedAt.add(const Duration(minutes: 58, seconds: 1));
      await servers.configuration();
      expect(calls, 2, reason: 'refreshed before expiry, not after it');
    });

    test('forceRefresh bypasses a perfectly good cache', () async {
      var calls = 0;
      final servers = _turnServers(
        clock: () => fetchedAt,
        handler: (_) async {
          calls++;
          return _okResponse();
        },
      );

      await servers.configuration();
      await servers.configuration(forceRefresh: true);
      expect(calls, 2);
    });

    test('concurrent callers share one request', () async {
      // Placing a call gathers ICE from more than one place at once; without
      // this the first seconds of a call fire several identical requests.
      var calls = 0;
      final servers = _turnServers(
        clock: () => fetchedAt,
        handler: (_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _okResponse();
        },
      );

      final results = await Future.wait([
        servers.configuration(),
        servers.configuration(),
        servers.configuration(),
      ]);

      expect(calls, 1);
      expect(results.every((r) => r.hasTurn), isTrue);
    });

    test('a 404 means the server has no relay, and says so', () async {
      final servers = _turnServers(
        clock: () => fetchedAt,
        handler: (_) async => http.Response(
          jsonEncode({'errcode': 'M_NOT_FOUND', 'error': 'Not found'}),
          404,
        ),
      );

      final configuration = await servers.configuration();

      expect(configuration.availability, TurnAvailability.notConfigured);
      expect(configuration.hasTurn, isFalse);
      // The whole point of this file: the SDK logs this at verbose level and
      // returns an empty list, which is how a self-hosted call works at home
      // and nowhere else with nothing on screen to explain it.
      expect(configuration.warning, contains('same network'));
      expect(configuration.servers, isEmpty);
    });

    test('a 200 with an empty body means the same thing', () async {
      // Synapse answers this way when turn_uris is unset.
      final servers = _turnServers(
        clock: () => fetchedAt,
        handler: (_) async => http.Response('{}', 200),
      );

      expect(
        (await servers.configuration()).availability,
        TurnAvailability.notConfigured,
      );
    });

    test(
      'an expired session is a sign-in problem, not a relay problem',
      () async {
        final servers = _turnServers(
          clock: () => fetchedAt,
          handler: (_) async =>
              http.Response(jsonEncode({'errcode': 'M_UNKNOWN_TOKEN'}), 401),
        );

        final configuration = await servers.configuration();
        expect(configuration.availability, TurnAvailability.unauthorised);
        expect(configuration.warning, contains('session has expired'));
      },
    );

    test('not being signed in never reaches the network', () async {
      var calls = 0;
      final servers = MatrixTurnServers(
        session: _FakeApiSession(
          accessToken: null,
          client: MockClient((_) async {
            calls++;
            return _okResponse();
          }),
        ),
        clock: () => fetchedAt,
      );

      final configuration = await servers.configuration();
      expect(configuration.availability, TurnAvailability.unauthorised);
      expect(calls, 0);
    });

    test('an unreachable server is a warning, not an exception', () async {
      // A call with no relay is still worth attempting — on one network it
      // works — so this is something to show, not a reason to refuse to dial.
      final servers = _turnServers(
        clock: () => fetchedAt,
        handler: (_) async => throw http.ClientException('offline'),
      );

      final configuration = await servers.configuration();
      expect(configuration.availability, TurnAvailability.unreachable);
      expect(configuration.warning, contains('could not reach'));
      expect(servers.lastFailure, same(configuration));
    });

    test('a 500 and unreadable JSON both read as unreachable', () async {
      final broken = _turnServers(
        clock: () => fetchedAt,
        handler: (_) async => http.Response('not json', 200),
      );
      expect(
        (await broken.configuration()).availability,
        TurnAvailability.unreachable,
      );

      final failing = _turnServers(
        clock: () => fetchedAt,
        handler: (_) async => http.Response('{}', 500),
      );
      expect(
        (await failing.configuration()).availability,
        TurnAvailability.unreachable,
      );
    });

    test('a failure is not cached as a credential', () async {
      var fail = true;
      final servers = _turnServers(
        clock: () => fetchedAt,
        handler: (_) async => fail ? http.Response('{}', 404) : _okResponse(),
      );

      expect((await servers.configuration()).hasTurn, isFalse);
      expect(servers.cached, isNull);

      fail = false;
      expect((await servers.configuration()).hasTurn, isTrue);
      expect(servers.cached, isNotNull);
      expect(servers.lastFailure, isNull);
    });

    test('invalidate drops the cache, e.g. after a logout', () async {
      var calls = 0;
      final servers = _turnServers(
        clock: () => fetchedAt,
        handler: (_) async {
          calls++;
          return _okResponse();
        },
      );

      await servers.configuration();
      servers.invalidate();
      await servers.configuration();

      expect(calls, 2);
      expect(servers.cached, isNotNull);
    });
  });
}

MatrixTurnServers _turnServers({
  required Future<http.Response> Function(http.Request) handler,
  required DateTime Function() clock,
}) {
  return MatrixTurnServers(
    session: _FakeApiSession(client: MockClient(handler)),
    clock: clock,
  );
}

http.Response _okResponse({int ttl = 86400}) => http.Response(
  jsonEncode({
    'username': '1758283200:@me:example.org',
    'password': 'opensesame',
    'ttl': ttl,
    'uris': ['turn:turn.example.org:3478'],
  }),
  200,
  headers: const {'content-type': 'application/json'},
);

class _FakeApiSession implements MatrixApiSession {
  _FakeApiSession({required this.client, this.accessToken = 'token-1'});

  final http.Client client;

  @override
  final String? accessToken;

  @override
  Uri? get baseUrl => Uri.parse('https://matrix.example.org');

  @override
  http.Client get httpClient => client;
}
