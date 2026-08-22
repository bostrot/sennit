import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart' show MapEquality;
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_richtext/weft_richtext.dart';
import 'package:weft_store/weft_store.dart';

import 'chat_repository.dart';
import 'sms_chat_repository.dart';

/// Reads the whole of a picked file.
///
/// The one place the send path touches the disk, and injected for exactly that
/// reason: everything else about an attachment is decided from an
/// [AttachmentSource]'s header slice, so a test that supplies bytes here can
/// drive the entire pipeline without one.
typedef AttachmentBytesLoader =
    Future<Uint8List> Function(AttachmentSource source);

/// Reads the file [AttachmentSource.filename] names.
///
/// The pickers Weft uses hand over a real path, and Android's share-in copies a
/// `content://` grant to a temp file before building a source, so by the time a
/// source reaches the repository its name is always openable. Read per upload
/// attempt rather than held: a twenty-photo share must not pin twenty files in
/// memory from the moment it is enqueued.
Future<Uint8List> readAttachmentFile(AttachmentSource source) =>
    File(source.filename).readAsBytes();

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
    SettingsStore? settings,
    MatrixAttachmentTransport? transport,
    AttachmentBytesLoader readBytes = readAttachmentFile,
    SmsChatRepository? sms,
  }) : _store = store,
       _settings = settings,
       _searchStore = searchStore,
       _transportOverride = transport,
       _readBytes = readBytes,
       _sms = sms {
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
    _syncSub = _session.client.onSync.stream.listen((_) => _scheduleRebuild());

    final sms = _sms;
    if (sms != null) {
      // SMS text goes through *this* repository's indexer rather than through a
      // second one, so a hybrid query covers it without knowing SMS exists. The
      // room id is resolved to a chat id at index time: a thread that has since
      // been merged must file its rows under the merged conversation, or the
      // search result opens a chat the inbox no longer shows.
      sms.indexer = (roomId, messages, {String chatTitle = ''}) =>
          indexMessages(
            chatForRoom(roomId)?.id ?? roomId,
            messages,
            chatTitle: chatTitle,
          );
      _smsSub = sms.updates.listen((_) => _rebuild());
      // Not awaited, and it must not be: reading the provider is a method
      // channel round trip, and the inbox has four other networks to draw
      // meanwhile. A phone where Weft is not the default SMS app settles
      // immediately on "no threads" and nothing here ever fires again.
      unawaited(sms.start());
    }
  }

  final WeftMatrixSession _session;
  final IdentityStore? _store;
  final SettingsStore? _settings;
  final SearchStore? _searchStore;
  final AttachmentBytesLoader _readBytes;

  /// SMS, when this device has it and Weft holds the role. Null everywhere
  /// else, which is the state every path below has to work in anyway.
  final SmsChatRepository? _sms;

  late IdentityGraph _graph;
  StreamSubscription<sdk.SyncUpdate>? _syncSub;
  StreamSubscription<void>? _smsSub;

  final _chatsController = StreamController<List<Chat>>.broadcast();
  List<Chat> _chats = const [];

  /// Coalesces the initial-sync storm: sync can tick many times a second
  /// while a large account catches up, and every tick used to rebuild every
  /// chat — three membership scans per room, per tick — which is most of what
  /// "the app takes long to load" was. One trailing rebuild per 300ms keeps
  /// the inbox as fresh as an eye can tell and cuts the work by an order of
  /// magnitude.
  Timer? _rebuildDebounce;
  void _scheduleRebuild() {
    _rebuildDebounce ??= Timer(const Duration(milliseconds: 300), () {
      _rebuildDebounce = null;
      _rebuild();
    });
  }

  final Map<String, ChatNetwork> _sendNetworks = {};

  /// Whether the homeserver serves media from the authenticated endpoint.
  /// Assumed true (the modern default) until the probe answers; a rebuild
  /// follows so avatars correct themselves rather than staying broken.
  bool _authenticatedMedia = true;

  /// What was last written to the identity store per handle, so an unchanged
  /// handle is not rewritten on every sync-driven refresh.
  final Map<String, String> _handleFingerprints = {};

  /// The newest event each room was receipted up to, from this session.
  ///
  /// `Room.notificationCount` is the *server's* number and only moves after
  /// the receipt lands and a sync returns; until then the badge the user just
  /// cleared would still glow. A room whose last event is the one we already
  /// receipted reads as zero, whatever the server still says.
  final Map<String, String> _readUpTo = {};

  /// Profiles fetched for DM partners whose member event was never loaded.
  final Map<String, sdk.Profile> _profiles = {};
  final Set<String> _profilesInFlight = {};

  /// The room's member list is lazy-loaded, so a bridged contact's avatar is
  /// usually not in memory at all — which is why avatars stayed as initials
  /// however the URL was built. Ask the server once per peer, then rebuild.
  ///
  /// Two lookups, in order. The global profile is first because it is one
  /// request that answers for every room the user shares. But a bridge ghost's
  /// global profile is frequently empty — many bridges only put the contact's
  /// picture on the *member event* of the portal room — so an empty answer
  /// falls back to reading `m.room.member` state from [room] directly.
  void _ensureProfile(String userId, {sdk.Room? room}) {
    if (_profiles.containsKey(userId) || _profilesInFlight.contains(userId)) {
      return;
    }
    _profilesInFlight.add(userId);

    Future<(sdk.Profile, bool failed)> lookup() async {
      var failed = false;
      sdk.Profile? profile;
      try {
        profile = await _client.getProfileFromUserId(userId);
      } on Exception catch (error) {
        failed = true;
        debugPrint('weft: profile fetch failed for $userId: $error');
      }
      if (profile?.avatarUrl != null || room == null) {
        return (profile ?? sdk.Profile(userId: userId), failed);
      }
      try {
        final member = await _client.getRoomStateWithKey(
          room.id,
          'm.room.member',
          userId,
        );
        final avatar = member['avatar_url'];
        return (
          sdk.Profile(
            userId: userId,
            displayName:
                (member['displayname'] as String?) ?? profile?.displayName,
            avatarUrl: avatar is String ? Uri.tryParse(avatar) : null,
          ),
          false,
        );
      } on Exception catch (error) {
        debugPrint('weft: member state fetch failed for $userId: $error');
        return (profile ?? sdk.Profile(userId: userId), true);
      }
    }

    lookup().then((result) {
      final (profile, failed) = result;
      _profiles[userId] = profile;
      _profilesInFlight.remove(userId);
      // An answer that came out of a *network failure* is not an answer: a
      // DNS blip during first sync used to cache "no name, no picture" for
      // the rest of the session. The empty result still serves for now, but
      // it expires, so a later rebuild asks again on a healthier connection.
      if (failed && profile.avatarUrl == null && profile.displayName == null) {
        Timer(const Duration(seconds: 45), () => _profiles.remove(userId));
      }
      // A name is as much a reason to redraw as a picture: chats waiting on a
      // lazy-loaded member are titled by their raw identifier until this lands.
      if (profile.avatarUrl != null || profile.displayName != null) _rebuild();
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
  final Map<String, List<TimelineSource>> _sources = {};

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
      seen.add(_networkOf(room));
    }
    // SMS earns its place in the rail the same way: by there being threads on
    // it. A phone where the role was declined has none and is offered none.
    if (_sms?.chats.isNotEmpty ?? false) seen.add(ChatNetwork.sms);
    return ChatNetwork.values.where(seen.contains).toList(growable: false);
  }

  @override
  Stream<List<Chat>> watchChats() async* {
    yield _chats;
    yield* _chatsController.stream;
  }

  @override
  Chat? chatForRoom(String roomId) =>
      _chats.where((c) => c.roomIds.contains(roomId)).firstOrNull;

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

    final sources = opened.whereType<TimelineSource>().toList();
    if (sources.isEmpty) {
      throw StateError('Chat $chatId has no reachable rooms');
    }

    final merged = MergedTimeline(sources: sources);
    _timelines[chatId] = merged;
    _sources[chatId] = sources;
    return merged;
  }

  Future<TimelineSource?> _openTimeline(ChatSource source) async {
    // An SMS leg is opened from the provider, not the homeserver, and is
    // otherwise an ordinary source: the watermark rule interleaves it with a
    // WhatsApp leg exactly as it interleaves two bridged ones.
    if (source.network == ChatNetwork.sms) {
      return _sms?.openTimeline(source.roomId);
    }

    final room = _client.getRoomById(source.roomId);
    if (room == null) return null;

    return MatrixTimelineSource(
      timeline: await room.getTimeline(),
      network: source.network,
      ownUserId: _client.userID,
      resolveSender: _identityOf,
    );
  }

  /// The person behind a sender id, for reaction dedupe.
  ///
  /// Recorded merge decisions only: `_graph` answers from handles the user has
  /// actually merged, and an unknown ghost stays itself. The heuristics next
  /// door in `networkFromUserId` guess a network from the shape of a localpart,
  /// which is fine for deciding a glyph and disqualifying here — collapsing two
  /// people who merely look alike does not show a bad suggestion, it deletes
  /// one of their reactions from the tally.
  String _identityOf(String senderId) =>
      _graph.contactIdForUser(senderId) ?? senderId;

  /// Releases an open chat's timelines when the user navigates away.
  void closeTimeline(String chatId) {
    for (final source in _sources.remove(chatId) ?? const <TimelineSource>[]) {
      switch (source) {
        case MatrixTimelineSource():
          source.dispose();
        default:
          // An SMS leg holds no subscription of its own; the repository that
          // built it drops its cache so a reopen re-reads the provider.
          _sms?.closeTimeline(source.roomId);
      }
    }
    _timelines.remove(chatId);
  }

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) async {
    final source = _sendSource(chatId, via: via);
    if (source.network == ChatNetwork.sms) {
      await _requireSms().send(source.roomId, body);
      return;
    }
    await _roomFor(source).sendTextEvent(body);
  }

  @override
  Future<void> sendCalendarInvite(
    String chatId, {
    required String title,
    required DateTime start,
    DateTime? end,
    ChatNetwork? via,
  }) async {
    final target = _sendSource(chatId, via: via);
    if (target.network == ChatNetwork.sms) {
      throw StateError('SMS cannot carry a calendar invitation');
    }
    final room = _roomFor(target);
    final uid =
        'weft-${DateTime.now().millisecondsSinceEpoch}@weft.bostrot.com';
    final when = start.toUtc();
    final until = (end ?? start.add(const Duration(hours: 1))).toUtc();

    String stamp(DateTime t) =>
        '${t.year.toString().padLeft(4, '0')}'
        '${t.month.toString().padLeft(2, '0')}'
        '${t.day.toString().padLeft(2, '0')}T'
        '${t.hour.toString().padLeft(2, '0')}'
        '${t.minute.toString().padLeft(2, '0')}00Z';
    final ics =
        'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Weft//EN\r\n'
        'METHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:$uid\r\n'
        'DTSTART:${stamp(when)}\r\nDTEND:${stamp(until)}\r\n'
        'SUMMARY:${title.replaceAll(RegExp(r'[\r\n]'), ' ')}\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n';

    final calendarBlock = {
      'uid': uid,
      'title': title,
      'start': when.toIso8601String(),
      'end': until.toIso8601String(),
    };
    final readable =
        '📅 $title — '
        '${start.day}.${start.month}.${start.year}, '
        '${start.hour.toString().padLeft(2, '0')}:'
        '${start.minute.toString().padLeft(2, '0')}';

    if (room.encrypted) {
      // No plain-media upload in an encrypted room; the custom key carries
      // everything a Weft peer needs and the body carries it for humans.
      await room.sendEvent({
        'msgtype': sdk.MessageTypes.Text,
        'body': readable,
        kCalendarInviteKey: calendarBlock,
      });
      return;
    }

    final mxc = await _client.uploadContent(
      Uint8List.fromList(ics.codeUnits),
      filename: '$title.ics',
      contentType: 'text/calendar',
    );
    await room.sendEvent({
      'msgtype': sdk.MessageTypes.File,
      'body': readable,
      'filename': '$title.ics',
      'url': mxc.toString(),
      'info': {'mimetype': 'text/calendar', 'size': ics.length},
      kCalendarInviteKey: calendarBlock,
    });
  }

  @override
  Future<void> respondCalendarInvite(
    String roomId,
    String inviteEventId, {
    required CalendarReply reply,
    DateTime? proposedStart,
  }) async {
    final room = _client.getRoomById(roomId);
    if (room == null) throw StateError('That conversation is gone');
    await room.sendEvent({
      'm.relates_to': {
        'rel_type': sdk.RelationshipTypes.reference,
        'event_id': inviteEventId,
      },
      'response': switch (reply) {
        CalendarReply.accepted => 'accept',
        CalendarReply.declined => 'decline',
        CalendarReply.reschedule => 'reschedule',
      },
      if (proposedStart != null)
        'proposed_start': proposedStart.toUtc().toIso8601String(),
    }, type: kCalendarResponseType);

    // Answering an invite that arrived through a bridge: the custom response
    // event above never crosses back over, so the other side would see
    // nothing at all. Say it in words too — that's the only channel the
    // bridge carries.
    final inviteEvent = await room.getEventById(inviteEventId);
    if (inviteEvent != null &&
        inviteEvent.content[kCalendarInviteKey] is! Map) {
      final line = switch (reply) {
        CalendarReply.accepted => '✅ Accepted: ${inviteEvent.text}',
        CalendarReply.declined => '❌ Declined: ${inviteEvent.text}',
        CalendarReply.reschedule =>
          proposedStart == null
              ? '🔄 Asking for another time: ${inviteEvent.text}'
              : '🔄 Proposing ${proposedStart.day}.${proposedStart.month}.'
                    '${proposedStart.year}, '
                    '${proposedStart.hour.toString().padLeft(2, '0')}:'
                    '${proposedStart.minute.toString().padLeft(2, '0')} '
                    'instead: ${inviteEvent.text}',
      };
      await room.sendTextEvent(line);
    }
  }

  @override
  Future<void> editCalendarInvite(
    String roomId,
    String inviteEventId, {
    required String title,
    required DateTime start,
    DateTime? end,
  }) async {
    final room = _client.getRoomById(roomId);
    if (room == null) throw StateError('That conversation is gone');

    final original = await room.getEventById(inviteEventId);
    final oldBlock = original?.content[kCalendarInviteKey];
    final when = start.toUtc();
    final until = (end ?? start.add(const Duration(hours: 1))).toUtc();
    final calendarBlock = {
      // The uid survives the move — it is the same appointment at a new time,
      // which is what lets a device calendar update instead of duplicating.
      'uid': oldBlock is Map
          ? (oldBlock['uid'] ?? 'weft-$inviteEventId')
          : 'weft-$inviteEventId',
      'title': title,
      'start': when.toIso8601String(),
      'end': until.toIso8601String(),
    };
    final readable =
        '📅 $title — '
        '${start.day}.${start.month}.${start.year}, '
        '${start.hour.toString().padLeft(2, '0')}:'
        '${start.minute.toString().padLeft(2, '0')}';

    // A standard m.replace: Weft peers re-read the block from the newest
    // version, everyone else — bridges included — shows an edited message.
    await room.sendEvent({
      'msgtype': sdk.MessageTypes.Text,
      'body': '* $readable',
      kCalendarInviteKey: calendarBlock,
      'm.new_content': {
        'msgtype': sdk.MessageTypes.Text,
        'body': readable,
        kCalendarInviteKey: calendarBlock,
      },
      'm.relates_to': {
        'rel_type': sdk.RelationshipTypes.edit,
        'event_id': inviteEventId,
      },
    });
  }

  @override
  List<String> typingIn(String chatId) {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return const [];
    final names = <String>[];
    for (final source in chat.sources) {
      final room = _client.getRoomById(source.roomId);
      if (room == null) continue;
      for (final user in room.typingUsers) {
        if (user.id == _client.userID) continue;
        // The bridge bot "typing" is plumbing, not a person composing.
        if (networkFromBridgeBotId(user.id) != ChatNetwork.unknown &&
            _botCache[room.id] == user.id) {
          continue;
        }
        names.add(_stripNetworkTag(user.calcDisplayname()));
      }
    }
    return names;
  }

  @override
  Future<void> setTyping(String chatId, {required bool typing}) async {
    final source = _sendSource(chatId);
    if (source.network == ChatNetwork.sms) return;
    final room = _client.getRoomById(source.roomId);
    // 25s server-side expiry: a lost "stopped" update clears itself.
    await room?.setTyping(typing, timeout: typing ? 25000 : null);
  }

  @override
  ({bool online, DateTime? lastActiveAt})? presenceFor(String chatId) {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null || chat.isGroup) return null;
    bool online = false;
    DateTime? lastActive;
    for (final source in chat.sources) {
      final room = _client.getRoomById(source.roomId);
      if (room == null) continue;
      final peerId = _peerOf(room);
      if (peerId == null) continue;
      // The sync-fed cache, synchronously: this runs per app-bar build, and
      // the replacement API is a server round trip per call.
      // ignore: deprecated_member_use
      final cached = _client.presences[peerId];
      if (cached == null) continue;
      if (cached.presence == sdk.PresenceType.online ||
          cached.currentlyActive == true) {
        online = true;
      }
      final at = cached.lastActiveTimestamp;
      if (at != null && (lastActive == null || at.isAfter(lastActive))) {
        lastActive = at;
      }
    }
    if (!online && lastActive == null) return null;
    return (online: online, lastActiveAt: lastActive);
  }

  @override
  List<({String roomId, String eventId, DateTime at})> peerReadUpTo(
    String chatId,
  ) {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return const [];
    final markers = <({String roomId, String eventId, DateTime at})>[];
    for (final source in chat.sources) {
      final room = _client.getRoomById(source.roomId);
      if (room == null) continue;
      // Bridge ghosts' receipts are the real ones: mautrix forwards the
      // remote network's read state as the ghost user reading the room.
      ({String eventId, DateTime at})? newest;
      for (final entry in room.receiptState.global.otherUsers.entries) {
        final at = DateTime.fromMillisecondsSinceEpoch(entry.value.ts);
        if (newest == null || at.isAfter(newest.at)) {
          newest = (eventId: entry.value.eventId, at: at);
        }
      }
      if (newest != null) {
        markers.add((
          roomId: source.roomId,
          eventId: newest.eventId,
          at: newest.at,
        ));
      }
    }
    return markers;
  }

  /// Address-book names by phone digits; see [setContactNameOverrides].
  Map<String, String> _contactNames = const {};

  @override
  void setContactNameOverrides(Map<String, String> namesByPhoneDigits) {
    if (const MapEquality<String, String>().equals(
      _contactNames,
      namesByPhoneDigits,
    )) {
      return;
    }
    _contactNames = Map.unmodifiable(namesByPhoneDigits);
    _scheduleRebuild();
  }

  /// The address-book name for any of [phones], or null.
  ///
  /// Suffix matching, because the two sides rarely agree on formatting: the
  /// bridge says `4915112345678` where the address book says `0151 1234 5678`.
  /// Seven digits of agreement is the threshold under which numbers collide.
  String? _contactNameForPhones(Iterable<String?> phones) {
    if (_contactNames.isEmpty) return null;
    for (final phone in phones) {
      if (phone == null) continue;
      final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.length < 7) continue;
      final direct = _contactNames[digits];
      if (direct != null) return direct;
      for (final entry in _contactNames.entries) {
        if (entry.key.length < 7) continue;
        if (digits.endsWith(entry.key) || entry.key.endsWith(digits)) {
          return entry.value;
        }
      }
    }
    return null;
  }

  @override
  Future<void> createPoll(
    String chatId, {
    required String question,
    required List<String> options,
    ChatNetwork? via,
  }) async {
    final target = _sendSource(chatId, via: via);
    if (target.network == ChatNetwork.sms) {
      throw StateError('SMS cannot carry a poll');
    }
    await _roomFor(target).sendEvent({
      'org.matrix.msc3381.poll.start': {
        'question': {'org.matrix.msc1767.text': question},
        'kind': 'org.matrix.msc3381.poll.disclosed',
        'max_selections': 1,
        'answers': [
          for (var i = 0; i < options.length; i++)
            {'id': 'option_$i', 'org.matrix.msc1767.text': options[i]},
        ],
      },
      // The text fallback older clients render instead of the poll.
      'org.matrix.msc1767.text': [
        question,
        for (var i = 0; i < options.length; i++) '${i + 1}. ${options[i]}',
      ].join('\n'),
    }, type: 'org.matrix.msc3381.poll.start');
  }

  @override
  Future<void> votePoll(
    String roomId,
    String startEventId,
    Set<String> answerIds,
  ) async {
    final room = _client.getRoomById(roomId);
    if (room == null) throw StateError('That poll\'s room is gone');
    await room.sendEvent({
      'm.relates_to': {
        'rel_type': sdk.RelationshipTypes.reference,
        'event_id': startEventId,
      },
      'org.matrix.msc3381.poll.response': {'answers': answerIds.toList()},
    }, type: 'org.matrix.msc3381.poll.response');
  }

  @override
  Future<void> sendLocation(
    String chatId, {
    required double latitude,
    required double longitude,
    ChatNetwork? via,
  }) async {
    final target = _sendSource(chatId, via: via);
    if (target.network == ChatNetwork.sms) {
      throw StateError('SMS cannot carry a location message');
    }
    final geoUri = 'geo:$latitude,$longitude';
    await _roomFor(target).sendEvent({
      'msgtype': sdk.MessageTypes.Location,
      'body': 'Location: $geoUri',
      'geo_uri': geoUri,
    });
  }

  @override
  Future<void> sendReply(
    String chatId,
    String body, {
    required String replyToEventId,
    ChatNetwork? via,
  }) async {
    final target = await _findEvent(chatId, replyToEventId);
    if (target == null) {
      // The target has scrolled out of every loaded timeline and the server no
      // longer serves it — a redacted event in a room with limited history, or
      // a leg the account has left. Sending a plain message is better than
      // losing what the user typed, and the composer has already shown them the
      // quote they were answering. Routed through [send] rather than straight
      // at a room, so a chat whose only leg is SMS — where no event can carry
      // an `m.in_reply_to` at all — still delivers what was typed.
      await send(chatId, body, via: via);
      return;
    }
    // `inReplyTo` is what puts the `m.in_reply_to` block *and* the quoted
    // fallback into the event, so every client that does not render rich
    // replies still shows what this answers.
    await target.room.sendTextEvent(body, inReplyTo: target.event);
  }

  @override
  Future<void> react(String chatId, String eventId, String key) async {
    final target = await _findEvent(chatId, eventId);
    if (target == null) {
      throw StateError('Cannot react to $eventId: it is not in $chatId');
    }
    await target.room.sendReaction(eventId, key);
  }

  @override
  Future<void> unreact(String chatId, String reactionEventId) async {
    final annotation = await _findEvent(chatId, reactionEventId);
    if (annotation == null) {
      throw StateError('Cannot remove reaction $reactionEventId in $chatId');
    }
    await annotation.room.redactEvent(reactionEventId);
  }

  @override
  Future<void> editMessage(
    String chatId,
    String eventId,
    String newBody,
  ) async {
    final target = await _findEvent(chatId, eventId);
    if (target == null) {
      throw StateError('Cannot edit $eventId: it is not in $chatId');
    }
    await target.room.sendTextEvent(newBody, editEventId: eventId);
  }

  @override
  Future<void> redact(String chatId, String eventId) async {
    final target = await _findEvent(chatId, eventId);
    if (target == null) {
      throw StateError('Cannot delete $eventId: it is not in $chatId');
    }
    // Edits are separate events carrying the same words; redacting only the
    // original would leave every version of a deleted message readable to
    // anyone who looks at the relations.
    await target.room.redactEvent(eventId, redactAllEdits: true);
  }

  /// Finds which of [chatId]'s rooms holds [eventId], and the event itself.
  ///
  /// The counterpart to [_sendSource], and deliberately not a variation of it:
  /// sending picks a leg, whereas reacting to, editing, redacting or replying
  /// to an existing event has no choice at all — the event lives in exactly one
  /// room, and that is the only room the relation can be sent to. A merged chat
  /// is where this stops being pedantry: the default send network is whichever
  /// leg last spoke, and reacting to a message on the *other* leg through it
  /// produces an annotation the homeserver stores and nobody can see.
  ///
  /// Returns null rather than throwing when nothing holds the event, so each
  /// caller decides: a reply degrades to a plain message, the rest refuse.
  Future<({sdk.Room room, sdk.Event event})?> _findEvent(
    String chatId,
    String eventId,
  ) async {
    for (final room in _roomsOf(chatId)) {
      try {
        final event = await room.getEventById(eventId);
        if (event != null) return (room: room, event: event);
      } on Exception {
        // A room the account has left, or one whose history the server will not
        // serve. Neither says anything about the other legs.
        continue;
      }
    }
    return null;
  }

  /// The room an outgoing message or attachment for [chatId] goes to.
  ///
  /// Distinct from [_roomsOf], which fans out to *every* room of a merged chat:
  /// muting or archiving applies to the whole conversation, whereas sending
  /// picks exactly one leg. Throws rather than returning null because a send
  /// with nowhere to go must surface to the composer, not fail silently.
  ///
  /// Split from [_roomFor] because the chosen leg is not always a room: an SMS
  /// leg resolves to a thread in the system provider and has no homeserver to
  /// look it up on.
  ChatSource _sendSource(String chatId, {ChatNetwork? via}) {
    final chat = _chats.firstWhere(
      (c) => c.id == chatId,
      orElse: () => throw ArgumentError.value(chatId, 'chatId', 'Unknown chat'),
    );
    return sendSourceFor(chat, via: via);
  }

  sdk.Room _roomFor(ChatSource source) {
    final room = _client.getRoomById(source.roomId);
    if (room == null) {
      throw StateError('Room ${source.roomId} is no longer available');
    }
    return room;
  }

  /// The SMS source, or a refusal the composer can show.
  ///
  /// Reached only when a chat carries an SMS leg, which cannot happen without
  /// one — but the role can be handed to another app while a chat is open, and
  /// "SMS is not available on this device" is a better answer than a null
  /// dereference under the send button.
  SmsChatRepository _requireSms() {
    final sms = _sms;
    if (sms == null) throw StateError('SMS is not available on this device');
    return sms;
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
    _invalidateTimelines();
    _persistGraph();
    _rebuild();
  }

  @override
  Future<void> unmergeHandle(String handleId) async {
    _graph.unmerge(handleId);
    _invalidateTimelines();
    _persistGraph();
    _rebuild();
  }

  /// A merge or unmerge changes which rooms a conversation is *made of*, and
  /// a cached [MergedTimeline] built before it keeps the old set — which is
  /// exactly how a freshly widened merge showed only one leg's history until
  /// the app restarted. Everything cached is dropped and [timelineEpoch]
  /// moves, so open chat views rebuild their timeline on the next sync tick.
  void _invalidateTimelines() {
    _timelines.clear();
    _sources.clear();
    _timelineEpoch++;
  }

  @override
  int get timelineEpoch => _timelineEpoch;
  int _timelineEpoch = 0;

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
    } on Object catch (error) {
      // Object, not Exception: the SDK throws bare *strings* for several of
      // its refusals ("This event hasn't any attachment or thumbnail."), and
      // an `on Exception` let those sail through as unhandled async errors.
      // A missing or undecryptable attachment renders as a placeholder rather
      // than taking the timeline down — but the reason is worth one log line.
      debugPrint('weft: attachment $eventId failed: $error');
      return null;
    }
  }

  @override
  Future<AttachmentLocation?> attachmentLocation(
    String roomId,
    String eventId,
  ) async {
    final room = _client.getRoomById(roomId);
    if (room == null) return null;
    // The whole point of the check: in an encrypted room the mxc URI addresses
    // ciphertext, and only `downloadAndDecryptAttachment` — i.e.
    // [attachmentBytes] — can turn that into the file the user asked for.
    if (room.encrypted) return null;

    try {
      final event = await room.getEventById(eventId);
      final mxc = event?.content['url'];
      if (mxc is! String) return null;

      final url = mxcToDownloadUrl(
        _client,
        mxc,
        authenticatedMedia: _authenticatedMedia,
      );
      final parsed = url == null ? null : Uri.tryParse(url);
      if (parsed == null) return null;

      // Read per call rather than captured: the SDK refreshes access tokens
      // underneath us, and a saved download that 401s ten minutes into a film
      // is the failure this avoids.
      return AttachmentLocation(
        url: parsed,
        headers: mediaAuthHeaders(_client) ?? const {},
      );
    } on Object catch (error) {
      // Same string-throw hazard as [attachmentBytes].
      debugPrint('weft: attachment location $eventId failed: $error');
      return null;
    }
  }

  // --------------------------------------------------------------- send path

  /// Built on first use, not in the constructor: a session that never sends a
  /// file should not open a transport, and the transport caches a homeserver
  /// probe it would otherwise make for nothing.
  MatrixAttachmentTransport? _transportOverride;
  UploadQueue? _queue;
  StreamSubscription<List<UploadTask>>? _uploadSub;

  /// Thumbnails already uploaded, keyed by their attachment's task id.
  ///
  /// Present with a null value means "tried, no preview" — a video, a photo the
  /// spec suppressed, bytes that would not decode. Retrying the attachment must
  /// not put a second copy of the preview on the media repo.
  final Map<String, MatrixThumbnailUpload?> _thumbnails = {};

  /// Rooms with a dispatch loop running, so two queue updates arriving during
  /// one `sendEvent` cannot send the same event twice.
  final Set<String> _dispatching = {};

  /// Uploads whose *event* send failed. See [dispatchableUploads].
  final Set<String> _undispatchable = {};

  int _nextUploadId = 0;

  MatrixAttachmentTransport get _transport =>
      _transportOverride ??= MatrixAttachmentTransport.forClient(_client);

  UploadQueue get _uploads {
    final existing = _queue;
    if (existing != null) return existing;

    final queue = UploadQueue(transport: _transport);
    _uploadSub = queue.updates.listen(_onUploadsChanged);
    return _queue = queue;
  }

  @override
  Future<void> sendAttachment(
    String chatId,
    AttachmentSource source, {
    ChatNetwork? via,
    bool isVoiceNote = false,
    int? durationMs,
  }) async {
    final target = _sendSource(chatId, via: via);
    // Refused rather than silently rerouted to another leg. Sending an MMS
    // means encoding a PDU, which Android does not expose — the same gap that
    // stops incoming MMS being retrieved — and a photo that quietly went out
    // over WhatsApp instead is worse than one that did not go.
    if (target.network == ChatNetwork.sms) {
      throw StateError('Weft cannot send MMS attachments yet');
    }
    final room = _roomFor(target);

    // Every branch of the decision belongs to `weft_attachments`; this supplies
    // only the two things it cannot know — whether the destination room is
    // encrypted, and what the homeserver will accept.
    final decision = planUpload(
      source,
      encrypted: room.encrypted,
      maxUploadBytes: await _transport.maxUploadBytes(),
      isVoiceNote: isVoiceNote,
      durationMs: durationMs,
    );
    if (decision is UploadRejection) {
      throw AttachmentRejectedException(decision);
    }
    final plan = decision as UploadPlan;

    // The id is allocated here rather than by the queue because the payload
    // loader needs it before `enqueue` returns: it is what the thumbnail's own
    // upload is keyed to, and therefore what one `cancel` has to reach.
    final taskId = 'upload-${_nextUploadId++}';
    _uploads.enqueue(
      plan,
      roomId: room.id,
      id: taskId,
      loadPayload: () => _loadPayload(plan, taskId),
    );
    // Returns on acceptance, not on arrival: awaiting the bytes here would put
    // a twenty-photo share through the picker one file at a time.
  }

  /// Reads the file, uploads its preview once, and encrypts what goes on the
  /// wire. Runs per attempt, inside [UploadState.hashing].
  Future<UploadPayload> _loadPayload(UploadPlan plan, String taskId) async {
    final bytes = await _readBytes(plan.source);

    if (!_thumbnails.containsKey(taskId)) {
      _thumbnails[taskId] = await _transport.uploadThumbnail(
        plan,
        sourceBytes: bytes,
        uploadId: taskId,
      );
    }

    return _transport.preparePayload(bytes, encrypted: plan.encrypted);
  }

  void _onUploadsChanged(List<UploadTask> tasks) {
    for (final roomId in {for (final task in tasks) task.roomId}) {
      unawaited(_dispatchRoom(roomId));
    }
  }

  /// Sends the events for every upload at the head of [roomId]'s queue that has
  /// finished, oldest first, and drops each task once its event is away.
  Future<void> _dispatchRoom(String roomId) async {
    if (!_dispatching.add(roomId)) return;
    try {
      while (true) {
        final next = dispatchableUploads(
          _uploads.tasksFor(roomId),
          blocked: _undispatchable,
        ).firstOrNull;
        if (next == null) return;
        await _sendUploadedEvent(next);
      }
    } finally {
      _dispatching.remove(roomId);
    }
  }

  Future<void> _sendUploadedEvent(UploadTask task) async {
    final room = _client.getRoomById(task.roomId);
    final uri = task.uri;
    if (room == null || uri == null) {
      // The room has gone, or a transport reported success without a URI.
      // Either way there is nothing to send and nothing a retry would fix.
      _forgetUpload(task.id);
      return;
    }

    final thumbnail = _thumbnails[task.id];
    try {
      await room.sendEvent(
        task.plan.toEventContent(
          uri: uri,
          file: task.file,
          thumbnailUri: thumbnail?.uri,
          thumbnailFile: thumbnail?.file,
          thumbnailSizeBytes: thumbnail?.sizeBytes,
          thumbnailDimensions: thumbnail?.dimensions,
        ),
      );
      // The SDK's own local echo takes over from here — the event is in the
      // room's timeline as `sending` before this returns — so the queue's task
      // has done its job and would otherwise render as a second bubble.
      _forgetUpload(task.id);
    } on Object catch (error) {
      // The bytes are on the server; only the event failed. The task keeps its
      // uri and key material, so [retryUpload] re-sends the event without
      // pushing a megabyte a second time, and blocking it here stops the rest
      // of the batch queueing behind a send that will not recover on its own.
      debugPrint(
        'weft: attachment event for ${task.id} failed to send: $error',
      );
      _undispatchable.add(task.id);
    }
  }

  void _forgetUpload(String taskId) {
    _uploads.remove(taskId);
    _thumbnails.remove(taskId);
    _undispatchable.remove(taskId);
  }

  @override
  Stream<List<UploadTask>> watchUploads(String chatId) =>
      watchUploadQueue(_uploads, (tasks) => _uploadsForChat(chatId, tasks));

  /// Resolved per emission rather than once: merging two conversations changes
  /// which rooms a chat id covers, and a share in flight across that change
  /// should follow the chat the user is looking at.
  List<UploadTask> _uploadsForChat(String chatId, List<UploadTask> tasks) {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    // An unmerged chat's id *is* its room id, which is what keeps this working
    // for a chat the inbox has not rebuilt yet.
    final rooms = chat?.roomIds ?? [chatId];
    return [
      for (final task in tasks)
        if (rooms.contains(task.roomId)) task,
    ];
  }

  @override
  Future<void> retryUpload(String taskId) async {
    // An upload whose event send failed has nothing left to upload: re-sending
    // it is the whole retry, and pushing the bytes again would leave an orphan
    // copy on the media repo.
    if (_undispatchable.remove(taskId)) {
      final task = _uploads.task(taskId);
      if (task != null) await _sendUploadedEvent(task);
      return;
    }
    _uploads.retry(taskId);
  }

  @override
  Future<void> cancelUpload(String taskId) async {
    _uploads.cancel(taskId);
    _thumbnails.remove(taskId);
    _undispatchable.remove(taskId);
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
      // Emptiness is asked of the projection, not of the raw body: a message
      // whose whole body was a dropped subtree says nothing to a reader and
      // would otherwise be indexed as a blank row.
      messages.where((m) => !m.redacted && plainTextOf(m).isNotEmpty),
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
      if (source.network == ChatNetwork.sms) {
        await _sms?.markRead(source.roomId);
        continue;
      }
      final room = _client.getRoomById(source.roomId);
      final lastEvent = room?.lastEvent;
      if (room == null || lastEvent == null) continue;
      // Recorded before the request: the badge clears the moment the user
      // opens the conversation, not a server round trip and a sync later —
      // and a merged chat summing three legs' stale server counts read as
      // "7 unread" for one new message until every receipt landed.
      _readUpTo[room.id] = lastEvent.eventId;
      // `public: false` sends only the private receipt: this account's other
      // devices still clear the unread badge, but the sender is not told.
      // Bridges relay the public receipt to the remote network as its native
      // read marker, so this switch is exactly WhatsApp's blue-ticks toggle.
      final tellSender =
          _settings?.getBool(WeftSettings.sendReadReceipts, fallback: true) ??
          true;
      try {
        await room.setReadMarker(
          lastEvent.eventId,
          mRead: lastEvent.eventId,
          public: tellSender,
        );
      } on Object catch (error) {
        // One leg refusing its receipt (a local-echo id, a server hiccup)
        // must not abandon the other legs — which is exactly how a merged
        // chat's count got stuck.
        debugPrint('weft: read receipt for ${room.id} failed: $error');
      }
    }
    _scheduleRebuild();
  }

  Future<void> dispose() async {
    await _syncSub?.cancel();
    await _smsSub?.cancel();
    await _uploadSub?.cancel();
    // Cancels everything outstanding: an upload with no repository left to send
    // its event would push bytes nobody will ever reference.
    await _queue?.dispose();
    _transportOverride?.dispose();
    for (final chatId in _sources.keys.toList()) {
      closeTimeline(chatId);
    }
    await _chatsController.close();
  }

  // ------------------------------------------------------------------ rebuild

  @override
  Set<String> get serviceChatIds => _serviceChatIds;
  Set<String> _serviceChatIds = const {};

  /// A room that exists to *operate* a bridge: the user plus its service bot.
  ///
  /// Scanned over participants rather than resolved through [_peerOf], and
  /// that is the fix for the one that kept showing: mautrix *names* its
  /// management rooms ("Google Messages bridge bot"), and a named room gets
  /// no summary heroes — so a hero-based peer lookup came back empty and the
  /// room passed as a normal chat. The bot suffix alone is not enough — a
  /// person may be called `@robot:...` — so the localpart must also resolve
  /// to a known network the way mautrix bots name themselves.
  bool _isServiceChat(sdk.Room room) =>
      _serviceCache[room.id] ??= _computeIsServiceChat(room);

  bool _computeIsServiceChat(sdk.Room room) {
    final participants = room.getParticipants();
    if (participants.length > 3) return false;

    var foundBot = false;
    for (final participant in participants) {
      if (participant.id == _client.userID) continue;
      final localpart = participant.id.split(':').first;
      if (localpart.endsWith('bot') &&
          networkFromBridgeBotId(participant.id) != ChatNetwork.unknown) {
        foundBot = true;
      } else {
        // Someone who is neither the user nor a bridge bot: a real
        // conversation the bot happens to sit in must not vanish.
        return false;
      }
    }
    return foundBot;
  }

  void _rebuild() {
    _refreshIdentityGraph();

    final service = <String>{};
    final byRoom = <String, Chat>{};
    for (final room in _client.rooms) {
      if (room.isSpace) continue;
      byRoom[room.id] = _chatFromRoom(room);
      if (_isServiceChat(room)) service.add(room.id);
    }
    _serviceChatIds = service;
    // Into the *same* map, not appended to the result: this is what makes an
    // SMS thread a candidate for [_applyMerges] rather than a row that is only
    // ever shown on its own. A number the user has merged with their WhatsApp
    // handle folds into one conversation from here on.
    for (final chat in _sms?.chats ?? const <Chat>[]) {
      byRoom[chat.id] = chat;
    }

    _chats = _applyMerges(byRoom);
    if (!_chatsController.isClosed) _chatsController.add(_chats);
  }

  /// The peer's human name, resolved the same way for titles and handles.
  ///
  /// Member event first, fetched profile second, and always with the bridge's
  /// " (WA)"-style suffix stripped — the merge scorer compares names *exactly*,
  /// and "Joanne (WA)" versus "Joanne" is how two chats with the same person's
  /// name on them never became a suggestion.
  String? _peerDisplayName(sdk.Room room, String peerId) {
    final fromMember = room
        .unsafeGetUserFromMemoryOrFallback(peerId)
        .displayName
        ?.trim();
    if (fromMember != null && fromMember.isNotEmpty) {
      return _stripNetworkTag(fromMember);
    }
    final fetched = _profiles[peerId]?.displayName?.trim();
    if (fetched != null && fetched.isNotEmpty) {
      return _stripNetworkTag(fetched);
    }
    return null;
  }

  /// Rebuilds handles from direct chats so the scorer can suggest merges.
  ///
  /// Only DMs participate: merging two group rooms is not a "same person"
  /// question, so groups are always left alone. A DM is what [_peerOf] says it
  /// is — bridge portals usually never enter `m.direct`, and skipping them
  /// here is why a WhatsApp chat and an SMS thread with the same person on
  /// them could not be offered as a merge at all.
  void _refreshIdentityGraph() {
    for (final room in _client.rooms) {
      if (room.isSpace) continue;

      final peerId = _peerOf(room);
      if (peerId == null) continue;

      final network = _networkOf(room);
      final peer = room.unsafeGetUserFromMemoryOrFallback(peerId);

      final handle = NetworkHandle(
        id: peerId,
        network: network,
        remoteId: _remoteIdFor(peerId, network),
        matrixUserId: peerId,
        roomId: room.id,
        displayName: _peerDisplayName(room, peerId) ?? peer.calcDisplayname(),
        avatarUrl:
            _thumbnail(peer.avatarUrl?.toString()) ??
            _thumbnail(_profiles[peerId]?.avatarUrl?.toString()),
        // The localpart of a bridged ghost is often the phone number. Storing
        // the normalised form means the strongest merge signal is actually
        // persisted, rather than left for the scorer to re-derive each pass —
        // and `normalizePhone` returns null for anything implausible, so a
        // Signal account id or a Discord snowflake simply doesn't set it.
        phoneE164: normalizePhone(_remoteIdFor(peerId, network)),
      );
      _graph.upsertHandle(handle);
      // Written to SQLite only when something actually changed: the graph
      // refresh runs on every (debounced) sync, and re-writing several dozen
      // identical rows each pass was a solid slice of the first minute's
      // scroll jank.
      final fingerprint =
          '${handle.displayName}|${handle.avatarUrl}|${handle.phoneE164}|'
          '${_graph.contactIdOf(handle.id)}';
      if (_handleFingerprints[handle.id] != fingerprint) {
        _handleFingerprints[handle.id] = fingerprint;
        _store?.upsertHandle(
          handle.copyWith(unifiedContactId: _graph.contactIdOf(handle.id)),
        );
      }
    }

    // SMS contributes handles in exactly the same shape, which is the whole
    // reason no merge code changed for this network: `MergeScorer` normalises
    // `phoneE164` on both sides and raises `phoneExact` at 0.95, so an SMS
    // thread and a WhatsApp chat for one number become a suggestion in the
    // existing merge screen, with the existing "Same phone number" evidence.
    for (final handle in _sms?.handles ?? const <NetworkHandle>[]) {
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

  /// Per-room answers that are expensive to compute and effectively never
  /// change for a given room: which network it belongs to, whether it is a
  /// bridge's management room, and which bot serves it. Each involves walking
  /// the member list, and each used to be recomputed for every room on every
  /// rebuild.
  final Map<String, ChatNetwork> _networkCache = {};
  final Map<String, bool> _serviceCache = {};
  final Map<String, String?> _botCache = {};

  ChatNetwork _networkOf(sdk.Room room) =>
      _networkCache[room.id] ??= networkForRoom(room);

  /// The bridge's service bot in [room], from its `m.bridge` state, or null.
  ///
  /// The bot is a member of every portal room it manages, and it poisons any
  /// computation that treats members as people: DM detection, hero-derived
  /// titles, avatars. Reading it from state rather than pattern-matching on
  /// localparts means a bridge with an unconventional bot name still works.
  String? _bridgeBotOf(sdk.Room room) {
    if (_botCache.containsKey(room.id)) return _botCache[room.id];
    return _botCache[room.id] = _computeBridgeBot(room);
  }

  String? _computeBridgeBot(sdk.Room room) {
    for (final type in bridgeStateEventTypes) {
      final states = room.states[type];
      if (states == null) continue;
      for (final event in states.values) {
        final bot = event.content['bridgebot'];
        if (bot is String && bot.isNotEmpty) return bot;
      }
    }
    return null;
  }

  /// The person this room is a conversation *with*, when it is one.
  ///
  /// `m.direct` first — but bridge portal rooms are only in `m.direct` when
  /// the bridge bothered to put them there, and several do not. A two-person
  /// room still names the other side in its summary heroes, so that is the
  /// fallback; without it every bridged DM outside `m.direct` was treated as
  /// a group and never looked up its contact's picture at all.
  ///
  /// The bridge bot does not count as a person: a portal DM has *three*
  /// members — the user, the contact's ghost, and the bot — and counting the
  /// bot made every such DM look like a group.
  String? _peerOf(sdk.Room room) {
    final direct = room.directChatMatrixID;
    if (direct != null) return direct;

    final bot = _bridgeBotOf(room);
    final joined = room.summary.mJoinedMemberCount ?? 0;
    final invited = room.summary.mInvitedMemberCount ?? 0;
    if (joined + invited > (bot == null ? 2 : 3)) return null;

    final ownId = _client.userID;
    for (final hero in room.summary.mHeroes ?? const <String>[]) {
      if (hero != ownId && hero != bot) return hero;
    }
    return null;
  }

  /// A network-decorated ghost name, undecorated.
  ///
  /// Bridge display-name templates append the network — "Anna (WA)",
  /// "Anna (Signal)" — which is redundant in a UI that already labels every
  /// chat with its network glyph, and noise in a merged conversation.
  static String _stripNetworkTag(String name) {
    final stripped = name
        .replaceFirst(
          RegExp(
            r'\s*\((WA|WhatsApp|Signal|Telegram|TG|SMS|FB|'
            r'Messenger|IG|Instagram|Discord|Slack|GChat|iMessage|LinkedIn|'
            r'Meta|X|Twitter)\)\s*$',
          ),
          '',
        )
        .trim();
    return stripped.isEmpty ? name : stripped;
  }

  /// What the inbox calls this room.
  ///
  /// The SDK's `getLocalizedDisplayname` names an unnamed room after its
  /// heroes — for a bridged DM that produced "WhatsApp bridge bot, Anna (WA)",
  /// because the bot is a hero too. An explicitly named room keeps its name;
  /// an unnamed conversation is named after the person it is with.
  String _titleFor(sdk.Room room) {
    final peerId = _peerOf(room);
    // The user's own name for this person outranks whatever the network or
    // the room state calls them.
    if (peerId != null) {
      final fromContacts = _contactNameForPhones([
        _graph.handleFor(peerId)?.phoneE164,
        _remoteIdFor(peerId, _networkOf(room)),
      ]);
      if (fromContacts != null) return fromContacts;
    }
    if (peerId == null) return room.getLocalizedDisplayname();

    final explicit = room.getState(sdk.EventTypes.RoomName)?.content['name'];
    if (explicit is String && explicit.trim().isNotEmpty) {
      return _stripNetworkTag(explicit);
    }

    final resolved = _peerDisplayName(room, peerId);
    if (resolved != null) return resolved;
    // The member event is lazy-loaded and no profile is cached yet; ask once
    // and name the chat after the peer's own identifier meanwhile — a phone
    // number is a worse name than "Anna" but a far better one than
    // "WhatsApp bridge bot, Anna (WA)".
    _ensureProfile(peerId, room: room);
    return _stripNetworkTag(_remoteIdFor(peerId, _networkOf(room)));
  }

  /// Room avatar, else the DM partner's member event, else a fetched profile.
  ///
  /// The third step is the one that matters in practice: rooms sync with
  /// lazy-loaded members, so a bridged contact's member event — and with it
  /// their avatar — is usually not in memory at all. No amount of fixing the
  /// URL helps when the source mxc is simply absent.
  @override
  String? avatarUrlFor(String userId, {String? roomId}) {
    final room = roomId == null ? null : _client.getRoomById(roomId);
    if (room != null) {
      final fromMember = _thumbnail(
        room.unsafeGetUserFromMemoryOrFallback(userId).avatarUrl?.toString(),
      );
      if (fromMember != null) return fromMember;
    }
    final cached = _profiles[userId];
    if (cached != null) return _thumbnail(cached.avatarUrl?.toString());
    _ensureProfile(userId, room: room);
    return null;
  }

  String? _avatarFor(sdk.Room room) {
    final roomAvatar = _thumbnail(room.avatar?.toString());
    if (roomAvatar != null) return roomAvatar;

    final peerId = _peerOf(room);
    if (peerId == null) return null;

    final fromMember = _thumbnail(
      room.unsafeGetUserFromMemoryOrFallback(peerId).avatarUrl?.toString(),
    );
    if (fromMember != null) return fromMember;

    final cached = _profiles[peerId];
    if (cached != null) return _thumbnail(cached.avatarUrl?.toString());

    _ensureProfile(peerId, room: room);
    return null;
  }

  Chat _chatFromRoom(sdk.Room room) {
    final network = _networkOf(room);
    final lastEvent = room.lastEvent;

    return Chat(
      id: room.id,
      title: _titleFor(room),
      contactId: switch (_peerOf(room)) {
        null => null,
        final peer => _graph.contactIdOf(peer),
      },
      sources: [
        ChatSource(
          roomId: room.id,
          network: network,
          // Per leg, and it is not the same fact as [Chat.muted]: a merged
          // chat is muted only when *every* leg is, so a contact muted on
          // WhatsApp and live on Signal reads as unmuted at chat level. This
          // is what `evaluateNotification`'s `sourceMuted` rule tests, and
          // without it that rule can never fire against a real chat.
          muted: room.pushRuleState != sdk.PushRuleState.notify,
        ),
      ],
      avatarUrl: _avatarFor(room),
      lastMessage: lastEvent == null
          ? null
          : mapEvent(lastEvent, network: network, ownUserId: _client.userID),
      unreadCount: _readUpTo[room.id] == lastEvent?.eventId
          ? 0
          : room.notificationCount,
      // A resolved peer means "conversation with a person", whatever the
      // member count says: a bridged DM carries the bot as a third member and
      // is usually missing from m.direct, and calling it a group is what put
      // group styling on half the inbox.
      isGroup: _peerOf(room) == null,
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
          title:
              _contactNameForPhones([
                for (final handle in _graph.handlesInContact(contact.id))
                  handle.phoneE164,
              ]) ??
              contact.displayName,
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
