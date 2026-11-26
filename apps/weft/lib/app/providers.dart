import 'dart:async';

import 'package:collection/collection.dart' show ListEquality, MapEquality;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart'
    show isUnanswered, kReplyReminderMaxGroupPeers;
import 'package:weft_sms/weft_sms.dart';

import '../data/chat_repository.dart';
import '../data/demo_repository.dart';
import '../data/matrix_chat_repository.dart';
import '../data/send_queue_source.dart';
import '../data/sms_chat_repository.dart';
import '../services/background/background_work.dart';
import '../services/sms/sms_platform.dart';
import 'package:weft_store/weft_store.dart';

import '../services/status/status_feed.dart';
import 'draft_providers.dart';
import 'labels.dart';
import 'nickname_providers.dart';
import 'reply_reminder_providers.dart' show replyReminderSettingsProvider;
import 'session_providers.dart';
import 'stores.dart';

/// The active data source.
///
/// Demo mode short-circuits to fixtures; otherwise this is the live Matrix
/// session. Reading it before the session is initialised is a programming
/// error — and one that used to be fatal for the whole run rather than for the
/// read that made it.
///
/// [matrixSessionProvider] hands out the same object before and after
/// `initialize()`, so nothing in this provider's dependencies changed when the
/// session became usable. A read from above the auth gate — a share intent on
/// a cold start, a push, anything that asks for the inbox during startup —
/// therefore threw `initialize() has not been called`, Riverpod kept that
/// failure as this provider's state, and every later read rethrew it: signing
/// in led straight to a red `ProviderException` where the inbox should be, for
/// as long as the process lived.
///
/// Watching the bootstrap is what makes the failure temporary. It is the thing
/// that *does* change when the session comes up, so a premature read now fails
/// only until then and the provider rebuilds itself into a working repository
/// — the same shape [storesProvider] already has, and the same lesson
/// [mediaHeadersProvider] carries: a mutable field on an object Riverpod has
/// already handed out is not something Riverpod can recompute on.
///
/// The bootstrap rather than [sessionStateProvider], which is what the headers
/// watch: that one re-emits on every reconnection and soft-logout refresh, and
/// rebuilding the repository on each of those would throw away the identity
/// graph and every open timeline for a token that changed. This resolves once.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  if (kDemoMode) return DemoChatRepository();
  // Sennit Web: the phone's repository, through the encrypted link. The auth
  // gate holds the inbox back until the connection exists.
  if (kRemoteClient) return ref.watch(remoteRepositoryProvider).requireValue;

  // First, and before anything that can throw: a dependency only counts once
  // `ref.watch` has run, and a build that threw before reaching this line
  // would be exactly the un-healable failure this guards against.
  if (ref.watch(sessionBootstrapProvider).isLoading) {
    throw StateError(
      'Chat repository read before the session finished starting',
    );
  }

  final stores = ref.watch(storesProvider);
  final repository = MatrixChatRepository(
    ref.watch(matrixSessionProvider),
    store: stores.identity,
    searchStore: stores.search,
    retention: stores.retention,
    settings: stores.settings,
    sms: ref.watch(smsRepositoryProvider),
    onUploads: ref.watch(backgroundWorkProvider).reflectUploads,
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
  if (kNoMatrix || defaultTargetPlatform != TargetPlatform.android) return null;

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
  if (kNoMatrix) return null;
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
  final chats = ref.watch(chatRepositoryProvider).watchChats();
  // The user's own names for people, over whatever the networks call them.
  final nicknames = ref.watch(chatNicknamesProvider);
  return nicknames.isEmpty ? chats : chats.map(nicknames.applyTo);
});

/// One conversation, compared by what it says rather than by which one it is.
///
/// [chatsProvider] emits after every sync, and a busy account syncs several
/// times a second: a typing notification in one room, a receipt in another.
/// Nearly all of those change nothing about the conversation a given widget
/// is drawing — but the list is a new list every time, so anything that
/// watches it rebuilds every time. Measured on an inbox of two thousand
/// conversations, that was a 10–19ms frame per sync on an M-series Mac, with
/// nothing on screen different afterwards.
///
/// `ref.watch(chatsProvider.select(...))` is the cure, and [Chat] itself is
/// the wrong thing to select: its `==` is the conversation's id, so a
/// selected [Chat] never notifies at all, changed or not. This is the wrapper
/// in between — equal exactly when [Chat.sameContentAs] says nothing moved.
@immutable
class ChatContent {
  const ChatContent(this.chat);

  final Chat chat;

  /// The conversation called [chatId] in [chats], or null.
  static ChatContent? find(List<Chat>? chats, String chatId) {
    if (chats == null) return null;
    for (final chat in chats) {
      if (chat.id == chatId) return ChatContent(chat);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ChatContent && other.chat.sameContentAs(chat);

  @override
  int get hashCode => chat.id.hashCode;
}

/// Hands back the previous value when the new one says the same thing.
///
/// A `Provider` notifies when its value is not `==` to the last one, and a
/// list or a map built fresh on every run never is. Returning the *old*
/// object for unchanged content is what lets a provider that recomputes on
/// every sync stay silent on nearly all of them.
///
/// One per provider, held in a provider of its own so the memory belongs to
/// the container rather than to the process — two `ProviderScope`s, or two
/// tests, must not share a last value.
class _Unchanging<T> {
  _Unchanging(this._same);

  final bool Function(T previous, T next) _same;
  T? _last;
  bool _has = false;

  T call(T next) {
    if (_has && _same(_last as T, next)) return _last as T;
    _has = true;
    return _last = next;
  }
}

final _visibleChatsMemo = Provider(
  (ref) => _Unchanging<List<Chat>>(Chat.sameContentList),
);
final _pendingRequestsMemo = Provider(
  (ref) => _Unchanging<List<Chat>>(Chat.sameContentList),
);
final _unreadByNetworkMemo = Provider(
  (ref) => _Unchanging<Map<ChatNetwork, int>>(
    const MapEquality<ChatNetwork, int>().equals,
  ),
);

/// What polls [roomId]'s bridge carries, for the "end poll" button on a poll
/// the reader started. Room features change when a bridge is upgraded, not
/// while a chat is open, so one read per room per screen is enough.
final pollSupportProvider = FutureProvider.autoDispose
    .family<PollSupport, String>(
      (ref, roomId) => ref.watch(chatRepositoryProvider).pollSupport(roomId),
    );

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
///
/// Two clocks, neither of them the sync. The *rooms* are watched through a
/// `select`, so a merge re-asks at once and the thousand syncs that touch
/// nothing about this conversation's composition do not. The *devices* behind
/// those rooms change with no word to the inbox at all — a contact signs in on
/// a new phone — so the answer is also re-asked on a slow timer for as long as
/// something is showing it. Watching the whole list instead walked every
/// member's device keys in every encrypted leg after each sync: several times
/// a second, in a group of hundreds, for a banner that changes once a month.
final chatTrustProvider = FutureProvider.family<RoomTrust, String>((
  ref,
  chatId,
) async {
  if (kNoMatrix) return RoomTrust.none;

  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized || !session.encryptionEnabled) {
    return RoomTrust.none;
  }

  final roomIds = ref.watch(
    chatsProvider.select(
      (chats) => ChatContent.find(chats.value, chatId)?.chat.roomIds.join('\n'),
    ),
  );
  if (roomIds == null) return RoomTrust.none;

  final refresh = Timer(_trustRefreshInterval, ref.invalidateSelf);
  ref.onDispose(refresh.cancel);

  try {
    return await trustOfRooms([
      for (final roomId in roomIds.split('\n'))
        ?session.client.getRoomById(roomId),
    ]);
  } catch (_) {
    return RoomTrust.none;
  }
});

/// How stale a conversation's device trust may get while it is on screen.
const Duration _trustRefreshInterval = Duration(seconds: 10);

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

/// Why each failed message did not leave, by its event id.
///
/// Empty for a repository with no send queue to report on — the demo, Sennit
/// Web — where a failed message simply says "Not sent".
final sendFailuresProvider = StreamProvider<Map<String, SendFailure>>((
  ref,
) async* {
  final repo = ref.watch(chatRepositoryProvider);
  if (repo is! SendQueueSource) {
    yield const {};
    return;
  }
  final queue = repo as SendQueueSource;
  yield queue.sendFailures;
  yield* queue.sendFailureChanges;
});

/// Reads a picked file's bytes.
///
/// The same loader the Matrix send path uses, exposed as a provider so the
/// preview sheet renders a real thumbnail through it and a widget test can hand
/// back fixture pixels instead of touching a disk that has no such file.
final attachmentFileReaderProvider = Provider<AttachmentBytesLoader>(
  (ref) => readAttachmentFile,
);

/// Whether the user sends public read receipts.
///
/// Read by the *ticks* as well as by the sender, and that is the point of it
/// being a provider rather than a lookup inside `markRead`. Turning receipts off
/// is a two-way switch: bridges relay the public receipt to the remote network
/// as its own read marker, and nearly all of them stop relaying the other
/// direction in return — so the user who switched it off is also the user whose
/// blue ticks will never arrive again. A bubble that went on drawing two grey
/// ticks would be telling them the other side has not looked at their message,
/// which is not what happened.
///
/// Defaults to **on**, matching the sender's own fallback, so the two cannot
/// disagree about what an unset key means.
final sendReadReceiptsProvider = Provider<bool>((ref) {
  ref.watch(settingsRevisionProvider);
  try {
    return ref
        .read(storesProvider)
        .settings
        .getBool(WeftSettings.sendReadReceipts, fallback: true);
  } on Object {
    return true;
  }
});

/// Whether Return sends the message, or breaks the line.
///
/// Off by default. Sennit's composer grows to five lines and people write
/// paragraphs in it; a Return that sends turns every attempt at a second line
/// into a message nobody meant to send, and there is no unsending it on a
/// network the message has already left.
final sendOnEnterProvider = Provider<bool>((ref) {
  ref.watch(settingsRevisionProvider);
  try {
    return ref.read(storesProvider).settings.getBool(WeftSettings.sendOnEnter);
  } on Object {
    // `Object`, not `StateError`: reading a provider that threw during its own
    // creation rethrows a `ProviderException` wrapping the cause, so catching
    // the cause catches nothing — and the composer's setting took the whole
    // chat view down with it before the stores had finished bootstrapping.
    return false;
  }
});

/// What time it is.
///
/// A provider because two things need to disagree about it: the app, which
/// wants the real clock, and a golden, which wants the instant its fixtures
/// are dated against. Before this the *formatter* held a fixed instant so the
/// goldens would settle — and shipped it, so every real message in the inbox
/// was newer than "now" and every conversation was labelled "Now".
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// The networks the account has conversations on, for the rail and the
/// sidebar.
///
/// `ChatRepository.availableNetworks` is a plain getter, so nothing announces
/// that a bridge's first room has arrived. The rail used to find out by being
/// rebuilt after every sync along with everything else; now that the shells
/// only rebuild for a reason, this is the reason — asked on the same heartbeat,
/// and silent unless the answer changed.
final availableNetworksProvider = Provider<List<ChatNetwork>>((ref) {
  ref.watch(chatsProvider);
  return ref.read(_availableNetworksMemo)(
    ref.watch(chatRepositoryProvider).availableNetworks,
  );
});

final _availableNetworksMemo = Provider(
  (ref) =>
      _Unchanging<List<ChatNetwork>>(const ListEquality<ChatNetwork>().equals),
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

  /// Whether the inbox is in selection mode with nothing picked yet.
  ///
  /// Selection used to be entered by long-pressing a row, which made the mode
  /// and its first member the same act — fine until holding a row came to mean
  /// something else. Now the mode is entered deliberately and starts empty, so
  /// it needs a state of its own: an empty set no longer means "not
  /// selecting".
  bool _active = false;
  bool get isActive => _active || state.isNotEmpty;

  /// Enters selection mode with nothing selected.
  void begin() {
    _active = true;
    // The set is what listeners watch, so the mode change has to reach them
    // through it. A fresh instance is not `==` to the old one, which is what
    // makes an empty-to-empty transition notify at all.
    state = <String>{...state};
  }

  void toggle(String chatId) {
    final next = {...state};
    if (!next.remove(chatId)) next.add(chatId);
    state = next;
  }

  void selectAll(Iterable<String> chatIds) => state = chatIds.toSet();

  void clear() {
    _active = false;
    state = const {};
  }
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

/// Networks kept out of the "All" view; the rail is their only door.
class HiddenFromAllNotifier extends Notifier<Set<ChatNetwork>> {
  @override
  Set<ChatNetwork> build() {
    final json = storesOrNull(
      ref,
    )?.settings.getJson(WeftSettings.inboxHiddenFromAll);
    final list = json?['networks'];
    if (list is! List) return const {};
    return {for (final id in list.whereType<String>()) ChatNetwork.fromId(id)}
      ..remove(ChatNetwork.unknown);
  }

  void toggle(ChatNetwork network) {
    final next = {...state};
    if (!next.remove(network)) next.add(network);
    state = next;
    storesOrNull(ref)?.settings.setJson(WeftSettings.inboxHiddenFromAll, {
      'networks': [for (final n in next) n.id]..sort(),
    });
  }
}

final hiddenFromAllProvider =
    NotifierProvider<HiddenFromAllNotifier, Set<ChatNetwork>>(
      HiddenFromAllNotifier.new,
    );

/// One-tap slices of the inbox: just what's unread, just the groups, just
/// the one-on-ones, just the ones waiting on an answer, just the ones with
/// something half-written. A second tap on the
/// active chip turns it back off.
enum InboxQuickFilter { unread, groups, people, needsReply, drafts }

/// Whether someone in [chat] spoke last and is waiting on the user.
///
/// [isUnanswered], the rule reply reminders use too, so a reaction answers a
/// chat here exactly when it stops its reminders. Read or not: an unread
/// message needs an answer as much as a read one. Only people and small
/// groups, by the same measure reply reminders use — in a big group the last
/// word is rarely addressed to anyone.
bool needsReply(Chat chat, {bool reactionsCount = true}) {
  if (!isUnanswered(chat, reactionsCount: reactionsCount)) return false;
  if (!chat.isGroup) return true;
  final peers = chat.participantCount;
  return peers != null && peers <= kReplyReminderMaxGroupPeers;
}

class InboxQuickFilterNotifier extends Notifier<InboxQuickFilter?> {
  @override
  InboxQuickFilter? build() => null;

  void toggle(InboxQuickFilter filter) =>
      state = state == filter ? null : filter;
}

final inboxQuickFilterProvider =
    NotifierProvider<InboxQuickFilterNotifier, InboxQuickFilter?>(
      InboxQuickFilterNotifier.new,
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
  // The broadcast group leaves the list in `rings` mode (its content lives
  // in the story row) and in `off` mode (the user asked for none of it);
  // only `group` mode shows it as an ordinary conversation.
  final statusChatId = ref.watch(statusModeProvider) == StatusMode.group
      ? null
      : ref.watch(statusChatProvider)?.id;
  final quick = ref.watch(inboxQuickFilterProvider);
  final reactionsCount =
      quick == InboxQuickFilter.needsReply &&
      ref.watch(
        replyReminderSettingsProvider.select((s) => s.reactionsCountAsReply),
      );
  final drafts = quick == InboxQuickFilter.drafts
      ? ref.watch(draftsProvider)
      : const <String, String>{};
  // A network hidden from "All" only appears when the rail filter names it
  // (alone or with others) — the combined view stays clean, the door stays
  // one tap away. A merged chat with any visible leg is not hidden: hiding
  // a whole person because one of their networks is tucked away would be
  // the wrong reading of the setting.
  final hiddenFromAll = ref.watch(hiddenFromAllProvider);
  final filtered = filterChats(
    chats
        .where(
          (c) =>
              c.archived == showArchived &&
              // Held out of the inbox proper, which is the whole feature: a
              // conversation from someone the user has never talked to should
              // be something they *choose* to look at, not a row that has
              // already pushed a real conversation down the list. They are in
              // [pendingRequestsProvider], one tap away.
              !c.isPendingRequest &&
              !service.contains(c.id) &&
              c.id != statusChatId &&
              (label == null || labels.ofChat(c.id).contains(label)) &&
              (filter.isNotEmpty ||
                  hiddenFromAll.isEmpty ||
                  c.networks.isEmpty ||
                  !c.networks.every(hiddenFromAll.contains)) &&
              switch (quick) {
                null => true,
                InboxQuickFilter.unread => c.unreadCount > 0,
                InboxQuickFilter.groups => c.isGroup,
                InboxQuickFilter.people => !c.isGroup,
                InboxQuickFilter.needsReply => needsReply(
                  c,
                  reactionsCount: reactionsCount,
                ),
                // Kept per room as well as per merged chat; any will do.
                InboxQuickFilter.drafts =>
                  drafts.containsKey(c.id) || c.roomIds.any(drafts.containsKey),
              },
        )
        .toList(),
    filter,
  );

  // Pinned first, then most recent activity — a message or a reaction, never
  // a profile picture or a room rename; see [Chat.lastActivityAt].
  final sorted = [...filtered]
    ..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return Chat.byActivity(a, b);
    });
  // The same list object when nothing in it moved, so the inbox is rebuilt by
  // a sync that changed a row and not by every sync there is.
  return ref.read(_visibleChatsMemo)(sorted);
});

/// Conversations waiting for the user to accept or decline them.
///
/// Deliberately *not* narrowed by the rail's network filter, the label filter
/// or the quick filters. A request is a decision the user has not made yet, and
/// a decision hidden by a filter they set for another purpose is one they never
/// make — the conversation simply never appears again. The archived split is
/// honoured, because an archived room is one they have already dealt with.
///
/// Service chats are excluded for the same reason they are excluded everywhere:
/// a bridge bot messaging its own management room is plumbing, and it would
/// otherwise arrive as a stranger asking to talk.
///
/// Newest first, so the one that just arrived is the one at the top.
final pendingRequestsProvider = Provider<List<Chat>>((ref) {
  final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
  final service = ref.watch(chatRepositoryProvider).serviceChatIds;
  final requests = chats
      .where(
        (c) => c.isPendingRequest && !c.archived && !service.contains(c.id),
      )
      .toList();
  requests.sort(Chat.byActivity);
  return ref.read(_pendingRequestsMemo)(List.unmodifiable(requests));
});

/// Unread totals per network, for the rail badges.
///
/// Deliberately *not* narrowed by the rail's own filter or the quick filters —
/// a badge that disappeared when you filtered somewhere else would be useless.
/// It is narrowed by the things the inbox will never show at all, which is a
/// different question and was the bug: the count came off the raw list, so a
/// WhatsApp status broadcast and the bridge bots' service rooms each put a
/// badge on a network whose inbox contains nothing unread. Tapping it showed
/// an empty result and no way to clear the mark.
final unreadByNetworkProvider = Provider<Map<ChatNetwork, int>>((ref) {
  final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
  final service = ref.watch(chatRepositoryProvider).serviceChatIds;
  // The broadcast group is a conversation only in `group` mode; in the other
  // two its content is a story row or nothing, and neither is something a
  // rail badge can send anyone to.
  final statusChatId = ref.watch(statusModeProvider) == StatusMode.group
      ? null
      : ref.watch(statusChatProvider)?.id;

  return ref.read(_unreadByNetworkMemo)(
    unreadByNetwork([
      for (final chat in chats)
        if (!chat.archived &&
            !service.contains(chat.id) &&
            chat.id != statusChatId)
          chat,
    ]),
  );
});
