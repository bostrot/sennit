import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:weft_domain/weft_domain.dart';

import '../ai/auto_reply_service.dart' show AutoReplyEndpoint;
import '../ai/conversation_context.dart';
import 'todo_assistant.dart';
import 'todo_item.dart';

/// How long a conversation has to be quiet before it is read.
///
/// People ask in three bubbles: "hey", "could you bring the cable", "the long
/// one". Reading after each would be three completions, the first two of them
/// about a request that has not been made yet.
const Duration kTodoSettle = Duration(seconds: 20);

/// Watches messages and keeps the to-do list in step with them.
///
/// Off unless the user switched it on, and dormant without an endpoint. A
/// message reaches the model only when [mightConcernTodo] thinks it could
/// matter, or when the chat already has open entries the assistant could tick
/// off. The context it sends is the same bounded, in-memory buffer the other
/// AI features use — what arrived this session, never history fetched for the
/// purpose.
///
/// The orchestration only, like `AutoReplyService`: the prompt and the parser
/// are [proposeTodoChanges], the list is whatever [apply] writes to, and every
/// lookup is a function read per message so a switch flipped in settings
/// affects the next message.
class TodoAgent {
  TodoAgent({
    required Stream<WeftMessage> incoming,
    required Chat? Function(String roomId) chatForRoom,
    required bool Function(String chatId) isServiceChat,
    required bool Function(Chat chat) isBroadcast,
    required bool Function() enabled,
    required AutoReplyEndpoint? Function() endpoint,
    required List<TodoItem> Function(String chatId) openItemsFor,
    required void Function(Chat chat, TodoChanges changes) apply,
    TodoProposer? proposer,
    Duration settle = kTodoSettle,
    DateTime Function()? now,
  }) : _incoming = incoming,
       _chatForRoom = chatForRoom,
       _isServiceChat = isServiceChat,
       _isBroadcast = isBroadcast,
       _enabled = enabled,
       _endpoint = endpoint,
       _openItemsFor = openItemsFor,
       _apply = apply,
       _proposer = proposer ?? proposeTodoChanges,
       _settle = settle,
       _now = now ?? DateTime.now;

  final Stream<WeftMessage> _incoming;
  final Chat? Function(String roomId) _chatForRoom;
  final bool Function(String chatId) _isServiceChat;
  final bool Function(Chat chat) _isBroadcast;
  final bool Function() _enabled;
  final AutoReplyEndpoint? Function() _endpoint;
  final List<TodoItem> Function(String chatId) _openItemsFor;
  final void Function(Chat chat, TodoChanges changes) _apply;
  final TodoProposer _proposer;
  final Duration _settle;
  final DateTime Function() _now;

  StreamSubscription<WeftMessage>? _sub;
  final ConversationContext<WeftMessage> _context =
      ConversationContext<WeftMessage>();
  final Map<String, Timer> _timers = {};
  final Set<String> _inFlight = {};

  /// Conversations that changed while their completion was running, read
  /// again once it lands so the newest message is never the one skipped.
  final Set<String> _dirty = {};

  void start() {
    _sub ??= _incoming.listen(
      (message) => unawaited(handleMessage(message)),
      onError: (Object error) =>
          debugPrint('weft: to-do stream failed: $error'),
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _context.clear();
  }

  /// Remembers [message] and, when it might matter, schedules a read of its
  /// conversation. With a zero settle the read happens before this returns,
  /// which is what the tests use.
  Future<void> handleMessage(WeftMessage message) async {
    final chat = _chatForRoom(message.roomId);
    if (chat == null) return;
    if (_isServiceChat(chat.id) || _isBroadcast(chat)) return;
    if (chat.isPendingRequest) return;
    if (message.kind != MessageKind.text || message.redacted) return;

    // Remembered even while the feature is off, so switching it on mid-way
    // through a conversation reads the conversation, not its last line.
    _context.remember(chat.id, message);
    // A reply Braid wrote itself is not something the user promised.
    if (message.isAutoReply) return;
    if (!_enabled() || _endpoint() == null) return;

    final cue = mightConcernTodo(message.searchableText);
    if (!cue && _openItemsFor(chat.id).isEmpty) return;

    if (_settle == Duration.zero) return review(chat.id);
    _timers.remove(chat.id)?.cancel();
    _timers[chat.id] = Timer(_settle, () {
      _timers.remove(chat.id);
      unawaited(review(chat.id));
    });
  }

  /// Reads [chatId]'s conversation and applies whatever the model proposes.
  Future<void> review(String chatId) async {
    if (!_inFlight.add(chatId)) {
      _dirty.add(chatId);
      return;
    }
    try {
      final recent = _context.of(chatId);
      if (recent.isEmpty) return;
      final chat = _chatForRoom(recent.last.roomId);
      final endpoint = _endpoint();
      if (chat == null || endpoint == null || !_enabled()) return;

      final open = _openItemsFor(chatId);
      final changes = await _proposer(
        baseUrl: endpoint.baseUrl,
        model: endpoint.model,
        apiKey: endpoint.apiKey,
        chatTitle: chat.title,
        transcript: transcriptLinesFor(recent),
        open: open,
        today: _now(),
      );
      if (changes == null || changes.isEmpty) return;
      // Switched off while the model was thinking: drop the answer.
      if (!_enabled()) return;
      _apply(chat, changes);
    } on Object catch (error) {
      debugPrint('weft: to-do review of $chatId failed: $error');
    } finally {
      _inFlight.remove(chatId);
      if (_dirty.remove(chatId)) unawaited(review(chatId));
    }
  }
}
