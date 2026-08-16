import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'api_keys.dart';
import 'tool_registry.dart';

/// Serves Weft's tools over MCP's Streamable HTTP transport (POST JSON-RPC).
///
/// Implemented directly on shelf rather than through a heavier server
/// framework: the surface Weft needs — `initialize`, `tools/list`,
/// `tools/call`, `ping` — is small, and owning it keeps the auth path
/// auditable in one file. Server-initiated streams (SSE) are not offered;
/// clients that only POST work fine, which covers the agent use case.
class WeftMcpHttpServer {
  WeftMcpHttpServer({
    required this.registry,
    required Iterable<McpApiKey> Function() loadKeys,
    this.serverName = 'weft',
    this.serverVersion = '0.1.0',
  }) : _loadKeys = loadKeys;

  final WeftToolRegistry registry;

  /// Re-read per request so a key revoked in settings takes effect immediately.
  final Iterable<McpApiKey> Function() _loadKeys;

  final String serverName;
  final String serverVersion;

  HttpServer? _server;

  int? get boundPort => _server?.port;

  /// Binds to loopback only. The tunnel (or an explicit reverse proxy) is the
  /// sole way in from outside, so a misconfigured firewall never exposes the
  /// port directly.
  Future<int> start({int port = 0}) async {
    final server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      port,
    );
    _server = server;
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  /// The shelf handler, public so tests can drive it without a socket.
  Future<Response> handler(Request request) async {
    if (request.method != 'POST') {
      return Response(405, body: 'MCP requests are POSTed JSON-RPC');
    }

    final key = _authenticate(request);
    if (key == null) {
      return Response(
        401,
        headers: {'www-authenticate': 'Bearer'},
        body: jsonEncode({'error': 'Missing or invalid API key'}),
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } on FormatException {
      return _rpcError(null, -32700, 'Parse error');
    }
    if (decoded is! Map<String, Object?>) {
      return _rpcError(null, -32600, 'Expected a JSON-RPC request object');
    }

    final id = decoded['id'];
    final method = decoded['method'] as String?;
    final params = decoded['params'];
    final args = params is Map<String, Object?> ? params : <String, Object?>{};

    switch (method) {
      case 'initialize':
        return _rpcResult(id, {
          'protocolVersion':
              (args['protocolVersion'] as String?) ?? '2025-06-18',
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': serverName, 'version': serverVersion},
        });

      case 'notifications/initialized':
        // A notification: acknowledged with no body.
        return Response(202);

      case 'ping':
        return _rpcResult(id, const <String, Object?>{});

      case 'tools/list':
        return _rpcResult(id, {
          'tools': [
            for (final tool in registry.toolsFor(key))
              {
                'name': tool.name,
                'description': tool.description,
                'inputSchema': tool.inputSchema,
                'annotations': {'readOnlyHint': tool.readOnly},
              },
          ],
        });

      case 'tools/call':
        final name = args['name'] as String?;
        if (name == null) {
          return _rpcError(id, -32602, 'tools/call requires "name"');
        }
        final rawArgs = args['arguments'];
        final outcome = await registry.call(
          name,
          rawArgs is Map<String, Object?> ? rawArgs : const {},
          key: key,
        );
        // Tool failures are results with isError, not protocol errors — per
        // spec, so the model sees the message and can adjust.
        return _rpcResult(id, {
          'content': [
            {'type': 'text', 'text': outcome.asJson},
          ],
          'isError': !outcome.ok,
        });

      default:
        return _rpcError(id, -32601, 'Method not found: $method');
    }
  }

  McpApiKey? _authenticate(Request request) {
    final header = request.headers['authorization'];
    if (header == null || !header.toLowerCase().startsWith('bearer ')) {
      return null;
    }
    final token = header.substring('bearer '.length).trim();
    return registry.keyManager.verify(token, _loadKeys());
  }

  static Response _rpcResult(Object? id, Map<String, Object?> result) =>
      Response.ok(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        headers: {'content-type': 'application/json'},
      );

  static Response _rpcError(Object? id, int code, String message) =>
      Response.ok(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': code, 'message': message},
        }),
        headers: {'content-type': 'application/json'},
      );
}
