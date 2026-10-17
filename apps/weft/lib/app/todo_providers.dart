import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../features/settings/integrations_screen.dart'
    show homeAssistantProvider;
import '../services/integrations/home_assistant.dart';
import '../services/status/status_feed.dart' show isStatusBroadcastChat;
import '../services/todo/todo_agent.dart';
import '../services/todo/todo_assistant.dart';
import '../services/todo/todo_item.dart';
import 'auto_reply_providers.dart' show autoReplyEndpointProvider;
import 'providers.dart';
import 'session_providers.dart';
import 'stores.dart';

/// The to-do list's settings keys.
///
/// Kept beside the feature rather than in `WeftSettings`: nothing outside the
/// list reads them, and the store takes any key.
abstract final class TodoSettings {
  /// `{"items": [...]}` — see [TodoItem.toJson].
  static const String items = 'todo.items';

  /// Whether the assistant may read conversations to keep the list. Off by
  /// default: it sends messages to the user's AI endpoint.
  static const String aiEnabled = 'todo.ai_enabled';

  /// Whether entries are also added to a Home Assistant to-do list.
  static const String homeAssistantSync = 'todo.ha_sync';

  /// The `todo.*` entity they are added to.
  static const String homeAssistantEntity = 'todo.ha_entity';
}

/// The switches, read together.
@immutable
class TodoPreferences {
  const TodoPreferences({
    this.aiEnabled = false,
    this.homeAssistantSync = false,
    this.homeAssistantEntity,
  });

  final bool aiEnabled;
  final bool homeAssistantSync;
  final String? homeAssistantEntity;

  /// The entity to mirror into, or null when mirroring is off or unaimed.
  String? get mirrorEntity {
    final entity = homeAssistantEntity?.trim() ?? '';
    return homeAssistantSync && entity.isNotEmpty ? entity : null;
  }
}

final todoPreferencesProvider = Provider<TodoPreferences>((ref) {
  ref.watch(settingsRevisionProvider);
  final stores = storesOrNull(ref);
  if (stores == null) return const TodoPreferences();
  return TodoPreferences(
    aiEnabled: stores.settings.getBool(TodoSettings.aiEnabled),
    homeAssistantSync: stores.settings.getBool(TodoSettings.homeAssistantSync),
    homeAssistantEntity: stores.settings.getString(
      TodoSettings.homeAssistantEntity,
    ),
  );
});

/// Writes one of the switches and tells the providers that read them.
void writeTodoPreference(WidgetRef ref, String key, Object value) {
  final settings = ref.read(storesProvider).settings;
  switch (value) {
    case bool():
      settings.setBool(key, value: value);
    case String():
      settings.setString(key, value);
  }
  ref.read(settingsRevisionProvider.notifier).bump();
}

/// The list itself, newest first.
///
/// One JSON blob, like the auto-reply rules: a personal list is tens of rows,
/// not thousands, and the blob rides along in the settings backup for free.
/// Every change is written before it is published, and mirrored into Home
/// Assistant afterwards — fire and forget, because a wall tablet being offline
/// is no reason to refuse a tick on the phone.
class TodoList extends Notifier<List<TodoItem>> {
  final Random _random = Random();

  @override
  List<TodoItem> build() {
    try {
      return TodoItem.listFromJson(
        ref.read(storesProvider).settings.getJson(TodoSettings.items)?['items'],
      );
    } on Object {
      // Stores not bootstrapped — a widget test or a launch still starting.
      return const [];
    }
  }

  void _replaceAll(List<TodoItem> items) {
    final next = List<TodoItem>.unmodifiable(items);
    try {
      ref.read(storesProvider).settings.setJson(TodoSettings.items, {
        'items': TodoItem.listToJson(next),
      });
    } on Object {
      // In memory only.
    }
    state = next;
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_random.nextInt(1 << 30).toRadixString(36)}';

  /// Adds an entry at the top. Returns it, or null for an empty title.
  TodoItem? add(
    String title, {
    DateTime? due,
    String? chatId,
    String? chatTitle,
    bool fromAi = false,
  }) {
    final trimmed = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.isEmpty) return null;
    final item = TodoItem(
      id: _newId(),
      title: trimmed,
      createdAt: DateTime.now(),
      due: due,
      chatId: chatId,
      chatTitle: chatTitle,
      fromAi: fromAi,
    );
    _replaceAll([item, ...state]);
    _mirror((ha, entity) => ha.addTodoItem(entity, item.title, due: item.due));
    return item;
  }

  void setDone(String id, {required bool done}) {
    final item = state.where((i) => i.id == id).firstOrNull;
    if (item == null || item.done == done) return;
    _replaceAll([
      for (final i in state) i.id == id ? i.copyWith(done: done) : i,
    ]);
    _mirror((ha, entity) => ha.setTodoItemDone(entity, item.title, done: done));
  }

  void edit(String id, {required String title, DateTime? due}) {
    final trimmed = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.isEmpty) return;
    _replaceAll([
      for (final i in state)
        i.id == id
            ? i.copyWith(title: trimmed, due: due, clearDue: due == null)
            : i,
    ]);
  }

  void remove(String id) => _replaceAll([
    for (final i in state)
      if (i.id != id) i,
  ]);

  /// Drops every finished entry; returns how many went.
  int clearDone() {
    final before = state.length;
    _replaceAll([
      for (final i in state)
        if (!i.done) i,
    ]);
    return before - state.length;
  }

  /// The open entries the assistant wrote for [chatId], oldest first — the
  /// numbered list the model is shown.
  List<TodoItem> openFor(String chatId) => [
    for (final i in state.reversed)
      if (!i.done && i.chatId == chatId) i,
  ];

  /// What the assistant proposed, applied.
  void applyChanges(Chat chat, TodoChanges changes) {
    for (final id in changes.complete) {
      setDone(id, done: true);
    }
    // A title that is open anywhere on the list — typed by hand, or from
    // another chat — is not added a second time.
    final open = {
      for (final i in state)
        if (!i.done) i.title.toLowerCase(),
    };
    for (final proposal in changes.add) {
      if (!open.add(proposal.title.toLowerCase())) continue;
      add(
        proposal.title,
        due: proposal.due,
        chatId: chat.id,
        chatTitle: chat.title,
        fromAi: true,
      );
    }
  }

  void _mirror(
    Future<void> Function(HomeAssistantClient ha, String entity) call,
  ) {
    final entity = ref.read(todoPreferencesProvider).mirrorEntity;
    if (entity == null) return;
    final HomeAssistantClient? ha;
    try {
      ha = ref.read(homeAssistantProvider);
    } on Object {
      return;
    }
    if (ha == null) return;
    unawaited(
      call(ha, entity).catchError(
        (Object error) =>
            debugPrint('weft: to-do mirror into $entity failed: $error'),
      ),
    );
  }
}

final todoListProvider = NotifierProvider<TodoList, List<TodoItem>>(
  TodoList.new,
);

/// The assistant that keeps the list, or null when this build cannot have
/// one — demo mode, or before the session is up. Whether it *acts* is
/// [TodoPreferences.aiEnabled], read per message.
final todoAgentProvider = Provider<TodoAgent?>((ref) {
  if (kDemoMode) return null;

  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) return null;

  final repository = ref.watch(chatRepositoryProvider);
  final matrixSession = MatrixNotificationSession.forClient(session.client);

  final agent = TodoAgent(
    incoming: matrixSession.incomingMessages,
    chatForRoom: repository.chatForRoom,
    isServiceChat: repository.serviceChatIds.contains,
    isBroadcast: isStatusBroadcastChat,
    enabled: () => ref.read(todoPreferencesProvider).aiEnabled,
    endpoint: () => ref.read(autoReplyEndpointProvider),
    openItemsFor: (chatId) =>
        ref.read(todoListProvider.notifier).openFor(chatId),
    apply: (chat, changes) =>
        ref.read(todoListProvider.notifier).applyChanges(chat, changes),
  );

  ref.onDispose(() => unawaited(agent.dispose()));
  return agent;
});
