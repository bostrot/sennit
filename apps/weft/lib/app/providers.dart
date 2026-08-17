import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../data/chat_repository.dart';
import '../data/demo_repository.dart';
import '../data/matrix_chat_repository.dart';
import 'package:weft_store/weft_store.dart';

import 'session_providers.dart';
import 'stores.dart';

/// The active data source.
///
/// Demo mode short-circuits to fixtures; otherwise this is the live Matrix
/// session. Reading it before the session is initialised is a programming
/// error, and the auth gate guarantees it cannot happen.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  if (kDemoMode) return DemoChatRepository();

  final stores = ref.watch(storesProvider);
  final repository = MatrixChatRepository(
    ref.watch(matrixSessionProvider),
    store: stores.identity,
    searchStore: stores.search,
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// Auth headers for avatar/media fetches, or null in demo mode.
final mediaHeadersProvider = Provider<Map<String, String>?>((ref) {
  if (kDemoMode) return null;
  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) return null;
  return mediaAuthHeaders(session.client);
});

final chatsProvider = StreamProvider<List<Chat>>((ref) {
  return ref.watch(chatRepositoryProvider).watchChats();
});

/// Uploads in flight for one chat, keyed by chat id.
///
/// Separate from the timeline because an upload is not a message yet — see
/// [ChatRepository.watchUploads]. The chat view draws these below the settled
/// messages and each disappears when its real event arrives.
final chatUploadsProvider = StreamProvider.family<List<UploadTask>, String>((
  ref,
  chatId,
) {
  return ref.watch(chatRepositoryProvider).watchUploads(chatId);
});

/// Reads a picked file's bytes.
///
/// The same loader the Matrix send path uses, exposed as a provider so the
/// preview sheet renders a real thumbnail through it and a widget test can hand
/// back fixture pixels instead of touching a disk that has no such file.
final attachmentFileReaderProvider = Provider<AttachmentBytesLoader>(
  (ref) => readAttachmentFile,
);

/// Networks selected in the left rail. Empty means "show everything".
class NetworkFilterNotifier extends Notifier<Set<ChatNetwork>> {
  @override
  Set<ChatNetwork> build() => const {};

  void toggle(ChatNetwork network) {
    final multi = _multiSelect;
    if (multi) {
      final next = {...state};
      if (!next.remove(network)) next.add(network);
      state = next;
      return;
    }
    // Single-select: one network at a time; tapping the active one clears
    // back to All. Radio behaviour, which is what most people expect of a
    // sidebar like this.
    state = state.length == 1 && state.contains(network) ? const {} : {network};
  }

  bool get _multiSelect {
    try {
      return ref
          .read(storesProvider)
          .settings
          .getBool(WeftSettings.railMultiSelect);
    } on StateError {
      // Stores not bootstrapped (tests pumping the shell directly).
      return false;
    }
  }

  void clear() => state = const {};
}

final networkFilterProvider =
    NotifierProvider<NetworkFilterNotifier, Set<ChatNetwork>>(
      NetworkFilterNotifier.new,
    );

/// The chat open in the detail pane, if any.
class SelectedChatNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? chatId) => state = chatId;
}

final selectedChatProvider = NotifierProvider<SelectedChatNotifier, String?>(
  SelectedChatNotifier.new,
);

/// Chats picked in the inbox's selection mode.
///
/// Empty means the mode is off entirely, so there is no separate flag to keep
/// in step with the set.
class ChatSelectionNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String chatId) {
    final next = {...state};
    if (!next.remove(chatId)) next.add(chatId);
    state = next;
  }

  void selectAll(Iterable<String> chatIds) => state = chatIds.toSet();

  void clear() => state = const {};
}

final chatSelectionProvider =
    NotifierProvider<ChatSelectionNotifier, Set<String>>(
      ChatSelectionNotifier.new,
    );

/// Whether the inbox is showing archived chats instead of active ones.
class ShowArchivedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final showArchivedProvider = NotifierProvider<ShowArchivedNotifier, bool>(
  ShowArchivedNotifier.new,
);

/// The inbox after the rail filter is applied.
final visibleChatsProvider = Provider<List<Chat>>((ref) {
  final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
  final filter = ref.watch(networkFilterProvider);
  final showArchived = ref.watch(showArchivedProvider);
  final filtered = filterChats(
    chats.where((c) => c.archived == showArchived).toList(),
    filter,
  );

  // Pinned first, then most recent activity.
  return [...filtered]..sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final at = a.lastMessage?.timestamp;
    final bt = b.lastMessage?.timestamp;
    if (at == null || bt == null) return 0;
    return bt.compareTo(at);
  });
});

/// Unread totals per network, for the rail badges. Computed from the unfiltered
/// list so filtering never makes a badge disappear.
final unreadByNetworkProvider = Provider<Map<ChatNetwork, int>>((ref) {
  final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
  return unreadByNetwork(chats);
});
