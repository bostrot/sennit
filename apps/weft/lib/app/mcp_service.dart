import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_mcp/weft_mcp.dart';
import 'package:weft_richtext/weft_richtext.dart';
import 'package:weft_search/weft_search.dart';
import 'package:weft_store/weft_store.dart';

import '../data/chat_repository.dart';
import 'providers.dart';
import 'search_providers.dart';
import 'stores.dart';

/// [WeftMcpDataSource] over the live app state — the seam between the MCP
/// tool surface and everything Weft actually knows.
class AppMcpDataSource implements WeftMcpDataSource {
  AppMcpDataSource(this._ref);

  final Ref _ref;

  ChatRepository get _repo => _ref.read(chatRepositoryProvider);
  SearchEngine get _search => _ref.read(searchEngineProvider);

  List<Chat> get _chats {
    final chats = _ref.read(chatsProvider).value;
    return chats ?? const [];
  }

  @override
  Future<List<McpChatSummary>> listChats({
    int limit = 50,
    String? network,
  }) async {
    var chats = _chats;
    if (network != null) {
      final wanted = ChatNetwork.fromId(network);
      chats = chats.where((c) => c.networks.contains(wanted)).toList();
    }
    return [
      for (final chat in chats.take(limit))
        McpChatSummary(
          id: chat.id,
          title: chat.title,
          networks: [for (final n in chat.networks) n.id],
          unreadCount: chat.unreadCount,
          isMerged: chat.isMerged,
          lastMessagePreview: chat.lastMessage?.body,
          lastMessageAt: chat.lastMessage?.timestamp,
        ),
    ];
  }

  @override
  Future<List<McpMessage>> getChat(String chatId, {int limit = 50}) async {
    final timeline = await _repo.timelineFor(chatId);
    var view = timeline.view();
    // Pull enough history to honour the requested window.
    while (view.messages.length < limit && timeline.hasMoreHistory) {
      view = await timeline.loadMoreUntilVisibleGrowth();
      if (view.messages.isEmpty) break;
    }
    return [for (final m in view.messages.take(limit)) _toMcp(m, chatId)];
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
    final results = await _search.search(
      SearchQuery(
        text: query,
        limit: limit,
        networks: network == null ? const {} : {ChatNetwork.fromId(network)},
        chatIds: chatId == null ? const {} : {chatId},
        after: after,
        before: before,
      ),
    );
    return [
      for (final r in results)
        McpMessage(
          eventId: r.eventId,
          chatId: r.chatId,
          network: r.network.id,
          sender: r.senderId,
          timestamp: r.timestamp,
          body: r.body,
          kind: r.kind.name,
        ),
    ];
  }

  @override
  Future<List<McpContact>> listContacts({int limit = 100}) async {
    return [
      for (final contact in _repo.identityGraph.contacts().take(limit))
        McpContact(
          id: contact.id,
          displayName: contact.displayName,
          handles: [
            for (final handle in contact.handles)
              McpHandle(
                id: handle.id,
                network: handle.network.id,
                displayName: handle.displayName,
                chatId: handle.roomId,
              ),
          ],
        ),
    ];
  }

  @override
  Future<String> sendMessage(
    String chatId,
    String body, {
    String? network,
  }) async {
    await _repo.send(
      chatId,
      body,
      via: network == null ? null : ChatNetwork.fromId(network),
    );
    return 'sent';
  }

  @override
  Future<void> markRead(String chatId) => _repo.markRead(chatId);

  @override
  Future<void> mergeContacts(String handleIdA, String handleIdB) =>
      _repo.mergeHandles(handleIdA, handleIdB);

  @override
  Future<List<McpBridgeStatus>> bridgeStatus() async {
    // Bridge health lives in the bridges screen's probes; from MCP's side the
    // honest minimal answer is which networks currently have rooms syncing.
    return [
      for (final network in _repo.availableNetworks)
        McpBridgeStatus(network: network.id, state: 'SYNCING'),
    ];
  }

  static McpMessage _toMcp(WeftMessage m, String chatId) => McpMessage(
    eventId: m.eventId,
    chatId: chatId,
    network: m.network.id,
    sender: m.senderName,
    timestamp: m.timestamp,
    // The projection, not the raw body: an MCP client is a program reading
    // messages on the user's behalf, and handing it markup makes it either
    // render tags to whoever asked or parse untrusted HTML itself.
    body: plainTextOf(m),
    isOwn: m.isOwn,
    kind: m.kind.name,
  );
}

const String _mcpKeysSetting = 'mcp.api_keys';

/// Owns the MCP server lifecycle and its key ring.
class McpService {
  McpService(this._ref) {
    final registry = WeftToolRegistry(dataSource: AppMcpDataSource(_ref));
    _registry = registry;
    _server = WeftMcpHttpServer(registry: registry, loadKeys: loadKeys);
    _tunnel = CloudflaredSupervisor();
  }

  final Ref _ref;
  late final WeftToolRegistry _registry;
  late final WeftMcpHttpServer _server;
  late final CloudflaredSupervisor _tunnel;

  int? get boundPort => _server.boundPort;
  CloudflaredSupervisor get tunnel => _tunnel;
  McpAuditLog get auditLog => _registry.auditLog;

  SettingsStore get _settings => _ref.read(storesProvider).settings;

  List<McpApiKey> loadKeys() {
    final json = _settings.getJson(_mcpKeysSetting);
    final list = json?['keys'];
    if (list is! List) return const [];
    return [
      for (final entry in list.whereType<Map>())
        McpApiKey.fromJson(entry.cast<String, Object?>()),
    ];
  }

  void _saveKeys(List<McpApiKey> keys) {
    _settings.setJson(_mcpKeysSetting, {
      'keys': [for (final k in keys) k.toJson()],
    });
  }

  /// Mints a key. The returned secret is shown once and never stored.
  GeneratedApiKey createKey({
    required String label,
    required Set<McpScope> scopes,
  }) {
    final generated = _registry.keyManager.generate(
      label: label,
      scopes: scopes,
    );
    _saveKeys([...loadKeys(), generated.record]);
    return generated;
  }

  void revokeKey(String keyId) {
    _saveKeys([
      for (final key in loadKeys())
        if (key.id == keyId) key.copyWith(revoked: true) else key,
    ]);
  }

  Future<int> start() async {
    final port = _settings.getInt(WeftSettings.mcpPort) ?? 0;
    final bound = await _server.start(port: port);
    _settings.setInt(WeftSettings.mcpPort, bound);

    if (_settings.getBool(WeftSettings.mcpTunnelEnabled)) {
      final token = await _ref
          .read(storesProvider)
          .secrets
          .read(SecretStore.mcpTunnelToken);
      await _tunnel.start(localPort: bound, token: token);
    }
    return bound;
  }

  Future<void> stop() async {
    await _server.stop();
    await _tunnel.stop();
  }

  Future<void> dispose() async {
    await stop();
    await _tunnel.dispose();
  }
}

final mcpServiceProvider = Provider<McpService>((ref) {
  final service = McpService(ref);
  ref.onDispose(service.dispose);
  return service;
});
