import 'dart:convert';

import 'package:meta/meta.dart';

import 'api_keys.dart';
import 'data_source.dart';

/// One MCP tool: its schema, the scope it needs, and how to run it.
@immutable
class WeftTool {
  const WeftTool({
    required this.name,
    required this.description,
    required this.scope,
    required this.inputSchema,
    required this.handler,
    this.readOnly = true,
  });

  final String name;
  final String description;

  /// Minimum scope a key must hold.
  final McpScope scope;

  /// JSON Schema for the arguments.
  final Map<String, Object?> inputSchema;

  final Future<Object?> Function(Map<String, Object?> args) handler;

  /// Advertised to clients as a hint that the call has no side effects.
  final bool readOnly;
}

/// Result of attempting a tool call.
@immutable
class ToolCallOutcome {
  const ToolCallOutcome({required this.ok, this.payload, this.error});

  final bool ok;
  final Object? payload;
  final String? error;

  /// JSON text, which is what MCP clients ultimately receive.
  String get asJson => const JsonEncoder.withIndent(
    '  ',
  ).convert(ok ? payload : {'error': error});
}

/// Weft's MCP tool surface, plus the auth gate every call passes through.
///
/// Scope checking, rate limiting and audit logging live here rather than in the
/// transport, so they hold however the server is reached — a local port, a
/// Cloudflare tunnel, or an in-process test.
class WeftToolRegistry {
  WeftToolRegistry({
    required WeftMcpDataSource dataSource,
    ApiKeyManager? keyManager,
    RateLimiter? rateLimiter,
    McpAuditLog? auditLog,
  }) : _data = dataSource,
       keyManager = keyManager ?? ApiKeyManager(),
       rateLimiter = rateLimiter ?? RateLimiter(),
       auditLog = auditLog ?? McpAuditLog() {
    _tools = {for (final tool in _build()) tool.name: tool};
  }

  final WeftMcpDataSource _data;
  final ApiKeyManager keyManager;
  final RateLimiter rateLimiter;
  final McpAuditLog auditLog;

  late final Map<String, WeftTool> _tools;

  List<WeftTool> get tools => _tools.values.toList(growable: false);

  /// Tools a key may see. A key without `send` should not be shown
  /// `send_message` at all — offering a tool that always fails is worse than
  /// not offering it.
  List<WeftTool> toolsFor(McpApiKey key) =>
      _tools.values.where((t) => key.allows(t.scope)).toList(growable: false);

  /// Runs [name] on behalf of [key], enforcing scope and rate limits.
  Future<ToolCallOutcome> call(
    String name,
    Map<String, Object?> args, {
    required McpApiKey key,
    DateTime? now,
  }) async {
    final tool = _tools[name];

    if (tool == null) {
      _audit(key, name, false, 'unknown tool', now);
      return const ToolCallOutcome(ok: false, error: 'Unknown tool');
    }
    if (!key.allows(tool.scope)) {
      _audit(key, name, false, 'missing ${tool.scope.name} scope', now);
      return ToolCallOutcome(
        ok: false,
        error: 'This key lacks the "${tool.scope.name}" scope',
      );
    }
    if (!rateLimiter.allow(key.id, now: now)) {
      _audit(key, name, false, 'rate limited', now);
      return const ToolCallOutcome(ok: false, error: 'Rate limit exceeded');
    }

    try {
      final payload = await tool.handler(args);
      _audit(key, name, true, null, now);
      return ToolCallOutcome(ok: true, payload: payload);
    } on ArgumentError catch (e) {
      _audit(key, name, false, 'bad arguments', now);
      return ToolCallOutcome(ok: false, error: e.message.toString());
    } on Exception catch (e) {
      _audit(key, name, false, '$e', now);
      return ToolCallOutcome(ok: false, error: '$e');
    }
  }

  void _audit(
    McpApiKey key,
    String tool,
    bool allowed,
    String? detail,
    DateTime? now,
  ) {
    auditLog.record(
      McpAuditEntry(
        at: now ?? DateTime.now(),
        keyId: key.id,
        tool: tool,
        allowed: allowed,
        detail: detail,
      ),
    );
  }

  // ------------------------------------------------------------------ tools

  List<WeftTool> _build() => [
    WeftTool(
      name: 'list_chats',
      description:
          'List conversations, newest activity first. Merged chats appear '
          'once, with every network they span.',
      scope: McpScope.read,
      inputSchema: {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer', 'default': 50},
          'network': {
            'type': 'string',
            'description': 'Filter to one network, e.g. "whatsapp".',
          },
        },
      },
      handler: (args) async {
        final chats = await _data.listChats(
          limit: _int(args['limit'], 50, max: 200),
          network: args['network'] as String?,
        );
        return {'chats': chats.map((c) => c.toJson()).toList()};
      },
    ),
    WeftTool(
      name: 'get_chat',
      description: 'Read recent messages from one conversation.',
      scope: McpScope.read,
      inputSchema: {
        'type': 'object',
        'properties': {
          'chat_id': {'type': 'string'},
          'limit': {'type': 'integer', 'default': 50},
        },
        'required': ['chat_id'],
      },
      handler: (args) async {
        final messages = await _data.getChat(
          _requiredString(args, 'chat_id'),
          limit: _int(args['limit'], 50, max: 200),
        );
        return {'messages': messages.map((m) => m.toJson()).toList()};
      },
    ),
    WeftTool(
      name: 'search_messages',
      description:
          'Hybrid keyword and semantic search across every conversation. '
          'Finds messages by meaning as well as by exact wording, and '
          'includes transcribed voice notes.',
      scope: McpScope.read,
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'limit': {'type': 'integer', 'default': 20},
          'network': {'type': 'string'},
          'chat_id': {'type': 'string'},
          'after': {'type': 'string', 'format': 'date-time'},
          'before': {'type': 'string', 'format': 'date-time'},
        },
        'required': ['query'],
      },
      handler: (args) async {
        final results = await _data.searchMessages(
          _requiredString(args, 'query'),
          limit: _int(args['limit'], 20, max: 100),
          network: args['network'] as String?,
          chatId: args['chat_id'] as String?,
          after: _dateTime(args['after']),
          before: _dateTime(args['before']),
        );
        return {'results': results.map((m) => m.toJson()).toList()};
      },
    ),
    WeftTool(
      name: 'list_contacts',
      description:
          'List contacts and the networks each is reachable on, including '
          'which have been merged.',
      scope: McpScope.read,
      inputSchema: {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer', 'default': 100},
        },
      },
      handler: (args) async {
        final contacts = await _data.listContacts(
          limit: _int(args['limit'], 100, max: 500),
        );
        return {'contacts': contacts.map((c) => c.toJson()).toList()};
      },
    ),
    WeftTool(
      name: 'bridge_status',
      description:
          'Report each bridge connection, so a disconnected network can be '
          'noticed before messages are missed.',
      scope: McpScope.read,
      inputSchema: {'type': 'object', 'properties': {}},
      handler: (_) async {
        final statuses = await _data.bridgeStatus();
        return {'bridges': statuses.map((b) => b.toJson()).toList()};
      },
    ),
    WeftTool(
      name: 'send_message',
      description:
          'Send a message. For a merged chat, "network" chooses which one '
          'it goes out on; omitted, it follows the chat\'s current default.',
      scope: McpScope.send,
      readOnly: false,
      inputSchema: {
        'type': 'object',
        'properties': {
          'chat_id': {'type': 'string'},
          'body': {'type': 'string'},
          'network': {'type': 'string'},
        },
        'required': ['chat_id', 'body'],
      },
      handler: (args) async {
        final body = _requiredString(args, 'body');
        if (body.trim().isEmpty) {
          throw ArgumentError('Refusing to send an empty message');
        }
        final eventId = await _data.sendMessage(
          _requiredString(args, 'chat_id'),
          body,
          network: args['network'] as String?,
        );
        return {'event_id': eventId, 'sent': true};
      },
    ),
    WeftTool(
      name: 'mark_read',
      description: 'Mark a conversation as read, across all merged legs.',
      scope: McpScope.send,
      readOnly: false,
      inputSchema: {
        'type': 'object',
        'properties': {
          'chat_id': {'type': 'string'},
        },
        'required': ['chat_id'],
      },
      handler: (args) async {
        await _data.markRead(_requiredString(args, 'chat_id'));
        return {'ok': true};
      },
    ),
    WeftTool(
      name: 'merge_contacts',
      description:
          'Merge two handles into one contact, so their conversations '
          'appear as a single thread.',
      scope: McpScope.admin,
      readOnly: false,
      inputSchema: {
        'type': 'object',
        'properties': {
          'handle_a': {'type': 'string'},
          'handle_b': {'type': 'string'},
        },
        'required': ['handle_a', 'handle_b'],
      },
      handler: (args) async {
        await _data.mergeContacts(
          _requiredString(args, 'handle_a'),
          _requiredString(args, 'handle_b'),
        );
        return {'merged': true};
      },
    ),
  ];

  static String _requiredString(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is! String || value.isEmpty) {
      throw ArgumentError('"$key" is required');
    }
    return value;
  }

  /// Clamps a client-supplied limit. An agent asking for 100000 results should
  /// get a sane page, not exhaust memory.
  static int _int(Object? raw, int fallback, {required int max}) {
    final value = raw is int ? raw : int.tryParse('$raw');
    if (value == null || value <= 0) return fallback;
    return value > max ? max : value;
  }

  static DateTime? _dateTime(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}
