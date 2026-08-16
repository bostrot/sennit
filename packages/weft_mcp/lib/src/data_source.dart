import 'package:meta/meta.dart';

/// What the MCP tools can reach.
///
/// The app implements this over the live session, search index and identity
/// graph. Declaring it here keeps `weft_mcp` pure Dart and lets the tool layer
/// be tested against a fake without a homeserver.
abstract class WeftMcpDataSource {
  /// Conversations, newest activity first.
  Future<List<McpChatSummary>> listChats({int limit = 50, String? network});

  /// Recent messages in one chat, newest first.
  Future<List<McpMessage>> getChat(String chatId, {int limit = 50});

  /// Hybrid search across everything.
  Future<List<McpMessage>> searchMessages(
    String query, {
    int limit = 20,
    String? network,
    String? chatId,
    DateTime? after,
    DateTime? before,
  });

  /// Contacts, including which networks each is reachable on.
  Future<List<McpContact>> listContacts({int limit = 100});

  /// Sends a message. [network] picks the leg of a merged chat.
  Future<String> sendMessage(String chatId, String body, {String? network});

  Future<void> markRead(String chatId);

  /// Merges two handles into one contact.
  Future<void> mergeContacts(String handleIdA, String handleIdB);

  /// Bridge health, for "is WhatsApp still connected?".
  Future<List<McpBridgeStatus>> bridgeStatus();
}

@immutable
class McpChatSummary {
  const McpChatSummary({
    required this.id,
    required this.title,
    required this.networks,
    this.unreadCount = 0,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.isMerged = false,
  });

  final String id;
  final String title;
  final List<String> networks;
  final int unreadCount;
  final String? lastMessagePreview;
  final DateTime? lastMessageAt;
  final bool isMerged;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'networks': networks,
    'unread_count': unreadCount,
    'is_merged': isMerged,
    if (lastMessagePreview != null) 'last_message': lastMessagePreview,
    if (lastMessageAt != null)
      'last_message_at': lastMessageAt!.toIso8601String(),
  };
}

@immutable
class McpMessage {
  const McpMessage({
    required this.eventId,
    required this.chatId,
    required this.network,
    required this.sender,
    required this.timestamp,
    required this.body,
    this.chatTitle,
    this.isOwn = false,
    this.kind = 'text',
  });

  final String eventId;
  final String chatId;
  final String? chatTitle;
  final String network;
  final String sender;
  final DateTime timestamp;
  final String body;
  final bool isOwn;
  final String kind;

  Map<String, Object?> toJson() => {
    'event_id': eventId,
    'chat_id': chatId,
    if (chatTitle != null) 'chat': chatTitle,
    'network': network,
    'sender': sender,
    'timestamp': timestamp.toIso8601String(),
    'body': body,
    'is_own': isOwn,
    'kind': kind,
  };
}

@immutable
class McpContact {
  const McpContact({
    required this.id,
    required this.displayName,
    required this.handles,
  });

  final String id;
  final String displayName;

  /// One entry per network the contact is reachable on.
  final List<McpHandle> handles;

  Map<String, Object?> toJson() => {
    'id': id,
    'display_name': displayName,
    'handles': handles.map((h) => h.toJson()).toList(),
    'is_merged': handles.length > 1,
  };
}

@immutable
class McpHandle {
  const McpHandle({
    required this.id,
    required this.network,
    this.displayName,
    this.chatId,
  });

  final String id;
  final String network;
  final String? displayName;
  final String? chatId;

  Map<String, Object?> toJson() => {
    'id': id,
    'network': network,
    if (displayName != null) 'display_name': displayName,
    if (chatId != null) 'chat_id': chatId,
  };
}

@immutable
class McpBridgeStatus {
  const McpBridgeStatus({
    required this.network,
    required this.state,
    this.accountName,
    this.error,
  });

  final String network;
  final String state;
  final String? accountName;
  final String? error;

  Map<String, Object?> toJson() => {
    'network': network,
    'state': state,
    if (accountName != null) 'account': accountName,
    if (error != null) 'error': error,
  };
}
