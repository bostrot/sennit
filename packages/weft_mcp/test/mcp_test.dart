import 'dart:math';

import 'package:test/test.dart';
import 'package:weft_mcp/weft_mcp.dart';

/// Records what was called, so authorisation can be tested by observing
/// whether the underlying action ever happened.
class _FakeDataSource implements WeftMcpDataSource {
  final List<String> calls = [];

  @override
  Future<List<McpChatSummary>> listChats({
    int limit = 50,
    String? network,
  }) async {
    calls.add('listChats(limit:$limit,network:$network)');
    return [
      const McpChatSummary(
        id: 'merged:anna',
        title: 'Anna Maven',
        networks: ['whatsapp', 'signal'],
        unreadCount: 3,
        isMerged: true,
      ),
    ];
  }

  @override
  Future<List<McpMessage>> getChat(String chatId, {int limit = 50}) async {
    calls.add('getChat($chatId,limit:$limit)');
    return [
      McpMessage(
        eventId: r'$1',
        chatId: chatId,
        network: 'signal',
        sender: 'Anna Maven',
        timestamp: DateTime.utc(2026, 8, 15),
        body: 'the watermark holds',
      ),
    ];
  }

  @override
  Future<List<McpMessage>> searchMessages(
    String query, {
    int limit = 20,
    String? network,
    String? chatId,
    DateTime? after,
    DateTime? before,
  }) async {
    calls.add('search($query,limit:$limit,after:$after)');
    return const [];
  }

  @override
  Future<List<McpContact>> listContacts({int limit = 100}) async {
    calls.add('listContacts');
    return const [];
  }

  @override
  Future<String> sendMessage(
    String chatId,
    String body, {
    String? network,
  }) async {
    calls.add('send($chatId,$body,via:$network)');
    return r'$sent';
  }

  @override
  Future<void> markRead(String chatId) async => calls.add('markRead($chatId)');

  @override
  Future<void> mergeContacts(String a, String b) async =>
      calls.add('merge($a,$b)');

  @override
  Future<List<McpBridgeStatus>> bridgeStatus() async {
    calls.add('bridgeStatus');
    return const [McpBridgeStatus(network: 'whatsapp', state: 'CONNECTED')];
  }
}

void main() {
  late _FakeDataSource data;
  late WeftToolRegistry registry;
  late ApiKeyManager keys;

  setUp(() {
    data = _FakeDataSource();
    keys = ApiKeyManager(random: Random(20260815));
    registry = WeftToolRegistry(dataSource: data, keyManager: keys);
  });

  McpApiKey keyWith(Set<McpScope> scopes) =>
      keys.generate(label: 'test', scopes: scopes).record;

  group('key generation and verification', () {
    test('a generated key verifies, and a tampered one does not', () {
      final generated = keys.generate(label: 'laptop', scopes: {McpScope.read});

      expect(keys.verify(generated.secret, [generated.record]), isNotNull);
      expect(keys.verify('${generated.secret}x', [generated.record]), isNull);
    });

    test('the secret is never stored', () {
      final generated = keys.generate(label: 'laptop', scopes: {McpScope.read});
      final serialized = generated.record.toJson().toString();

      expect(serialized, isNot(contains(generated.secret)));
      expect(serialized, contains(generated.record.hash));
    });

    test('two keys are never the same', () {
      final a = keys.generate(label: 'a', scopes: {McpScope.read});
      final b = keys.generate(label: 'b', scopes: {McpScope.read});

      expect(a.secret, isNot(b.secret));
      expect(a.record.id, isNot(b.record.id));
      expect(a.record.salt, isNot(b.record.salt));
    });

    test('a revoked key stops verifying', () {
      final generated = keys.generate(label: 'leaked', scopes: {McpScope.read});
      final revoked = generated.record.copyWith(revoked: true);

      expect(keys.verify(generated.secret, [revoked]), isNull);
    });

    test('a key for another id does not verify against this one', () {
      final a = keys.generate(label: 'a', scopes: {McpScope.read});
      final b = keys.generate(label: 'b', scopes: {McpScope.read});

      expect(keys.verify(a.secret, [b.record]), isNull);
    });

    test('malformed tokens are rejected without throwing', () {
      final generated = keys.generate(label: 'x', scopes: {McpScope.read});
      for (final bad in ['', 'nonsense', 'weft_', 'weft_abc', 'Bearer x']) {
        expect(keys.verify(bad, [generated.record]), isNull, reason: bad);
      }
    });

    test('round-trips through JSON', () {
      final original = keys.generate(
        label: 'agent',
        scopes: {McpScope.read, McpScope.send},
      );
      final restored = McpApiKey.fromJson(original.record.toJson());

      expect(restored.scopes, original.record.scopes);
      expect(keys.verify(original.secret, [restored]), isNotNull);
    });

    test('refuses to mint a key that can do nothing', () {
      expect(
        () => keys.generate(label: 'useless', scopes: const {}),
        throwsArgumentError,
      );
    });
  });

  group('constantTimeEquals', () {
    test('behaves like equality', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'ab'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
    });
  });

  group('scope enforcement', () {
    test('a read key can read', () async {
      final result = await registry.call(
        'list_chats',
        {},
        key: keyWith({McpScope.read}),
      );

      expect(result.ok, isTrue);
      expect(data.calls.single, contains('listChats'));
    });

    test('a read key cannot send, and the send never happens', () async {
      final result = await registry.call('send_message', {
        'chat_id': 'c1',
        'body': 'hello',
      }, key: keyWith({McpScope.read}));

      expect(result.ok, isFalse);
      expect(result.error, contains('send'));
      expect(
        data.calls,
        isEmpty,
        reason: 'a denied call must not reach the data source at all',
      );
    });

    test('a send key cannot merge contacts', () async {
      final result = await registry.call('merge_contacts', {
        'handle_a': 'a',
        'handle_b': 'b',
      }, key: keyWith({McpScope.read, McpScope.send}));

      expect(result.ok, isFalse);
      expect(data.calls, isEmpty);
    });

    test('an admin key still needs the scope for the tool it calls', () async {
      // admin alone does not imply read: scopes are explicit, not hierarchical,
      // so a narrow key cannot be widened by accident.
      final result = await registry.call(
        'list_chats',
        {},
        key: keyWith({McpScope.admin}),
      );

      expect(result.ok, isFalse);
    });

    test('a revoked key is refused everything', () async {
      final revoked = keyWith({McpScope.read}).copyWith(revoked: true);
      final result = await registry.call('list_chats', {}, key: revoked);

      expect(result.ok, isFalse);
      expect(data.calls, isEmpty);
    });

    test('only permitted tools are advertised', () {
      final readOnly = registry.toolsFor(keyWith({McpScope.read}));

      expect(readOnly.map((t) => t.name), contains('search_messages'));
      expect(
        readOnly.map((t) => t.name),
        isNot(contains('send_message')),
        reason: 'offering a tool that always fails is worse than hiding it',
      );
    });

    test('an unknown tool is refused and audited', () async {
      final result = await registry.call(
        'rm_rf',
        {},
        key: keyWith({McpScope.admin}),
      );

      expect(result.ok, isFalse);
      expect(registry.auditLog.denials.single.tool, 'rm_rf');
    });
  });

  group('argument handling', () {
    test('a missing required argument is an error, not a crash', () async {
      final result = await registry.call(
        'get_chat',
        {},
        key: keyWith({McpScope.read}),
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('chat_id'));
    });

    test('an absurd limit is clamped rather than honoured', () async {
      await registry.call('list_chats', {
        'limit': 1000000,
      }, key: keyWith({McpScope.read}));

      expect(data.calls.single, contains('limit:200'));
    });

    test('an empty message body is refused', () async {
      final result = await registry.call('send_message', {
        'chat_id': 'c1',
        'body': '   ',
      }, key: keyWith({McpScope.send}));

      expect(result.ok, isFalse);
      expect(data.calls, isEmpty);
    });

    test('date filters are parsed, and bad ones ignored', () async {
      await registry.call('search_messages', {
        'query': 'x',
        'after': '2026-08-01T00:00:00Z',
      }, key: keyWith({McpScope.read}));
      expect(data.calls.single, contains('after:2026-08-01'));

      data.calls.clear();
      await registry.call('search_messages', {
        'query': 'x',
        'after': 'not a date',
      }, key: keyWith({McpScope.read}));
      expect(data.calls.single, contains('after:null'));
    });

    test('send routes to the requested network', () async {
      final result = await registry.call('send_message', {
        'chat_id': 'merged:anna',
        'body': 'hi',
        'network': 'signal',
      }, key: keyWith({McpScope.send}));

      expect(result.ok, isTrue);
      expect(data.calls.single, contains('via:signal'));
    });
  });

  group('rate limiting', () {
    test('blocks once the window is full, and recovers after it', () async {
      final registry = WeftToolRegistry(
        dataSource: data,
        rateLimiter: RateLimiter(
          maxRequests: 2,
          window: const Duration(minutes: 1),
        ),
      );
      final key = keyWith({McpScope.read});
      final start = DateTime.utc(2026, 8, 15, 12);

      expect(
        (await registry.call('list_chats', {}, key: key, now: start)).ok,
        isTrue,
      );
      expect(
        (await registry.call('list_chats', {}, key: key, now: start)).ok,
        isTrue,
      );

      final blocked = await registry.call(
        'list_chats',
        {},
        key: key,
        now: start,
      );
      expect(blocked.ok, isFalse);
      expect(blocked.error, contains('Rate limit'));

      final later = start.add(const Duration(minutes: 2));
      expect(
        (await registry.call('list_chats', {}, key: key, now: later)).ok,
        isTrue,
      );
    });

    test('is per key, so one noisy agent does not block another', () async {
      final registry = WeftToolRegistry(
        dataSource: data,
        rateLimiter: RateLimiter(maxRequests: 1),
      );
      final noisy = keyWith({McpScope.read});
      final quiet = keyWith({McpScope.read});
      final now = DateTime.utc(2026, 8, 15, 12);

      await registry.call('list_chats', {}, key: noisy, now: now);
      expect(
        (await registry.call('list_chats', {}, key: noisy, now: now)).ok,
        isFalse,
      );
      expect(
        (await registry.call('list_chats', {}, key: quiet, now: now)).ok,
        isTrue,
      );
    });
  });

  group('audit log', () {
    test('records both allowed and denied calls', () async {
      final readKey = keyWith({McpScope.read});
      await registry.call('list_chats', {}, key: readKey);
      await registry.call('send_message', {
        'chat_id': 'c',
        'body': 'x',
      }, key: readKey);

      expect(registry.auditLog.entries, hasLength(2));
      expect(registry.auditLog.entries.first.allowed, isTrue);
      expect(registry.auditLog.denials.single.tool, 'send_message');
    });

    test('is bounded so a long-running server cannot grow forever', () async {
      final log = McpAuditLog(capacity: 5);
      for (var i = 0; i < 20; i++) {
        log.record(
          McpAuditEntry(
            at: DateTime.utc(2026),
            keyId: 'k',
            tool: 'list_chats',
            allowed: true,
          ),
        );
      }
      expect(log.entries, hasLength(5));
    });
  });

  group('cloudflared', () {
    test('extracts a quick-tunnel URL from the banner', () {
      const line =
          '|  https://weft-test-abc.trycloudflare.com                    |';
      expect(extractTunnelUrl(line), 'https://weft-test-abc.trycloudflare.com');
    });

    test('ignores unrelated log lines', () {
      expect(extractTunnelUrl('INF Registered tunnel connection'), isNull);
      expect(extractTunnelUrl('https://example.com'), isNull);
    });
  });
}
