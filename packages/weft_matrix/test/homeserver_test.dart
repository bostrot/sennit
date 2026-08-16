import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  group('parseHomeserverInput', () {
    test('accepts a bare domain', () {
      expect(
        parseHomeserverInput('example.org').toString(),
        'https://example.org',
      );
    });

    test('accepts a full URL and drops the path', () {
      expect(
        parseHomeserverInput('https://example.org/').toString(),
        'https://example.org',
      );
      expect(
        parseHomeserverInput('https://example.org/_matrix/').toString(),
        'https://example.org',
      );
    });

    test('extracts the server name from a full user id', () {
      expect(
        parseHomeserverInput('@erict:bostrot.com').toString(),
        'https://bostrot.com',
      );
    });

    test('keeps an explicit port', () {
      expect(
        parseHomeserverInput('matrix.example.org:8448').toString(),
        'https://matrix.example.org:8448',
      );
    });

    test('allows http for a local test server', () {
      expect(
        parseHomeserverInput('http://localhost:8008').toString(),
        'http://localhost:8008',
      );
    });

    test('defaults loopback hosts to http rather than https', () {
      // A local Synapse is almost never TLS-terminated; defaulting to https
      // fails with an opaque handshake error instead of connecting.
      expect(
        parseHomeserverInput('localhost:8008').toString(),
        'http://localhost:8008',
      );
      expect(
        parseHomeserverInput('127.0.0.1:8008').toString(),
        'http://127.0.0.1:8008',
      );
      expect(
        parseHomeserverInput('synapse.localhost').toString(),
        'http://synapse.localhost',
      );
    });

    test('still defaults real hosts to https', () {
      expect(parseHomeserverInput('bostrot.com')!.scheme, 'https');
      expect(parseHomeserverInput('notlocalhost.com')!.scheme, 'https');
    });

    test('trims surrounding whitespace', () {
      expect(
        parseHomeserverInput('  example.org  ').toString(),
        'https://example.org',
      );
    });

    test('rejects input that cannot be a host', () {
      // A bare word would otherwise become https://signal and fail much later
      // with a confusing network error.
      expect(parseHomeserverInput('signal'), isNull);
      expect(parseHomeserverInput(''), isNull);
      expect(parseHomeserverInput('   '), isNull);
      expect(parseHomeserverInput('@erict'), isNull);
      expect(parseHomeserverInput('ftp://example.org'), isNull);
    });
  });

  group('discoverHomeserver', () {
    test('follows .well-known delegation', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/.well-known/matrix/client');
        return http.Response(
          jsonEncode({
            'm.homeserver': {'base_url': 'https://matrix.example.org'},
            'm.identity_server': {'base_url': 'https://id.example.org'},
          }),
          200,
        );
      });

      final result = await discoverHomeserver(
        Uri.parse('https://example.org'),
        httpClient: client,
      );

      expect(result.baseUrl.toString(), 'https://matrix.example.org');
      expect(
        result.serverName,
        'example.org',
        reason: 'user ids stay scoped to the delegating domain',
      );
      expect(result.identityServer.toString(), 'https://id.example.org');
      expect(result.viaWellKnown, isTrue);
    });

    test('strips a trailing slash from the delegated base URL', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'm.homeserver': {'base_url': 'https://matrix.example.org/'},
          }),
          200,
        ),
      );

      final result = await discoverHomeserver(
        Uri.parse('https://example.org'),
        httpClient: client,
      );

      expect(result.baseUrl.toString(), 'https://matrix.example.org');
    });

    test('falls back to the entered URL when there is no well-known', () async {
      final client = MockClient((_) async => http.Response('', 404));

      final result = await discoverHomeserver(
        Uri.parse('https://example.org'),
        httpClient: client,
      );

      expect(result.baseUrl.toString(), 'https://example.org');
      expect(result.viaWellKnown, isFalse);
    });

    test('falls back when the well-known is malformed', () async {
      // A broken well-known must not block login — the spec treats it as
      // simply "no delegation".
      final client = MockClient((_) async => http.Response('not json', 200));

      final result = await discoverHomeserver(
        Uri.parse('https://example.org'),
        httpClient: client,
      );

      expect(result.baseUrl.toString(), 'https://example.org');
      expect(result.viaWellKnown, isFalse);
    });

    test('falls back when the request fails outright', () async {
      final client = MockClient((_) async => throw const SocketExceptionStub());

      final result = await discoverHomeserver(
        Uri.parse('https://example.org'),
        httpClient: client,
      );

      expect(result.baseUrl.toString(), 'https://example.org');
    });
  });
}

/// Stands in for a network failure without importing dart:io into the test.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
