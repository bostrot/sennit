import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:collection/collection.dart' show MapEquality;
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_richtext/weft_richtext.dart';
import 'package:weft_store/weft_store.dart';

import 'auto_reply_transport.dart';
import 'chat_repository.dart';
import 'profile_lookups.dart';
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
/// The pickers Sennit uses hand over a real path, and Android's share-in copies a
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
class MatrixChatRepository implements ChatRepository, AutoReplyTransport {
  MatrixChatRepository(
    this._session, {
    IdentityStore? store,
    SearchStore? searchStore,
    RetentionStore? retention,
    SettingsStore? settings,
    MatrixAttachmentTransport? transport,
    AttachmentBytesLoader readBytes = readAttachmentFile,
    SmsChatRepository? sms,
    void Function(List<UploadTask> tasks)? onUploads,
  }) : _store = store,
       _settings = settings,
       _searchStore = searchStore,
       _retention = retention,
       _transportOverride = transport,
       _readBytes = readBytes,
       _sms = sms,
       _onUploads = onUploads {
    // Rehydrate: stored handles and decisions rebuild the same partition the
    // user last saw, which is what makes an unmerge survive a restart.
    final storedHandles = _store?.loadHandles() ?? const <NetworkHandle>[];
    _graph = IdentityGraph(
      // The scorer reads its two knobs from settings: the country code that
      // makes national numbers comparable, and whether same-name pairs merge
      // on their own. Auto-merge defaults on — its rule is narrow enough to
      // trust (identical substantial name, different networks, one-to-one)
      // and it is what makes a fresh login fold a person's three apps into
      // one conversation without a tour through the merge screen.
      scorer: MergeScorer(
        config: MergeScoringConfig(
          autoMergeOnIdentitySignal:
              _settings?.getBool(
                WeftSettings.autoMergeOnIdentitySignal,
                fallback: true,
              ) ??
              true,
          defaultCountryCode: _settings?.getString(
            WeftSettings.defaultCountryCode,
          ),
        ),
      ),
      handles: storedHandles,
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
    // What the database already says, so the first rebuild does not say it
    // again. `_handleFingerprints` starts empty on every launch while the rows
    // it describes do not, and the refresh below reads an empty map as "none of
    // these handles has ever been written" — so every launch rewrote every
    // handle, plus the `unified_contact` row each merged one points at, one
    // synchronous SQLite statement at a time on the UI thread, before the inbox
    // had drawn. Seeded from the same rows the graph was just rehydrated from,
    // a handle that has not moved since the last run costs nothing.
    for (final handle in storedHandles) {
      _handleFingerprints[handle.id] = handleFingerprint(_asPersisted(handle));
    }
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
      // meanwhile. A phone where Sennit is not the default SMS app settles
      // immediately on "no threads" and nothing here ever fires again.
      unawaited(sms.start());
    }
  }

  final WeftMatrixSession _session;
  final IdentityStore? _store;
  final SettingsStore? _settings;
  final SearchStore? _searchStore;

  /// Self-deleting chats: which conversations erase themselves, and what has
  /// already been erased here. Null wherever retention is not configured, and
  /// every path below reads it as "nothing self-deletes".
  final RetentionStore? _retention;

  final AttachmentBytesLoader _readBytes;

  /// SMS, when this device has it and Sennit holds the role. Null everywhere
  /// else, which is the state every path below has to work in anyway.
  final SmsChatRepository? _sms;

  /// Told about every change to the upload queue, so the app can keep
  /// uploads running — with their progress in a notification — after the user
  /// leaves it.
  final void Function(List<UploadTask> tasks)? _onUploads;

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
  final DateTime _bornAt = DateTime.now();
  void _scheduleRebuild() {
    // The whole room scan runs on the UI thread, so its cadence *is* the
    // scroll's frame budget. While the initial sync storm is still landing —
    // the first half minute — one rebuild every 1.5s keeps the inbox alive
    // without re-scanning the world under the user's finger; after that the
    // 300ms trailing edge is imperceptible again.
    final settling =
        DateTime.now().difference(_bornAt) < const Duration(seconds: 30);
    _rebuildDebounce ??= Timer(
      Duration(milliseconds: settling ? 1500 : 300),
      () {
        _rebuildDebounce = null;
        _rebuild();
      },
    );
  }

  final Map<String, ChatNetwork> _sendNetworks = {};

  /// Whether the homeserver serves media from the authenticated endpoint.
  /// Assumed true (the modern default) until the probe answers; a rebuild
  /// follows so avatars correct themselves rather than staying broken.
  bool _authenticatedMedia = true;

  /// What was last written to the identity store per handle, so an unchanged
  /// handle is not rewritten on every sync-driven refresh.
  ///
  /// Seeded in the constructor from the rows already in the database, because
  /// an empty map at launch means every one of them gets written back
  /// unchanged. See [handleFingerprint] for why comparing these strings is the
  /// same question as comparing the rows.
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

  /// Profile lookups go out a few at a time. One rebuild of a large account
  /// asks for a profile per conversation, and issuing them together was a
  /// couple of thousand requests in one frame — see [LookupLane].
  final LookupLane _profileLane = LookupLane();

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

    _profileLane.add(() async {
      final (profile, failed) = await lookup();
      // What the inbox shows for this person right now. Read before the answer
      // is filed, because afterwards it *is* the answer.
      final shown = _graph.handleFor(userId);
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
      //
      // Only when it says something the inbox is not already showing, though,
      // and never straight away. A rebuild scans every room and, when a handle
      // moved, scores every pair of them for a merge; one per answer made a
      // launch cost the square of the account — a thousand contacts, a
      // thousand full rebuilds, back to back on the UI thread, every time the
      // app was opened. Scheduled, the answers that land within one window
      // share a single rebuild.
      final name = profile.displayName?.trim();
      final news =
          _thumbnail(profile.avatarUrl?.toString()) != shown?.avatarUrl ||
          (name != null &&
              name.isNotEmpty &&
              _stripNetworkTag(name) != shown?.displayName);
      if (news) _scheduleRebuild();
    });
  }

  Future<void> _resolveMediaSupport() async {
    try {
      final supported = await _client.authenticatedMediaSupported();
      if (supported == _authenticatedMedia) return;
      _authenticatedMedia = supported;
      _rebuild();
    } on Object catch (error) {
      // Probe failed; the assumed default stands.
      //
      // `Object`, not `Exception`. The repository is built before the client
      // necessarily has a homeserver, and asking one that is not there throws
      // a `TypeError` from inside the SDK — an `Error`, which an `on Exception`
      // clause does not catch. That escaped as an unhandled exception on every
      // launch of a signed-out app: loud, alarming, and about a probe whose
      // failure this method is written to tolerate.
      debugPrint('weft: media-auth probe failed, assuming default: $error');
    }
  }

  /// Timelines are expensive to build and hold subscriptions, so an open chat
  /// reuses its sources instead of rebuilding them on every sync.
  final Map<String, MergedTimeline> _timelines = {};
  final Map<String, List<TimelineSource>> _sources = {};

  static String Function() _idFactory() {
    // Stamped per run: the old counter restarted at zero every launch and
    // collided with ids already persisted, which dropped freshly unmerged
    // (and brand-new) handles into strangers' contacts. The graph now also
    // refuses colliding ids outright; this makes them not happen at all.
    var n = 0;
    final run = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return () => 'contact_${run}_${n++}';
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
      // What a retention sweep has already deleted here. Read at open rather
      // than per event: the homeserver still holds these, so a backfill would
      // otherwise walk them straight back into a conversation the user was
      // told erases itself.
      purgedEventIds: _retention?.purgedIn(source.roomId) ?? const {},
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
  Future<String?> sendAutoReply(
    String chatId,
    String body, {
    ChatNetwork? via,
  }) async {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) {
      throw ArgumentError.value(chatId, 'chatId', 'Unknown chat');
    }
    // Beneath the engine's own guard, not instead of it. A machine-written
    // answer to a stranger tells them the handle is live, is read, and is worth
    // trying again — and this is the last place that can still be refused.
    if (chat.isPendingRequest) {
      throw StateError('Auto-reply refuses to answer a pending request');
    }

    // Which legs were unread *before* the send. Recorded rather than assumed,
    // because auto-reply must not invent a badge: a conversation the user has
    // open and caught up on stays caught up. `_unreadCountFor` is the same
    // function the inbox row reads, so this cannot disagree with what is on
    // screen.
    final unreadBefore = <String, bool>{};
    for (final source in chat.sources) {
      if (source.network == ChatNetwork.sms) continue;
      final room = _client.getRoomById(source.roomId);
      if (room == null) continue;
      unreadBefore[room.id] = _unreadCountFor(room, room.lastEvent) > 0;
    }

    final target = _sendSource(chatId, via: via);
    String? eventId;
    if (target.network == ChatNetwork.sms) {
      // No custom keys on a text message, and none needed: `_ingest` leaves an
      // existing thread's unread count alone for an outgoing message, so the
      // SMS leg keeps its badge without anything being re-asserted.
      await _requireSms().send(target.roomId, body);
    } else {
      eventId = await _roomFor(target).sendEvent({
        'msgtype': sdk.MessageTypes.Text,
        'body': body,
        kAutoReplyKey: true,
      });
    }

    await _restoreUnread(unreadBefore);
    _scheduleRebuild();
    return eventId;
  }

  /// Puts back the unread flag on every leg that had one before an auto-reply.
  ///
  /// This is the crux of the feature, and it is not about receipts. Nothing in
  /// [sendAutoReply] writes one — the problem is that `isReadLocally` treats
  /// *the user's own newest event* as proof they have read the room, which is
  /// right for a message they typed and wrong for one their model sent. The
  /// MSC2867 flag is checked before that clause in [_unreadCountFor], so
  /// setting it is what survives the send.
  ///
  /// It is also the multi-device half. `markUnread` writes room account data,
  /// which syncs, so a reply sent from the phone leaves the laptop's badge
  /// standing too — a purely local variable could not do that.
  ///
  /// Per leg and non-fatal: one room refusing the flag must not abandon the
  /// others, and a failure here is a badge that cleared, not a message lost.
  Future<void> _restoreUnread(Map<String, bool> unreadBefore) async {
    for (final entry in unreadBefore.entries) {
      if (!entry.value) continue;
      final room = _client.getRoomById(entry.key);
      if (room == null) continue;
      // The optimistic marker from an earlier visit would zero the badge back
      // out on the next rebuild. `markUnread` does the same for the same
      // reason.
      _readUpTo.remove(room.id);
      if (room.markedUnread) continue;
      try {
        await room.markUnread(true);
      } on Object catch (error) {
        debugPrint('weft: auto-reply could not keep ${room.id} unread: $error');
      }
    }
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
        'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Sennit//EN\r\n'
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
      // everything a Sennit peer needs and the body carries it for humans.
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
  Future<String?> createDirectChat(String matrixUserId) async {
    final roomId = await _client.startDirectChat(matrixUserId.trim());
    _rebuild();
    return chatForRoom(roomId)?.id ?? roomId;
  }

  @override
  Future<String?> createGroupChat(
    String name,
    List<String> inviteMatrixIds,
  ) async {
    final roomId = await _client.createGroupChat(
      groupName: name,
      invite: inviteMatrixIds,
      preset: sdk.CreateRoomPreset.privateChat,
      enableEncryption: true,
    );
    _rebuild();
    return chatForRoom(roomId)?.id ?? roomId;
  }

  @override
  Future<bool> startBridgeChat(ChatNetwork network, String identifier) async {
    for (final chatId in serviceChatIds) {
      final room = _client.getRoomById(chatId);
      if (room == null) continue;
      final bot = _bridgeBotOf(room);
      if (bot == null || networkFromBridgeBotId(bot) != network) continue;
      // bridgev2's own verb; the portal room arrives by sync once the bridge
      // has resolved the identifier.
      await room.sendTextEvent('start-chat ${identifier.trim()}');
      return true;
    }
    return false;
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
    // The other half of the receipt rule. A typing notification is a stronger
    // signal than a read receipt — it says a person is at the keyboard, right
    // now, because of your message — and a user drafting a reply to a stranger
    // and thinking better of it would have told them everything.
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat?.isPendingRequest ?? false) return;

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
  List<({String roomId, String userId, String eventId, DateTime at})>
  peerReadUpTo(String chatId) {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return const [];

    final bots = <String>{};
    final markers =
        <({String roomId, String userId, String eventId, DateTime at})>[];
    for (final source in chat.sources) {
      final room = _client.getRoomById(source.roomId);
      if (room == null) continue;
      final bot = _bridgeBotOf(room);
      if (bot != null) bots.add(bot);

      // One entry per reader, not one per room. Bridge ghosts' receipts are
      // the real ones: mautrix forwards the remote network's read state as the
      // ghost user reading the room, so a WhatsApp contact's blue tick arrives
      // here as `@whatsapp_49151…` having read the event.
      //
      // The bridge *bot* is skipped. It is a member of every bridged room and
      // its receipt is plumbing rather than a person having looked at
      // anything — counted, it would satisfy a two-person group on its own.
      for (final entry in room.receiptState.global.otherUsers.entries) {
        if (entry.key == bot) continue;
        markers.add((
          roomId: source.roomId,
          userId: entry.key,
          eventId: entry.value.eventId,
          at: DateTime.fromMillisecondsSinceEpoch(entry.value.ts),
        ));
      }
    }
    return markers;
  }

  @override
  List<({String roomId, String eventId, DateTime at})> ownReadUpTo(
    String chatId,
  ) {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return const [];

    final markers = <({String roomId, String eventId, DateTime at})>[];
    for (final source in chat.sources) {
      final room = _client.getRoomById(source.roomId);
      // `receiptState.global.latestOwnReceipt` is this account's `m.read` in
      // this room, wherever it was last moved from — including from another
      // device, which is the case that makes it worth reading at all.
      final own = room?.receiptState.global.latestOwnReceipt;
      if (own == null) continue;
      markers.add((
        roomId: source.roomId,
        eventId: own.eventId,
        at: DateTime.fromMillisecondsSinceEpoch(own.ts),
      ));
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
    _contactNamesBySuffix = {
      for (final entry in namesByPhoneDigits.entries)
        if (entry.key.length >= 9)
          entry.key.substring(entry.key.length - 9): entry.value
        else
          entry.key: entry.value,
    };
    _scheduleRebuild();
  }

  /// The same names keyed by the last nine digits, so a lookup is a hash
  /// probe instead of a scan — the scan ran per room per rebuild, which the
  /// launch stutter could feel.
  Map<String, String> _contactNamesBySuffix = const {};

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
      final suffix = digits.length >= 9
          ? digits.substring(digits.length - 9)
          : digits;
      final bySuffix = _contactNamesBySuffix[suffix];
      if (bySuffix != null) return bySuffix;
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
  Future<void> sendThreadReply(
    String chatId,
    String body, {
    required String threadRootId,
    String? replyToEventId,
    String? threadLatestEventId,
  }) async {
    final root = await _findEvent(chatId, threadRootId);
    if (root == null) {
      throw StateError(
        'Cannot reply in thread $threadRootId: it is not in $chatId',
      );
    }

    // Passed apart, because `is_falling_back` is the difference and the SDK
    // derives it from which of the two is given. An explicit `inReplyTo` marks
    // the relation as a real reply — the user picked a message in the thread and
    // answered it. `threadLastEventId` marks it as the spec's *fallback*, which
    // is what a plain message typed into a thread is: it points at the newest
    // event so a client with no thread support renders the exchange as a chain,
    // while a client that does render threads knows to ignore the quote.
    //
    // Getting this backwards shows every thread message quoting the one before
    // it, in a view where they are already one under the other.
    final explicit = replyToEventId == null
        ? null
        : await _findEvent(chatId, replyToEventId);

    await root.room.sendTextEvent(
      body,
      threadRootEventId: threadRootId,
      threadLastEventId: threadLatestEventId ?? threadRootId,
      inReplyTo: explicit?.event,
    );
  }

  @override
  Future<ChatRequestState?> answerChatRequest(
    String chatId,
    ChatRequestAction action,
  ) async {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    final current = chat?.request;
    if (chat == null || !isPendingRequest(current)) return current;

    final next = applyChatRequestAction(current!, action);
    // Recorded before the awaits, not after. The buttons disappear on the next
    // rebuild, and a rebuild can land while a `leave` is still on the wire —
    // leaving the row back in the requests section with its buttons live, which
    // reads as the tap having done nothing.
    for (final source in chat.sources) {
      _answeredRequests[source.roomId] = next;
    }
    _rebuild();

    // Per leg: a merged request is one conversation to the user and several
    // rooms underneath, and accepting it has to answer all of them or the
    // unanswered legs come straight back as a second request.
    for (final source in chat.sources) {
      final plan = planChatRequest(action: action, network: source.network);
      final room = _client.getRoomById(source.roomId);
      if (room == null) continue;

      // Deliberately no `markRead` anywhere in this method, and no
      // `setTyping`. The whole promise of holding a stranger's message is that
      // they learn nothing — not that it was delivered, not that it was
      // opened, and not that it was refused.
      if (plan.ignoreSender) {
        final peer = _peerOf(room);
        if (peer != null) {
          await _client.ignoreUser(peer).catchError((Object error) {
            debugPrint('weft: could not ignore $peer: $error');
          });
        }
      }
      if (plan.join) {
        await room.join();
      }
      if (plan.leave) {
        await room.leave();
      }
    }

    _rebuild();
    return next;
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

  @override
  Future<void> forgetLocally(String roomId, String eventId) async {
    // The SDK's own store, not Sennit's: this is the copy the timeline is read
    // from, and the one a re-open would otherwise redraw the message out of.
    // Sennit's record of the message — the search index — is dropped by the
    // sweeper, which is also what writes the tombstone that keeps a backfill
    // from bringing it back.
    await _client.database.removeEvent(eventId, roomId);
    _invalidateTimelines();
    _scheduleRebuild();
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

      // A thumbnail request for an event that has no thumbnail falls back, in
      // the SDK, to the attachment itself. Whether that is a preview or a
      // waste of megabytes depends on what the file is — see
      // [attachmentServesAsThumbnail], which knows about stickers as well as
      // about films. Nothing is the better answer when it is not: the caller
      // draws a poster instead.
      if (thumbnail &&
          !event.hasThumbnail &&
          !attachmentServesAsThumbnail(
            messageType: event.messageType,
            mimetype: event.attachmentMimetype,
          )) {
        return null;
      }

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
    String? caption,
  }) async {
    final target = _sendSource(chatId, via: via);
    // Refused rather than silently rerouted to another leg. Sending an MMS
    // means encoding a PDU, which Android does not expose — the same gap that
    // stops incoming MMS being retrieved — and a photo that quietly went out
    // over WhatsApp instead is worse than one that did not go.
    if (target.network == ChatNetwork.sms) {
      throw StateError('Sennit cannot send MMS attachments yet');
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
      caption: caption,
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
    _onUploads?.call(tasks);
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
    // One query per room rather than one per message: a merged chat's legs are
    // few and its messages are not.
    final retention = _retention;
    final purged = <String, Set<String>>{};
    Set<String> purgedIn(String roomId) => purged.putIfAbsent(
      roomId,
      () => retention?.purgedIn(roomId) ?? const {},
    );

    store.indexMessages(
      // Emptiness is asked of the projection, not of the raw body: a message
      // whose whole body was a dropped subtree says nothing to a reader and
      // would otherwise be indexed as a blank row.
      //
      // A purged message is filtered here as well as in the timeline mapper,
      // and the belt is worth the braces: the mapper's tombstone set is a
      // snapshot taken when the timeline opened, so a message swept *while*
      // the chat is on screen is still in the list this method was handed.
      // Re-filing it would put a deleted message back into the one place the
      // user would find it again.
      messages.where(
        (m) =>
            !m.redacted &&
            plainTextOf(m).isNotEmpty &&
            !purgedIn(m.roomId).contains(m.eventId),
      ),
      chatId: chatId,
      chatTitle: title,
    );
  }

  @override
  Future<void> retryFailedSend(String roomId, String eventId) async {
    final event = await _client.getRoomById(roomId)?.getEventById(eventId);
    if (event == null) return;
    await event.sendAgain();
    _scheduleRebuild();
  }

  @override
  Future<void> discardFailedSend(String roomId, String eventId) async {
    final event = await _client.getRoomById(roomId)?.getEventById(eventId);
    if (event == null) return;
    await event.cancelSend();
    _scheduleRebuild();
  }

  @override
  Future<void> markUnread(String chatId) async {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return;
    for (final source in chat.sources) {
      if (source.network == ChatNetwork.sms) continue;
      final room = _client.getRoomById(source.roomId);
      if (room == null) continue;
      // The optimistic receipt would zero the badge right back out.
      _readUpTo.remove(room.id);
      try {
        await room.markUnread(true);
      } on Object catch (error) {
        debugPrint('weft: ${source.roomId} could not be marked unread: $error');
      }
    }
    _scheduleRebuild();
  }

  @override
  Future<void> markRead(String chatId) async {
    final chat = _chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return;

    // A request the user has not answered stays unread on the wire, however
    // long they look at it. Reading a stranger's message must tell the stranger
    // nothing — and the private receipt is not enough, because it is the
    // *public* one bridges relay as WhatsApp's blue ticks and `_readUpTo`
    // below is what a later `markRead` would flush. Skipping the whole method
    // is the only version of this that cannot leak by accident.
    //
    // The local badge is not lost by this: the request lives in its own section
    // with its own affordances, and clearing it is what accepting does.
    //
    // Asked of the rooms as they are now, not only of [chat]: that is the
    // inbox as of the last rebuild, and rebuilds are scheduled, not immediate.
    // Someone who answers a request and keeps reading is, for the second or
    // so until the next one, still looking at a row that says "pending" — and
    // the receipt for a conversation they have just spoken in went unsent.
    if (chat.isPendingRequest &&
        chat.sources.every((source) {
          final room = _client.getRoomById(source.roomId);
          return room == null ||
              _requestStateOf(room) == ChatRequestState.pending;
        })) {
      return;
    }

    // What a read-anchored retention policy counts from. Recorded per *chat*
    // and not per leg, because that is the granularity the user reads at: they
    // opened the conversation, and every message already in it has now been
    // seen whichever network carried it.
    //
    // `now` on both sides rather than the newest event's own timestamp: a
    // bridge that stamps an event with the remote network's clock can put it
    // slightly in the future, and a watermark taken from that would mark
    // messages read before they arrive. Reading the conversation is what
    // happened, and it happened now.
    final readAt = clock.now().toUtc();
    _retention?.recordRead(chatId: chatId, at: readAt, upTo: readAt);

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
      // Opening is the one thing that clears a deliberate unread flag.
      if (room.markedUnread) {
        try {
          await room.markUnread(false);
        } on Object catch (error) {
          debugPrint('weft: unread flag stuck on ${room.id}: $error');
        }
      }
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
    _profileLane.close();
    _rebuildDebounce?.cancel();
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
    _applyAutoMerges();
    _mergedContactIds = null;

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
    // Neither the room nor the server has said yet — which, with lazy-loaded
    // members, is every conversation at the start of every run. What the last
    // run learned is still true far more often than not, and using it is what
    // keeps a relaunch from re-asking for, and re-titling, the whole inbox.
    return _remembered(room, peerId).displayName;
  }

  /// The peer's name and picture as the identity store last had them, or
  /// nothing once this run knows better.
  ///
  /// "Knows better" is a fetched profile or a loaded member event, including
  /// one that says the person has no picture: a remembered avatar must not
  /// outlive the contact taking theirs down.
  ({String? displayName, String? avatarUrl}) _remembered(
    sdk.Room room,
    String peerId,
  ) {
    if (_profiles.containsKey(peerId) ||
        room.getState(sdk.EventTypes.RoomMember, peerId) != null) {
      return (displayName: null, avatarUrl: null);
    }
    return rememberedProfile(
      _graph.handleFor(peerId),
      fallbackName: room
          .unsafeGetUserFromMemoryOrFallback(peerId)
          .calcDisplayname(),
    );
  }

  /// Rebuilds handles from direct chats so the scorer can suggest merges.
  ///
  /// Only DMs participate: merging two group rooms is not a "same person"
  /// question, so groups are always left alone. A DM is what [_peerOf] says it
  /// is — bridge portals usually never enter `m.direct`, and skipping them
  /// here is why a WhatsApp chat and an SMS thread with the same person on
  /// them could not be offered as a merge at all.
  /// Set by the handle refresh whenever any handle actually changed; the
  /// scorer only runs then. It walks every pair with a string-similarity
  /// metric — running that on each of the initial sync storm's rebuilds was
  /// most of a thirty-second stutter after launch.
  ///
  /// True to begin with, so the first rebuild of a run always evaluates the
  /// auto-merge once. Before the fingerprints were seeded that was implicit —
  /// every handle looked new at launch — and losing it would mean an
  /// auto-merge the user *switched on while the app was closed* never ran:
  /// the setting had changed, but no handle had, so nothing was dirty and the
  /// fold waited for an unrelated rename.
  bool _handlesDirty = true;

  /// Runs the narrow auto-merge after a handle refresh and persists what it
  /// did, so the fold survives a restart exactly like a tapped merge — and
  /// an unmerge stays sticky, because the graph records the user's verdict
  /// and [IdentityGraph.suggestions] never re-offers a ruled pair.
  void _applyAutoMerges() {
    if (!_handlesDirty) return;
    _handlesDirty = false;
    final applied = _graph.applyAutoMerges();
    if (applied.isEmpty) return;
    for (final candidate in applied) {
      debugPrint(
        'weft: auto-merged ${candidate.a.displayName} '
        '(${candidate.a.network.id} + ${candidate.b.network.id})',
      );
    }
    _invalidateTimelines();
    _persistGraph();
  }

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
            _thumbnail(_profiles[peerId]?.avatarUrl?.toString()) ??
            // Kept rather than blanked while nobody has answered: writing
            // null over a stored picture here made every handle look changed
            // on the first rebuild of a run, and changed again when its
            // profile landed — two SQLite writes and two merge passes per
            // contact, per launch, for a row that ended where it began.
            _remembered(room, peerId).avatarUrl,
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
      if (_persistHandle(handle)) _handlesDirty = true;
    }

    // SMS contributes handles in exactly the same shape, which is the whole
    // reason no merge code changed for this network: `MergeScorer` normalises
    // `phoneE164` on both sides and raises `phoneExact` at 0.95, so an SMS
    // thread and a WhatsApp chat for one number become a suggestion in the
    // existing merge screen, with the existing "Same phone number" evidence.
    for (final handle in _sms?.handles ?? const <NetworkHandle>[]) {
      _graph.upsertHandle(handle);
      // Through the same guard as the rooms above, which it was not before: an
      // SMS thread is rewritten on every rebuild, and the rebuilds come every
      // 300ms once the inbox is live.
      _persistHandle(handle);
    }
  }

  /// The handle as [IdentityStore.upsertHandle] would store it — which is the
  /// handle plus whichever contact the graph currently puts it in.
  NetworkHandle _asPersisted(NetworkHandle handle) =>
      handle.copyWith(unifiedContactId: _graph.contactIdOf(handle.id));

  /// Writes [handle] to the identity store unless the row already says exactly
  /// this, and reports whether it wrote.
  bool _persistHandle(NetworkHandle handle) {
    final persisted = _asPersisted(handle);
    final fingerprint = handleFingerprint(persisted);
    if (_handleFingerprints[handle.id] == fingerprint) return false;
    _handleFingerprints[handle.id] = fingerprint;
    _store?.upsertHandle(persisted);
    return true;
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
  /// Cached per room: the peer of a DM never changes, and this walks the
  /// member summary and participants — six times per room per rebuild before
  /// the cache, all of it on the UI thread during the initial sync storm.
  final Map<String, String?> _peerCache = {};

  String? _peerOf(sdk.Room room) {
    if (_peerCache.containsKey(room.id)) return _peerCache[room.id];
    return _peerCache[room.id] = _computePeerOf(room);
  }

  String? _computePeerOf(sdk.Room room) {
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

  /// Compiled once: this runs for every conversation on every rebuild.
  static final RegExp _networkTag = RegExp(
    r'\s*\((WA|WhatsApp|Signal|Telegram|TG|SMS|FB|'
    r'Messenger|IG|Instagram|Discord|Slack|GChat|iMessage|LinkedIn|'
    r'Meta|X|Twitter|MM|Mattermost)\)\s*$',
  );

  /// A network-decorated ghost name, undecorated.
  ///
  /// Bridge display-name templates append the network — "Anna (WA)",
  /// "Anna (Signal)" — which is redundant in a UI that already labels every
  /// chat with its network glyph, and noise in a merged conversation.
  static String _stripNetworkTag(String name) {
    final stripped = name.replaceFirst(_networkTag, '').trim();
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

    // A picture the last run already resolved is drawn as it is, and nothing
    // is asked: the member event arrives with the next sync that touches it
    // and replaces this the ordinary way.
    final remembered = _remembered(room, peerId).avatarUrl;
    if (remembered != null) return remembered;

    _ensureProfile(peerId, room: room);
    return null;
  }

  /// The inbox preview, re-mapped only when the room's last event moves —
  /// mapping every room's tail on every rebuild was pure repeat work.
  final Map<String, (String, WeftMessage?)> _previewCache = {};

  WeftMessage? _previewFor(
    sdk.Room room,
    sdk.Event lastEvent,
    ChatNetwork network,
  ) {
    final cached = _previewCache[room.id];
    if (cached != null && cached.$1 == lastEvent.eventId) return cached.$2;
    final mapped = mapEvent(
      lastEvent,
      network: network,
      ownUserId: _client.userID,
    );
    _previewCache[room.id] = (lastEvent.eventId, mapped);
    return mapped;
  }

  /// How many messages are waiting in [room].
  ///
  /// Lifted out so a room's own leg and the chat built from it cannot disagree
  /// — the rail reads the first and the inbox row the second.
  int _unreadCountFor(sdk.Room room, sdk.Event? lastEvent) => roomUnreadCount(
    markedUnread: room.markedUnread,
    notificationCount: room.notificationCount,
    readLocally: _isReadLocally(room, lastEvent),
  );

  /// Whether the user has read [room] up to (at least) [lastEvent].
  ///
  /// Four witnesses, any of which settles it: the newest event being one the
  /// user sent, the receipt this session just wrote, the stored own receipt
  /// naming the event itself, or a stored own receipt *younger* than the event
  /// — receipts sometimes point at trailing reactions and edits rather than
  /// the message the preview shows.
  ///
  /// Sending is the first witness because it needs no receipt at all. Writing
  /// a message moves `lastEvent` past every receipt the room holds, so a chat
  /// the user had just caught up on went unread again the moment they replied
  /// — and then reported whatever `notificationCount` still held as the count
  /// of messages they had not seen, which was their own.
  bool _isReadLocally(sdk.Room room, sdk.Event? lastEvent) {
    if (lastEvent == null) return true;
    final own = room.receiptState.global.latestOwnReceipt;
    return isReadLocally(
      lastEventId: lastEvent.eventId,
      lastEventSenderId: lastEvent.senderId,
      lastEventTs: lastEvent.originServerTs.millisecondsSinceEpoch,
      ownUserId: _client.userID,
      readUpToEventId: _readUpTo[room.id],
      receiptEventId: own?.eventId,
      receiptTs: own?.ts,
    );
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
          // The same number the chat carries, on the leg it came from. A
          // one-legged chat is the trivial case; a merged one is folded from
          // these, and the rail needs to know which leg is waiting.
          unread: _unreadCountFor(room, lastEvent),
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
          : _previewFor(room, lastEvent, network),
      // The marked-unread flag keeps at least a badge of one; otherwise a
      // conversation the user has read is read — this session's optimistic
      // receipt, or the *persisted* one the SDK synced back, both beat the
      // server's cached count, which goes stale the moment the app is killed
      // before the next sync and resurrected every chat as unread.
      unreadCount: _unreadCountFor(room, lastEvent),
      // A resolved peer means "conversation with a person", whatever the
      // member count says: a bridged DM carries the bot as a third member and
      // is usually missing from m.direct, and calling it a group is what put
      // group styling on half the inbox.
      isGroup: _peerOf(room) == null,
      pinned: room.isFavourite,
      archived: room.membership == sdk.Membership.leave,
      muted: room.pushRuleState != sdk.PushRuleState.notify,
      request: _requestStateOf(room),
      participantCount: _peerCountOf(room),
      preferredSendNetwork: _sendNetworks[room.id],
    );
  }

  /// How many people are in [room] besides the user, or null when the server
  /// has not said.
  ///
  /// The bridge bot is subtracted where there is one: it is a member of every
  /// bridged room, it will never send a read receipt, and counting it would make
  /// the blue ticks structurally unreachable on every bridged conversation.
  ///
  /// Null rather than a guess for a summary that has not arrived — which is
  /// ordinary during first sync — because the group read rule reads this as
  /// "everyone", and a wrong number there is a blue tick on a message half the
  /// room has not opened. Zero is returned as null for the same reason: a room
  /// the user is apparently alone in is a room whose membership is not known
  /// yet, not one where everybody has read everything.
  int? _peerCountOf(sdk.Room room) {
    final joined = room.summary.mJoinedMemberCount;
    if (joined == null) return null;
    final peers = joined - 1 - (_bridgeBotOf(room) == null ? 0 : 1);
    return peers > 0 ? peers : null;
  }

  /// Whether this room is a chat request, and what the user has said about it.
  ///
  /// An answered request is *not* remembered here. Accepting one leaves an
  /// ordinary joined room and declining leaves the room outright, so the
  /// membership the next sync reports is already the answer — a second record
  /// of it would only be something to keep in step, and would resurrect a
  /// declined request if it ever fell out of step.
  ///
  /// A room the user is still deciding about is held in [_answeredRequests] for
  /// the seconds between the tap and the membership change arriving. Without it
  /// the row springs back into the requests section on the next sync tick,
  /// which reads as the button not having worked.
  ChatRequestState? _requestStateOf(sdk.Room room) {
    final answered = _answeredRequests[room.id];
    if (answered != null) return answered;
    if (room.membership == sdk.Membership.leave) return null;

    final peer = _peerOf(room);
    return isChatRequest(
          invited: room.membership == sdk.Membership.invite,
          everSentByUser: _hasOwnMessage(room),
          // A merged contact is a contact: the user has recorded that this
          // handle is someone they know, which is a stronger statement than
          // having replied to them.
          knownContact: peer != null && _isKnownContact(peer),
          isGroup: peer == null,
        )
        ? ChatRequestState.pending
        : null;
  }

  /// Whether the local user has ever spoken in [room], as far as this client
  /// can see.
  ///
  /// Deliberately cheap and deliberately one-sided. The honest question is
  /// "have they ever replied here", and answering it properly would mean
  /// paginating every room in the account on every rebuild. What is available
  /// for nothing is the room's own read/send state: `lastEvent` being the
  /// user's, and the fact that Sennit records where the user has read up to.
  ///
  /// It errs towards **not** a request. A conversation wrongly held out of the
  /// inbox is a message the user never sees; a conversation wrongly left in it
  /// is the behaviour they have today.
  bool _hasOwnMessage(sdk.Room room) {
    final ownId = _client.userID;
    if (ownId == null) return true;
    if (room.lastEvent?.senderId == ownId) return true;
    // A read marker the user's own client wrote is a room they have opened and
    // read, which is not a request whatever else is true.
    if (_readUpTo.containsKey(room.id)) return true;
    return room.receiptState.global.latestOwnReceipt != null;
  }

  /// Whether [userId] is somebody the user has recorded knowing.
  ///
  /// A handle existing is not enough — the graph builds one from every direct
  /// chat, so every stranger has one the moment their room appears. What counts
  /// is a *merge*: the user looking at two handles and saying they are the same
  /// person is a deliberate act, and the only durable record in Sennit that they
  /// know who this is.
  ///
  /// A phone number in the address book counts too, via the contact-name
  /// overrides the user opted into — the same source the inbox already titles
  /// rows from.
  bool _isKnownContact(String userId) {
    final handle = _graph.handleFor(userId);
    if (handle == null) return false;

    final contactId = _graph.contactIdOf(handle.id);
    if (contactId != null &&
        (_mergedContactIds ??= _graph.mergedContactIds()).contains(contactId)) {
      return true;
    }
    final digits = handle.phoneE164?.replaceAll(RegExp(r'\D'), '');
    return digits != null && _contactNames.containsKey(digits);
  }

  /// Which contacts hold more than one handle, as of the current rebuild.
  ///
  /// [_isKnownContact] is asked once per conversation per rebuild, and asking
  /// the graph for a contact's handles walks every handle there is — so the
  /// question cost the square of the inbox, on the UI thread, on every sync.
  /// One pass answers it for all of them; [_rebuild] drops it.
  Set<String>? _mergedContactIds;

  /// Requests answered this session, held until the membership change lands.
  final Map<String, ChatRequestState> _answeredRequests = {};

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

/// Everything [IdentityStore.upsertHandle] would put in the row, as one string.
///
/// The point of it is the skip: two handles with the same fingerprint write the
/// same row, so the second write can be dropped. That only holds while this
/// covers **every** persisted column — a field left out is a field that can
/// change without anybody writing it, and the row then disagrees with the app
/// until something unrelated about the handle moves. `roomId` is the one that
/// makes this concrete: it was outside the older, four-field fingerprint and
/// got away with it only because the map was empty at launch and every row was
/// rewritten anyway. Seeding the map takes that cover away.
///
/// `unifiedContactId` is read off the handle rather than the graph, so callers
/// pass the handle **as it will be stored** — see `_asPersisted`.
///
/// Encoded rather than joined with a separator, because the values are display
/// names and URLs the app does not choose: any character picked as a separator
/// is one somebody can put in their name, and a name holding it reads as the
/// two fields either side of it. JSON also keeps an absent field apart from the
/// four-letter name of it — `null` and `"null"` are different rows.
String handleFingerprint(NetworkHandle handle) => jsonEncode([
  handle.network.id,
  handle.remoteId,
  handle.matrixUserId,
  handle.roomId,
  handle.displayName,
  handle.avatarUrl,
  handle.phoneE164,
  handle.email,
  handle.avatarDHash,
  handle.unifiedContactId,
]);

/// A room's badge, from the three facts that decide it.
///
/// Lifted out for the same reason [isReadLocally] was — it is reachable only
/// through a live sync otherwise — and for one more: the order of these two
/// clauses is the whole of the auto-reply unread guarantee.
///
/// [markedUnread] is checked **first**, and that is what survives a send.
/// Writing a message moves the room's newest event past every receipt it holds,
/// so [readLocally] becomes true the moment anything is sent from this account
/// — right for a message the user typed, wrong for one their model sent on
/// their behalf. The MSC2867 flag sits above that clause, which is why
/// re-asserting it after an auto-reply keeps the conversation waiting. It is
/// also room *account data*, so it syncs: the badge stays on the laptop too.
///
/// The `> 0 ? … : 1` is not padding. A room flagged unread whose server-side
/// notification count is zero — every conversation the user marked unread by
/// hand — still has to show something, and one is the honest number when the
/// only thing known is "not finished with this".
int roomUnreadCount({
  required bool markedUnread,
  required int notificationCount,
  required bool readLocally,
}) {
  if (markedUnread) return notificationCount > 0 ? notificationCount : 1;
  return readLocally ? 0 : notificationCount;
}

/// Whether a room's newest event has already been read, from facts alone.
///
/// Lifted out of the repository so it can be tested without a homeserver: the
/// rule is four small clauses and every one of them was reachable only through
/// a live sync before, which is how the send-makes-it-unread case survived.
///
/// [readUpToEventId] is the receipt this session wrote and has not seen come
/// back down sync yet; [receiptEventId] and [receiptTs] are the newest own
/// receipt the room does hold. A null receipt means "no idea", which is not
/// the same as "never read" — but the caller has nothing better to go on, so
/// it counts as unread.
bool isReadLocally({
  required String lastEventId,
  required String lastEventSenderId,
  required int lastEventTs,
  required String? ownUserId,
  required String? readUpToEventId,
  required String? receiptEventId,
  required int? receiptTs,
}) {
  if (ownUserId != null && lastEventSenderId == ownUserId) return true;
  if (readUpToEventId == lastEventId) return true;
  if (receiptEventId == null || receiptTs == null) return false;
  if (receiptEventId == lastEventId) return true;
  return receiptTs >= lastEventTs;
}
