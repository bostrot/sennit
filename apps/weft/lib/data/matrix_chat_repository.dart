import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_store/weft_store.dart';

import 'chat_repository.dart';

/// [ChatRepository] backed by a live Matrix session.
///
/// Rooms become chats; the identity graph decides which of those chats are the
/// same person and get folded into one merged conversation. The UI above this
/// is identical to the demo path — that is the point of the interface.
class MatrixChatRepository implements ChatRepository {
  MatrixChatRepository(
    this._session, {
    IdentityStore? store,
    SearchStore? searchStore,
  }) : _store = store,
       _searchStore = searchStore {
    // Rehydrate: stored handles and decisions rebuild the same partition the
    // user last saw, which is what makes an unmerge survive a restart.
    _graph = IdentityGraph(
      handles: _store?.loadHandles() ?? const [],
      decisions: [
        for (final d in _store?.loadDecisions() ?? const <StoredDecision>[])
          MergeDecision(
            pair: d.pair,
            verdict: d.verdict == MergeVerdict.merged.name
                ? MergeVerdict.merged
                : MergeVerdict.rejected,
            source: d.source == MergeDecisionSource.auto.name
                ? MergeDecisionSource.auto
                : MergeDecisionSource.user,
            decidedAt: d.decidedAt,
          ),
      ],
      idFactory: _idFactory(),
    );
    _sendNetworks.addAll(_store?.loadSendNetworks() ?? const {});
    _resolveMediaSupport();
    _rebuild();
    _syncSub = _session.client.onSync.stream.listen((_) => _rebuild());
  }

  final WeftMatrixSession _session;
  final IdentityStore? _store;
  final SearchStore? _searchStore;

  late IdentityGraph _graph;
  StreamSubscription<sdk.SyncUpdate>? _syncSub;

  final _chatsController = StreamController<List<Chat>>.broadcast();
  List<Chat> _chats = const [];

  final Map<String, ChatNetwork> _sendNetworks = {};

  /// Whether the homeserver serves media from the authenticated endpoint.
  /// Assumed true (the modern default) until the probe answers; a rebuild
  /// follows so avatars correct themselves rather than staying broken.
  bool _authenticatedMedia = true;

  /// Profiles fetched for DM partners whose member event was never loaded.
  final Map<String, sdk.Profile> _profiles = {};
  final Set<String> _profilesInFlight = {};

  /// The room's member list is lazy-loaded, so a bridged contact's avatar is
  /// usually not in memory at all — which is why avatars stayed as initials
  /// however the URL was built. Ask the server once per peer, then rebuild.
  void _ensureProfile(String userId) {
    if (_profiles.containsKey(userId) || _profilesInFlight.contains(userId)) {
      return;
    }
    _profilesInFlight.add(userId);
    _client
        .getProfileFromUserId(userId)
        .then((profile) {
          _profiles[userId] = profile;
          _profilesInFlight.remove(userId);
          if (profile.avatarUrl != null) _rebuild();
        })
        .catchError((Object error) {
          _profilesInFlight.remove(userId);
          debugPrint('weft: profile fetch failed for $userId: $error');
        });
  }

  Future<void> _resolveMediaSupport() async {
    try {
      final supported = await _client.authenticatedMediaSupported();
      if (supported == _authenticatedMedia) return;
      _authenticatedMedia = supported;
      _rebuild();
    } on Exception {
      // Probe failed; the assumed default stands.
    }
  }

  /// Timelines are expensive to build and hold subscriptions, so an open chat
  /// reuses its sources instead of rebuilding them on every sync.
  final Map<String, MergedTimeline> _timelines = {};
  final Map<String, List<MatrixTimelineSource>> _sources = {};

  static String Function() _idFactory() {
    var n = 0;
    return () => 'contact_$n${n++}';
  }

  sdk.Client get _client => _session.client;

  @override
  IdentityGraph get identityGraph => _graph;

  @override
  List<ChatNetwork> get availableNetworks {
    // Only networks the user actually has rooms on — an empty rail is better
    // than one advertising bridges they never set up.
    final seen = <ChatNetwork>{};
    for (final room in _client.rooms) {
      seen.add(networkForRoom(room));
    }
    return ChatNetwork.values.where(seen.contains).toList(growable: false);
  }

  @override
  Stream<List<Chat>> watchChats() async* {
    yield _chats;
    yield* _chatsController.stream;
  }

  @override
  Future<MergedTimeline> timelineFor(String chatId) async {
    final existing = _timelines[chatId];
    if (existing != null) return existing;

    final chat = _chats.firstWhere(
      (c) => c.id == chatId,
      orElse: () => throw ArgumentError.value(chatId, 'chatId', 'Unknown chat'),
    );

    // Opened concurrently: a merged chat spans several rooms, and opening them
    // one after another would make a three-network conversation three times
    // slower to appear.
    final opened = await Future.wait([
      for (final source in chat.sources)
        _openTimeline(source).catchError((_) => null),
    ]);

    final sources = opened.whereType<MatrixTimelineSource>().toList();
    if (sources.isEmpty) {
      throw StateError('Chat $chatId has no reachable rooms');
    }

    final merged = MergedTimeline(sources: sources);
    _timelines[chatId] = merged;
    _sources[chatId] = sources;
    return merged;
  }

  Future<MatrixTimelineSource?> _openTimeline(ChatSource source) async {
    final room = _client.getRoomById(source.roomId);
    if (room == null) return null;

    return MatrixTimelineSource(
      timeline: await room.getTimeline(),
      network: source.network,
      ownUserId: _client.userID,
    );
  }

  /// Releases an open chat's timelines when the user navigates away.
  void closeTimeline(String chatId) {
    for (final source
        in _sources.remove(chatId) ?? const <MatrixTimelineSource>[]) {
      source.dispose();
    }
    _timelines.remove(chatId);
  }

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) async {
    final chat = _chats.firstWhere((c) => c.id == chatId);
    final network = via ?? chat.sendNetwork;
    final source = network == null
        ? chat.sources.first
        : chat.sourceFor(network) ?? chat.sources.first;

    final room = _client.getRoomById(source.roomId);
    if (room == null) {
      throw StateError('Room ${source.roomId} is no longer available');
    }
    await room.sendTextEvent(body);
  }

  @override
  Future<void> setSendNetwork(String chatId, ChatNetwork network) async {
    _sendNetworks[chatId] = network;
    _store?.setSendNetwork(chatId, network);
    _rebuild();
  }

  @override
  Future<void> mergeHandles(String handleIdA, String handleIdB) async {
    _graph.merge(handleIdA, handleIdB);
    _persistGraph();
    _rebuild();
  }

  @override
  Future<void> unmergeHandle(String handleId) async {
    _graph.unmerge(handleId);
    _persistGraph();
    _rebuild();
  }

  @override
  Future<void> rejectSuggestion(String handleIdA, String handleIdB) async {
    _graph.reject(handleIdA, handleIdB);
    _persistGraph();
  }

  void _persistGraph() {
    final store = _store;
    if (store == null) return;
    store.saveDecisions([
      for (final d in _graph.decisions)
        (
          pair: d.pair,
          verdict: d.verdict.name,
          source: d.source.name,
          decidedAt: d.decidedAt,
        ),
    ]);
    store.saveAssignments({
      for (final h in _graph.handles)
        if (_graph.contactIdOf(h.id) != null) h.id: _graph.contactIdOf(h.id)!,
    });
  }

  @override
  Future<void> setArchived(String chatId, {required bool archived}) async {
    for (final room in _roomsOf(chatId)) {
      // Matrix has no "archive"; m.low_priority is the standard equivalent and
      // syncs to the user's other clients rather than being a local-only flag.
      await room.setLowPriority(archived);
    }
    _rebuild();
  }

  @override
  Future<void> setMuted(String chatId, {required bool muted}) async {
    for (final room in _roomsOf(chatId)) {
      await room.setPushRuleState(
        muted ? sdk.PushRuleState.dontNotify : sdk.PushRuleState.notify,
      );
    }
    _rebuild();
  }

  @override
  Future<void> deleteChat(String chatId) async {
    for (final room in _roomsOf(chatId)) {
      await room.leave();
      await room.forget();
    }
    closeTimeline(chatId);
    _rebuild();
  }

  Iterable<sdk.Room> _roomsOf(String chatId) {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return const [];
    return chat.roomIds.map(_client.getRoomById).whereType<sdk.Room>();
  }

  @override
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  }) async {
    final room = _client.getRoomById(roomId);
    if (room == null) return null;
    try {
      final event = await room.getEventById(eventId);
      if (event == null) return null;
      final file = await event.downloadAndDecryptAttachment(
        getThumbnail: thumbnail,
      );
      return Uint8List.fromList(file.bytes);
    } on Exception {
      // A missing or undecryptable attachment renders as a placeholder rather
      // than taking the timeline down.
      return null;
    }
  }

  @override
  void indexMessages(
    String chatId,
    List<WeftMessage> messages, {
    String chatTitle = '',
  }) {
    final store = _searchStore;
    if (store == null || messages.isEmpty) return;

    // Fall back to the chat's own title so a search for a person's name finds
    // their conversation even when the caller did not pass one.
    final title = chatTitle.isNotEmpty
        ? chatTitle
        : _chats.where((c) => c.id == chatId).firstOrNull?.title ?? '';
    // Redacted events carry no text and must not linger in the index.
    for (final m in messages.where((m) => m.redacted)) {
      store.removeMessage(eventId: m.eventId, roomId: m.roomId);
    }
    store.indexMessages(
      messages.where((m) => !m.redacted && m.searchableText.isNotEmpty),
      chatId: chatId,
      chatTitle: title,
    );
  }

  @override
  Future<void> markRead(String chatId) async {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return;

    // A merged chat marks every leg read: the user has seen the conversation,
    // regardless of which network each message arrived on.
    for (final source in chat.sources) {
      final room = _client.getRoomById(source.roomId);
      final lastEvent = room?.lastEvent;
      if (room == null || lastEvent == null) continue;
      await room.setReadMarker(lastEvent.eventId, mRead: lastEvent.eventId);
    }
  }

  Future<void> dispose() async {
    await _syncSub?.cancel();
    for (final chatId in _sources.keys.toList()) {
      closeTimeline(chatId);
    }
    await _chatsController.close();
  }

  // ------------------------------------------------------------------ rebuild

  void _rebuild() {
    _refreshIdentityGraph();

    final byRoom = <String, Chat>{};
    for (final room in _client.rooms) {
      if (room.isSpace) continue;
      byRoom[room.id] = _chatFromRoom(room);
    }

    _chats = _applyMerges(byRoom);
    if (!_chatsController.isClosed) _chatsController.add(_chats);
  }

  /// Rebuilds handles from direct chats so the scorer can suggest merges.
  ///
  /// Only DMs participate: merging two group rooms is not a "same person"
  /// question, so groups are always left alone.
  void _refreshIdentityGraph() {
    for (final room in _client.rooms) {
      if (!room.isDirectChat || room.isSpace) continue;

      final peerId = room.directChatMatrixID;
      if (peerId == null) continue;

      final network = networkForRoom(room);
      final peer = room.unsafeGetUserFromMemoryOrFallback(peerId);

      final handle = NetworkHandle(
        id: peerId,
        network: network,
        remoteId: _remoteIdFor(peerId, network),
        matrixUserId: peerId,
        roomId: room.id,
        displayName: peer.calcDisplayname(),
        avatarUrl: _thumbnail(peer.avatarUrl?.toString()),
        // The localpart of a bridged ghost is often the phone number. Storing
        // the normalised form means the strongest merge signal is actually
        // persisted, rather than left for the scorer to re-derive each pass —
        // and `normalizePhone` returns null for anything implausible, so a
        // Signal account id or a Discord snowflake simply doesn't set it.
        phoneE164: normalizePhone(_remoteIdFor(peerId, network)),
      );
      _graph.upsertHandle(handle);
      _store?.upsertHandle(
        handle.copyWith(unifiedContactId: _graph.contactIdOf(handle.id)),
      );
    }
  }

  /// Bridge ghosts encode the remote identifier in their localpart.
  static String _remoteIdFor(String matrixUserId, ChatNetwork network) {
    if (network == ChatNetwork.matrix) return matrixUserId;

    var localpart = matrixUserId.startsWith('@')
        ? matrixUserId.substring(1)
        : matrixUserId;
    final colon = localpart.indexOf(':');
    if (colon >= 0) localpart = localpart.substring(0, colon);
    if (localpart.startsWith('_')) localpart = localpart.substring(1);

    final underscore = localpart.indexOf('_');
    return underscore >= 0 ? localpart.substring(underscore + 1) : localpart;
  }

  String? _thumbnail(String? mxc) =>
      mxcToThumbnailUrl(_client, mxc, authenticatedMedia: _authenticatedMedia);

  /// Room avatar, else the DM partner's member event, else a fetched profile.
  ///
  /// The third step is the one that matters in practice: rooms sync with
  /// lazy-loaded members, so a bridged contact's member event — and with it
  /// their avatar — is usually not in memory at all. No amount of fixing the
  /// URL helps when the source mxc is simply absent.
  String? _avatarFor(sdk.Room room) {
    final roomAvatar = _thumbnail(room.avatar?.toString());
    if (roomAvatar != null) return roomAvatar;

    final peerId = room.directChatMatrixID;
    if (peerId == null) return null;

    final fromMember = _thumbnail(
      room.unsafeGetUserFromMemoryOrFallback(peerId).avatarUrl?.toString(),
    );
    if (fromMember != null) return fromMember;

    final cached = _profiles[peerId];
    if (cached != null) return _thumbnail(cached.avatarUrl?.toString());

    _ensureProfile(peerId);
    return null;
  }

  Chat _chatFromRoom(sdk.Room room) {
    final network = networkForRoom(room);
    final lastEvent = room.lastEvent;

    return Chat(
      id: room.id,
      title: room.getLocalizedDisplayname(),
      contactId: room.directChatMatrixID == null
          ? null
          : _graph.contactIdOf(room.directChatMatrixID!),
      sources: [ChatSource(roomId: room.id, network: network)],
      avatarUrl: _avatarFor(room),
      lastMessage: lastEvent == null
          ? null
          : mapEvent(lastEvent, network: network, ownUserId: _client.userID),
      unreadCount: room.notificationCount,
      isGroup: !room.isDirectChat,
      pinned: room.isFavourite,
      archived: room.membership == sdk.Membership.leave,
      muted: room.pushRuleState != sdk.PushRuleState.notify,
      preferredSendNetwork: _sendNetworks[room.id],
    );
  }

  /// Folds each merged contact's DM rooms into a single [Chat].
  List<Chat> _applyMerges(Map<String, Chat> byRoom) {
    final out = <Chat>[];
    final consumed = <String>{};

    for (final contact in _graph.contacts()) {
      if (!contact.isMerged) continue;

      final legs = contact.roomIds
          .map((id) => byRoom[id])
          .whereType<Chat>()
          .toList();
      if (legs.length < 2) continue;

      consumed.addAll(legs.map((c) => c.id));

      // The newest inbound message across every leg drives both the preview and
      // the default send network.
      legs.sort((a, b) {
        final at = a.lastMessage?.timestamp;
        final bt = b.lastMessage?.timestamp;
        if (at == null || bt == null) return 0;
        return bt.compareTo(at);
      });

      final mergedId = 'merged:${contact.id}';
      out.add(
        Chat(
          id: mergedId,
          title: contact.displayName,
          contactId: contact.id,
          sources: [for (final leg in legs) leg.sources.single],
          avatarUrl: contact.avatarUrl ?? legs.first.avatarUrl,
          lastMessage: legs.first.lastMessage,
          unreadCount: legs.fold(0, (sum, leg) => sum + leg.unreadCount),
          pinned: legs.any((leg) => leg.pinned),
          muted: legs.every((leg) => leg.muted),
          preferredSendNetwork: _sendNetworks[mergedId],
        ),
      );
    }

    for (final entry in byRoom.entries) {
      if (!consumed.contains(entry.key)) out.add(entry.value);
    }
    return out;
  }
}
