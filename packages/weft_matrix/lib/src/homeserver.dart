import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// Turns whatever a user typed into a homeserver URL.
///
/// People type `example.org`, `@me:example.org`, `https://example.org/`, or
/// `matrix.example.org:8448`. All of them should work, because a login screen
/// that rejects `example.org` for missing a scheme is a login screen that loses
/// the user before they start.
///
/// Returns null when the input cannot be a host at all.
Uri? parseHomeserverInput(String raw) {
  var input = raw.trim();
  if (input.isEmpty) return null;

  // A full user id carries the server name after the colon.
  if (input.startsWith('@')) {
    final colon = input.indexOf(':');
    if (colon < 0 || colon == input.length - 1) return null;
    input = input.substring(colon + 1);
  }

  if (!input.contains('://')) {
    // A loopback address is a local test server; those are almost never
    // TLS-terminated, and defaulting to https there fails with an opaque
    // handshake error instead of connecting.
    final host = input.split(':').first;
    final loopback =
        host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.endsWith('.localhost');
    input = '${loopback ? 'http' : 'https'}://$input';
  }

  final uri = Uri.tryParse(input);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;

  // Reject anything that isn't plausibly a hostname. A bare word like "signal"
  // would otherwise resolve to https://signal and fail confusingly later.
  if (!uri.host.contains('.') && uri.host != 'localhost') return null;

  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

/// Where a server's client-server API actually lives, plus what it advertises.
@immutable
class HomeserverDiscovery {
  const HomeserverDiscovery({
    required this.baseUrl,
    this.serverName,
    this.identityServer,
    this.viaWellKnown = false,
  });

  /// The base URL to talk to — the delegated one when `.well-known` redirects.
  final Uri baseUrl;

  /// The server name users' IDs are scoped to (`example.org`), which is often
  /// *not* the host serving the API (`matrix.example.org`).
  final String? serverName;

  final Uri? identityServer;

  /// Whether delegation actually applied, so the UI can say where it landed.
  final bool viaWellKnown;

  @override
  String toString() =>
      'HomeserverDiscovery($baseUrl, serverName: $serverName, '
      'viaWellKnown: $viaWellKnown)';
}

/// Resolves `.well-known/matrix/client` delegation for [input].
///
/// Per the spec, a missing or malformed well-known is not an error — it just
/// means no delegation — so this falls back to the entered URL rather than
/// failing the login.
Future<HomeserverDiscovery> discoverHomeserver(
  Uri input, {
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  final serverName = input.port == 0 || !input.hasPort
      ? input.host
      : '${input.host}:${input.port}';

  try {
    final response = await client
        .get(input.replace(path: '/.well-known/matrix/client'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      return HomeserverDiscovery(baseUrl: input, serverName: serverName);
    }

    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map<String, dynamic>) {
      return HomeserverDiscovery(baseUrl: input, serverName: serverName);
    }

    final homeserver = body['m.homeserver'];
    final delegated = homeserver is Map<String, dynamic>
        ? Uri.tryParse((homeserver['base_url'] as String? ?? '').trim())
        : null;

    final identity = body['m.identity_server'];
    final identityUrl = identity is Map<String, dynamic>
        ? Uri.tryParse((identity['base_url'] as String? ?? '').trim())
        : null;

    if (delegated == null || delegated.host.isEmpty) {
      return HomeserverDiscovery(baseUrl: input, serverName: serverName);
    }

    return HomeserverDiscovery(
      // Trailing slashes in well-known base_url are common and break path
      // joining downstream.
      baseUrl: _stripTrailingSlash(delegated),
      serverName: serverName,
      identityServer: identityUrl,
      viaWellKnown: true,
    );
  } on Exception {
    // No well-known, bad JSON, DNS failure, timeout — all mean "no delegation".
    return HomeserverDiscovery(baseUrl: input, serverName: serverName);
  } finally {
    if (httpClient == null) client.close();
  }
}

Uri _stripTrailingSlash(Uri uri) {
  if (!uri.path.endsWith('/') || uri.path == '/') {
    return uri.path == '/' ? uri.replace(path: '') : uri;
  }
  return uri.replace(path: uri.path.substring(0, uri.path.length - 1));
}
