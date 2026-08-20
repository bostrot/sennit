import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_sms/weft_sms.dart';

import '../data/chat_repository.dart';
import '../data/demo_repository.dart';
import '../data/matrix_chat_repository.dart';
import '../data/sms_chat_repository.dart';
import '../services/sms/sms_platform.dart';
import 'package:weft_store/weft_store.dart';

import 'labels.dart';
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
    settings: stores.settings,
    sms: ref.watch(smsRepositoryProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// SMS as one more source in the merged inbox, on the one platform that has it.
///
/// Null everywhere else — and null is not a degraded state. Weft is a Matrix
/// client that can also carry SMS: on a desktop, on iOS, and on an Android
/// phone where the user declined the default-app role, the SMS network is
/// simply absent from the inbox and nothing else changes.
final smsRepositoryProvider = Provider<SmsChatRepository?>((ref) {
  if (kDemoMode || defaultTargetPlatform != TargetPlatform.android) return null;

  final platform = SmsPlatform();
  final repository = SmsChatRepository(
    gateway: platform,
    // The region a national-format number is read against. Unset by default,
    // and deliberately not guessed from the locale: a wrong country code does
    // not fail to merge, it merges two different people. With no region,
    // `01234 567890` parses to nothing and only international-format numbers
    // become merge evidence — the conservative half of the trade.
    parser: PhoneNumberParser(defaultCountryCode: _defaultCountryCode(ref)),
  );
  ref.onDispose(() async {
    await repository.dispose();
    await platform.dispose();
  });
  return repository;
});

/// The stored country calling code, or null when there isn't one.
///
/// An empty setting has to read as "no region", not as the empty country code:
/// the parser's contract is that null means *do not guess*, and a blank string
/// prefixing a national number would produce a plausible-looking E.164 that
/// belongs to nobody.
String? _defaultCountryCode(Ref ref) {
  final stored = ref
      .watch(storesProvider)
      .settings
      .getString(WeftSettings.defaultCountryCode);
  return stored == null || stored.trim().isEmpty ? null : stored.trim();
}

/// Auth headers for avatar/media fetches, or null in demo mode or before the
/// client actually has a token.
///
/// Deliberately watches [sessionStateProvider] rather than reading
/// `session.isInitialized` directly. `matrixSessionProvider` returns the same
/// [WeftMatrixSession] instance for the app's whole lifetime, and Riverpod
/// only recomputes a `Provider` when a *watched provider's value* changes —
/// not when a mutable field on an already-returned object changes underneath
/// it. `isInitialized` flips from a private field the moment the SDK's
/// `Client` is constructed, which is *before* `client.init()` has restored
/// any stored access token — so the old code could (and reproducibly did)
/// compute once during that window, cache `null` headers forever, and send
/// every avatar and media request unauthenticated for the rest of the
/// session: a 401 on every single fetch, not a `null` mxc URL, which is
/// exactly the failure mode this was silently causing. `sessionStateProvider`
/// is a real stream that re-emits on every login-state transition, including
/// after `onSoftLogout`'s token refresh, so watching it recomputes the
/// headers exactly when the token is actually usable — and again if it
/// changes later.
final mediaHeadersProvider = Provider<Map<String, String>?>((ref) {
  if (kDemoMode) return null;
  final state = ref.watch(sessionStateProvider).value;
  switch (state) {
    case null:
    case WeftSessionState.loggedOut:
    case WeftSessionState.connecting:
    // The SDK is mid-refresh; the old token is already known bad, so there is
    // no point sending it. `_onLoginStateChanged` re-emits once the refresh
    // lands, which recomputes this with the new one.
    case WeftSessionState.softLoggedOut:
      return null;
    case WeftSessionState.unverified:
    case WeftSessionState.ready:
      break;
  }
  return mediaAuthHeaders(ref.watch(matrixSessionProvider).client);
});

final chatsProvider = StreamProvider<List<Chat>>((ref) {
  return ref.watch(chatRepositoryProvider).watchChats();
});

/// Whether one conversation's encrypted rooms hold any unverified device.
///
/// A family over the chat id rather than a field on [Chat], because it is the
/// one fact about a chat that comes from the key store instead of the timeline
/// and would otherwise drag E2EE state through every repository that builds a
/// chat, including the demo one. Watching [chatsProvider] is what recomputes it
/// when a merge changes which rooms the conversation covers.
///
/// Failures resolve to [RoomTrust.none]. The banner is an advisory, and a
/// key-store hiccup must not put a red bar over a chat that is fine.
final chatTrustProvider = FutureProvider.family<RoomTrust, String>((
  ref,
  chatId,
) async {
  if (kDemoMode) return RoomTrust.none;

  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized || !session.encryptionEnabled) {
    return RoomTrust.none;
  }

  final chat = ref
      .watch(chatsProvider)
      .value
      ?.where((c) => c.id == chatId)
      .firstOrNull;
  if (chat == null) return RoomTrust.none;

  try {
    return await trustOfRooms([
      for (final source in chat.sources)
        ?session.client.getRoomById(source.roomId),
    ]);
  } catch (_) {
    return RoomTrust.none;
  }
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
  // Bridge management bots are plumbing, not conversations; they open from
  // the bridges screen instead of sitting between real chats in the inbox.
  final service = ref.watch(chatRepositoryProvider).serviceChatIds;
  // Labels compose with the network rail: the rail says which apps, the label
  // says which *life* — Work on WhatsApp, Family across everything.
  final label = ref.watch(labelFilterProvider);
  final labels = ref.watch(chatLabelsProvider.notifier);
  ref.watch(chatLabelsProvider);
  final filtered = filterChats(
    chats
        .where(
          (c) =>
              c.archived == showArchived &&
              !service.contains(c.id) &&
              (label == null || labels.ofChat(c.id).contains(label)),
        )
        .toList(),
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
