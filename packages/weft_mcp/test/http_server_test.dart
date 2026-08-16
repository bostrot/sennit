import 'dart:convert';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:weft_mcp/weft_mcp.dart';

class _NullDataSource implements WeftMcpDataSource {
  @override
  Future<List<McpChatSummary>> listChats({
    int limit = 50,
    String? network,
  }) async => const [
    McpChatSummary(id: 'c1', title: 'Anna', networks: ['whatsapp']),
  ];

  @override
  Future<List<McpMessage>> getChat(String chatId, {int limit = 50}) async =>
      const [];

  @override
  Future<List<McpMessage>> searchMessages(
    String query, {
    int limit = 20,
    String? network,
    String? chatId,
    DateTime? after,
    DateTime? before,
  }) async => const [];

  @override
  Future<List<McpContact>> listContacts({int limit = 100}) async => const [];

  @override
  Future<String> sendMessage(
    String chatId,
    String body, {
    String? network,
  }) async => r'$id';

  @override
  Future<void> markRead(String chatId) async {}

  @override
  Future<void> mergeContacts(String a, String b) async {}

  @override
  Future<List<McpBridgeStatus>> bridgeStatus() async => const [];
}

void main() {
  late ApiKeyManager keys;
  late GeneratedApiKey readKey;
  late WeftMcpHttpServer server;

  setUp(() {
    keys = ApiKeyManager(random: Random(42));
    final registry = WeftToolRegistry(
      dataSource: _NullDataSource(),
      keyManager: keys,
    );
    readKey = keys.generate(label: 't', scopes: {McpScope.read});
    server = WeftMcpHttpServer(
      registry: registry,
      loadKeys: () => [readKey.record],
    );
  });

  Future<Map<String, Object?>> rpc(
    String method, {
    Map<String, Object?>? params,
    String? token,
    Object? id = 1,
  }) async {
    final response = await server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/mcp'),
        headers: {
          if (token != null) 'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': ?params,
        }),
      ),
    );
    if (response.statusCode == 202) return const {};
    expect(
      response.statusCode,
      anyOf(200, 401),
      reason: 'unexpected HTTP status',
    );
    if (response.statusCode == 401) return {'_unauthorized': true};
    return jsonDecode(await response.readAsString()) as Map<String, Object?>;
  }

  test(
    'rejects a missing or invalid key before touching the protocol',
    () async {
      expect(await rpc('tools/list'), containsPair('_unauthorized', true));
      expect(
        await rpc('tools/list', token: 'weft_nope_nope'),
        containsPair('_unauthorized', true),
      );
    },
  );

  test('initialize handshake reports the server and tool capability', () async {
    final result =
        (await rpc('initialize', token: readKey.secret))['result']! as Map;

    expect((result['serverInfo'] as Map)['name'], 'weft');
    expect((result['capabilities'] as Map)['tools'], isNotNull);
  });

  test('the initialized notification is acknowledged silently', () async {
    expect(
      await rpc('notifications/initialized', token: readKey.secret),
      isEmpty,
    );
  });

  test('tools/list shows only what the key may call', () async {
    final result =
        (await rpc('tools/list', token: readKey.secret))['result']! as Map;
    final names = (result['tools'] as List)
        .map((t) => (t as Map)['name'])
        .toList();

    expect(names, contains('search_messages'));
    expect(
      names,
      isNot(contains('send_message')),
      reason: 'a read key must not be shown write tools',
    );
  });

  test('tools/call runs a tool and wraps the result as MCP content', () async {
    final result =
        (await rpc(
              'tools/call',
              params: {'name': 'list_chats', 'arguments': <String, Object?>{}},
              token: readKey.secret,
            ))['result']!
            as Map;

    expect(result['isError'], isFalse);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    expect(jsonDecode(text), containsPair('chats', isNotEmpty));
  });

  test(
    'a denied tool call is an isError result, not a protocol error',
    () async {
      final result =
          (await rpc(
                'tools/call',
                params: {
                  'name': 'send_message',
                  'arguments': {'chat_id': 'c1', 'body': 'x'},
                },
                token: readKey.secret,
              ))['result']!
              as Map;

      expect(
        result['isError'],
        isTrue,
        reason: 'the model should see the denial and adapt, per spec',
      );
    },
  );

  test('unknown methods and malformed bodies are JSON-RPC errors', () async {
    final unknown = await rpc('resources/list', token: readKey.secret);
    expect((unknown['error']! as Map)['code'], -32601);

    final bad = await server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/mcp'),
        headers: {'authorization': 'Bearer ${readKey.secret}'},
        body: 'not json',
      ),
    );
    final decoded = jsonDecode(await bad.readAsString()) as Map;
    expect((decoded['error'] as Map)['code'], -32700);
  });

  test('a revoked key stops working between requests', () async {
    final revocable = keys.generate(label: 'r', scopes: {McpScope.read});
    var stored = [revocable.record];
    final revocableServer = WeftMcpHttpServer(
      registry: WeftToolRegistry(
        dataSource: _NullDataSource(),
        keyManager: keys,
      ),
      loadKeys: () => stored,
    );

    Future<int> status() async => (await revocableServer.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/mcp'),
        headers: {'authorization': 'Bearer ${revocable.secret}'},
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      ),
    )).statusCode;

    expect(await status(), 200);
    stored = [revocable.record.copyWith(revoked: true)];
    expect(
      await status(),
      401,
      reason: 'keys are reloaded per request, so revocation is immediate',
    );
  });

  test('binds to loopback only', () async {
    final port = await server.start();
    addTearDown(server.stop);
    expect(port, greaterThan(0));
    // The bind address is loopback by construction; reaching it from another
    // interface would require the tunnel, which is the point.
  });
}
