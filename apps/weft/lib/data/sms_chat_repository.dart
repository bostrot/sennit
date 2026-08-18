import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_sms/weft_sms.dart';

import '../services/sms/sms_platform.dart';

/// Hands loaded SMS bodies to the search index.
///
/// The same signature as `ChatRepository.indexMessages`, so the composing
/// repository can pass its own method straight in — SMS text goes
/// through the one index every other network's text goes through, rather than
/// into a second one that a hybrid query would have to remember to ask.
typedef SmsMessageIndexer =
    void Function(
      String roomId,
      List<WeftMessage> messages, {
      String chatTitle,
    });

/// One SMS thread's history, as the merged timeline reads any other room's.
///
/// The system provider has no cursor API worth the name: a query takes a
/// `LIMIT` and gives back the newest N rows. So "load older" here is a re-read
/// with a bigger limit, and pagination between re-reads is served from what is
/// already in memory. That is cheap — a row is a few hundred bytes and never
/// leaves the device — and it keeps [TimelineSource]'s contract intact, which
/// is what lets an SMS leg interleave with a WhatsApp one under the watermark
/// rule instead of needing a second timeline implementation.
class SmsTimelineSource extends TimelineSource {
  SmsTimelineSource({
    required this.roomId,
    required Future<List<WeftMessage>> Function(int limit) fetch,
    required List<WeftMessage> initial,
    int fetchedWith = kSmsReadLimit,
    this.pageSize = 30,
  }) : _fetch = fetch,
       _fetchLimit = fetchedWith,
       _history = [...initial];

  @override
  final String roomId;

  @override
  ChatNetwork get network => ChatNetwork.sms;

  final Future<List<WeftMessage>> Function(int limit) _fetch;
  final int pageSize;

  /// Everything read so far, newest first.
  final List<WeftMessage> _history;

  /// The limit the current [_history] was read with. A read that came back
  /// exactly full is the signal that the provider is holding more.
  int _fetchLimit;

  final List<WeftMessage> _loaded = [];

  @override
  List<WeftMessage> get loaded => List.unmodifiable(_loaded);

  @override
  bool get hasMore => _loaded.length < _history.length || _mayHaveMore;

  bool get _mayHaveMore => _history.length >= _fetchLimit;

  @override
  Future<int> loadMore({int count = 30}) async {
    if (_loaded.length >= _history.length && _mayHaveMore) {
      // Everything read is on screen and the last read came back full: go back
      // to the provider for a deeper slice before giving up.
      _fetchLimit *= 2;
      final deeper = await _fetch(_fetchLimit);
      if (deeper.length > _history.length) {
        _history
          ..clear()
          ..addAll(deeper);
      } else {
        // The provider has no more to give, whatever the limit said. Pinning
        // the limit above what came back is what clears [hasMore] for good.
        _fetchLimit = _history.length + 1;
      }
    }

    final take = count < pageSize ? count : pageSize;
    final start = _loaded.length;
    final end = (start + take).clamp(0, _history.length);
    if (start >= end) return 0;
    _loaded.addAll(_history.sublist(start, end));
    return end - start;
  }

  /// Puts a just-arrived message at the head of the thread.
  ///
  /// Added to [_loaded] as well as to the history, not merely to the history:
  /// an unpaginated source would otherwise hold a message the view can never
  /// reach, and a received SMS would appear only after a scroll.
  void prepend(WeftMessage message) {
    if (_history.any((m) => m.eventId == message.eventId)) {
      replace(message);
      return;
    }
    _history.insert(0, message);
    _loaded.insert(0, message);
  }

  /// Swaps in a new version of a message already on screen.
  ///
  /// This is what a delivery report is: not a new bubble, an existing one whose
  /// tick changed. Returns whether anything matched, so a report for a message
  /// this source never loaded is a no-op rather than an appended duplicate.
  bool replace(WeftMessage message) {
    var found = false;
    for (final list in [_history, _loaded]) {
      final index = list.indexWhere((m) => m.eventId == message.eventId);
      if (index >= 0) {
        list[index] = message;
        found = true;
      }
    }
    return found;
  }
}

/// The system SMS provider as one more source in the merged inbox.
///
/// Not a `ChatRepository`. SMS answers a strict subset of what one promises —
/// there are no reactions, no edits, no redactions and no read receipts on a
/// GSM network — and implementing the interface would mean a dozen methods that
/// throw. It is instead composed into `MatrixChatRepository`, which owns the
/// inbox and routes the calls SMS can actually serve. That is what puts an SMS
/// thread in the same list as a bridged chat, and what lets the two be *merged*
/// rather than living in a tab of their own.
///
/// Everything that decides anything is in `weft_sms`, in pure Dart: what a
/// provider row means, what a number normalises to, and whether an SMS address
/// is the same person as a WhatsApp handle. This class holds state and moves it.
class SmsChatRepository {
  SmsChatRepository({
    required SmsGateway gateway,
    PhoneNumberParser parser = const PhoneNumberParser(),
  }) : _gateway = gateway,
       _parser = parser;

  final SmsGateway _gateway;
  final PhoneNumberParser _parser;

  /// Where loaded SMS bodies go to become searchable.
  ///
  /// Settable rather than constructor state because the indexer is the
  /// composing repository's own `indexMessages`, and that repository does not
  /// exist yet at the moment this one is built.
  SmsMessageIndexer? indexer;

  SmsPlatformStatus _status = SmsPlatformStatus.unsupported;

  /// Threads by synthetic room id, newest activity first.
  final Map<String, SmsThread> _threads = {};

  /// The inbox row's preview for each thread.
  ///
  /// Held apart from the thread because it has two sources: the provider's own
  /// `snippet` column for a thread nobody has opened, and the real newest
  /// [WeftMessage] once one has been loaded or has just arrived. The second is
  /// strictly better — it knows who sent it and what its delivery state is — so
  /// it wins wherever it exists.
  final Map<String, WeftMessage> _previews = {};

  final Map<String, SmsTimelineSource> _sources = {};

  final _updates = StreamController<void>.broadcast();

  StreamSubscription<SmsMessage>? _incomingSub;
  StreamSubscription<SmsMessage>? _statusSub;
  StreamSubscription<SmsMmsPush>? _pushSub;

  /// Fires whenever the inbox's SMS rows changed. The composing repository
  /// rebuilds on it, exactly as it rebuilds on a Matrix sync.
  Stream<void> get updates => _updates.stream;

  SmsPlatformStatus get status => _status;

  bool get isReady => _status.isReady;

  /// SMS threads as inbox rows, newest first.
  ///
  /// Single-source by construction. Folding one together with the WhatsApp chat
  /// for the same number is the merge engine's decision, reached from the
  /// evidence [handles] contributes — a chat that merged itself would bypass
  /// the confirmation the user is owed.
  List<Chat> get chats {
    final out = [
      for (final entry in _threads.entries)
        entry.value.toChat(
          lastMessage: _previews[entry.key],
          handleId: _handleIdFor(entry.value),
        ),
    ];
    out.sort((a, b) {
      final at = a.lastMessage?.timestamp;
      final bt = b.lastMessage?.timestamp;
      if (at == null || bt == null) return 0;
      return bt.compareTo(at);
    });
    return out;
  }

  /// Identity-graph evidence for every thread that is one person.
  ///
  /// Group threads are deliberately excluded, for the same reason
  /// `MatrixChatRepository` only builds handles from direct chats: merging two
  /// group conversations is not a "same person" question, and a group member's
  /// handle carrying the group's room id would fold that whole thread into
  /// somebody's DM the moment they were merged.
  List<NetworkHandle> get handles => [
    for (final thread in _threads.values)
      if (!thread.isGroup) ...linkSmsThreadIdentities(thread, parser: _parser),
  ];

  /// Reads the role, subscribes, and loads the inbox.
  ///
  /// Safe to call on a device with no telephony and on a phone where another
  /// app is the default: both settle on an empty [chats] and no subscriptions,
  /// which is the state Weft has to work perfectly in anyway.
  Future<void> start() async {
    _status = await _gateway.status();
    if (!_status.isReady) {
      _emit();
      return;
    }

    // Subscribed before the drain, not after: `drainPending` replays what
    // arrived before Dart was listening, and a listener attached afterwards
    // would miss exactly the messages the queue exists to save.
    _incomingSub = _gateway.incoming.listen(_onIncoming);
    _statusSub = _gateway.statusUpdates.listen(_onStatusUpdate);
    _pushSub = _gateway.mmsPushes.listen(_onMmsPush);

    await refresh();
    await _gateway.drainPending();
  }

  /// Shows the system's default-app dialog, then reloads if it was granted.
  ///
  /// A decline is an answer rather than an error: [chats] stays empty and every
  /// other network in the inbox is untouched.
  Future<bool> requestRole() async {
    final granted = await _gateway.requestRole();
    if (granted) await start();
    return granted;
  }

  /// Re-reads every thread from the provider.
  Future<void> refresh() async {
    if (!_status.isReady) return;
    final threads = await _gateway.threads();

    _threads.clear();
    for (final thread in threads) {
      _threads[thread.roomId] = thread;
      // A thread already carrying a real message keeps it: the snippet is a
      // truncated copy of the same text with no sender and no delivery state.
      final preview = _snippetPreview(thread);
      if (preview != null) _previews.putIfAbsent(thread.roomId, () => preview);
    }
    // Threads the provider no longer returns are gone from the inbox, and so
    // are their previews — otherwise a deleted thread's preview would resurrect
    // it the next time a message for that id arrived.
    _previews.removeWhere((roomId, _) => !_threads.containsKey(roomId));
    _emit();
  }

  bool owns(String roomId) => isSmsRoomId(roomId);

  /// The thread [roomId] names, or null when the provider has never shown it.
  SmsThread? threadFor(String roomId) => _threads[roomId];

  /// One thread's history, as a merged-timeline source.
  ///
  /// Null when SMS is not available at all, which is what sends the caller down
  /// its "this leg is unreachable" path rather than into an empty conversation.
  Future<TimelineSource?> openTimeline(String roomId) async {
    if (!isSmsRoomId(roomId)) return null;
    final existing = _sources[roomId];
    if (existing != null) return existing;
    if (!_status.isReady) return null;

    final threadId = _threadIdOf(roomId);
    final messages = await _read(threadId, kSmsReadLimit);

    final source = SmsTimelineSource(
      roomId: roomId,
      initial: messages,
      fetch: (limit) => _read(threadId, limit),
    );
    _sources[roomId] = source;

    if (messages.isNotEmpty) {
      _remember(messages.first);
      _index(roomId, messages);
      _emit();
    }
    return source;
  }

  /// Releases an open thread's source when the user navigates away.
  void closeTimeline(String roomId) => _sources.remove(roomId);

  /// Sends [body] to the thread [roomId] names.
  ///
  /// Throws rather than returning a failure, matching the Matrix send path: a
  /// message that could not leave the composer has to reach the composer.
  Future<void> send(String roomId, String body) async {
    final thread = _threads[roomId];
    if (thread == null) {
      throw StateError('SMS thread $roomId is no longer in the provider');
    }
    // One address, because `SmsManager.sendTextMessage` takes one. A group MMS
    // is a different wire format entirely, and quietly sending to the first
    // participant would look like a group reply and be a private message.
    if (thread.addresses.length > 1) {
      throw StateError('Weft cannot send to a group MMS thread yet');
    }
    final address = thread.addresses.firstOrNull;
    if (address == null || address.isEmpty) {
      throw StateError('SMS thread $roomId has no address to reply to');
    }

    final sent = await _gateway.send(address: address, body: body);
    if (sent == null) {
      throw StateError('The device would not accept that message');
    }
    _ingest(sent, incoming: false);
  }

  /// Marks every message in a thread read, in the provider itself.
  ///
  /// The provider, not a local flag: Weft holds the default-SMS role, so its
  /// idea of what has been read is the phone's — a notification the user
  /// dismissed here must not still be unread for the next app that looks.
  Future<void> markRead(String roomId) async {
    if (!_status.isReady) return;
    final thread = _threads[roomId];
    if (thread == null) return;

    await _gateway.markThreadRead(thread.id);
    if (thread.unreadCount == 0) return;
    _threads[roomId] = SmsThread(
      id: thread.id,
      addresses: thread.addresses,
      title: thread.title,
      snippet: thread.snippet,
      lastMessageAt: thread.lastMessageAt,
      archived: thread.archived,
    );
    _emit();
  }

  Future<void> dispose() async {
    await _incomingSub?.cancel();
    await _statusSub?.cancel();
    await _pushSub?.cancel();
    _sources.clear();
    await _updates.close();
  }

  // ----------------------------------------------------------------- internals

  void _onIncoming(SmsMessage message) => _ingest(message, incoming: true);

  /// A send outcome or a delivery report for a message already on screen.
  ///
  /// Handled apart from [_onIncoming] on purpose: one appends a bubble and the
  /// other changes one already drawn. Folding the two streams together
  /// duplicates every message the user sends.
  void _onStatusUpdate(SmsMessage message) {
    final roomId = smsRoomId(message.threadId);
    final updated = _toWeftMessage(message, roomId);

    final source = _sources[roomId];
    // An update for a thread nobody has open still matters — it is the inbox
    // row's tick — so the preview is refreshed either way.
    source?.replace(updated);
    if (_previews[roomId]?.eventId == updated.eventId) {
      _previews[roomId] = updated;
    }
    _emit();
  }

  void _onMmsPush(SmsMmsPush push) {
    // Weft cannot retrieve an MMS: Android exposes the transport but not the
    // PDU parser. Writing a placeholder row would put a message in the thread
    // that the rest of the phone would read as real, so this is logged and the
    // thread is re-read instead — the notification itself is in the provider,
    // and whatever the system did with it shows up there.
    debugPrint('weft: sms mms push (${push.sizeBytes} bytes), not retrievable');
    unawaited(refresh());
  }

  /// Files a message that has just appeared, creating its thread if need be.
  void _ingest(SmsMessage message, {required bool incoming}) {
    final roomId = smsRoomId(message.threadId);
    final weft = _toWeftMessage(message, roomId);

    final existing = _threads[roomId];
    _threads[roomId] = existing == null
        ? _threadFrom(message)
        : SmsThread(
            id: existing.id,
            addresses: existing.addresses.isEmpty
                ? [message.address]
                : existing.addresses,
            title: existing.title,
            snippet: message.body,
            unreadCount: incoming
                ? existing.unreadCount + 1
                : existing.unreadCount,
            lastMessageAt: message.timestamp,
            archived: existing.archived,
          );

    _sources[roomId]?.prepend(weft);
    _remember(weft);
    _index(roomId, [weft]);
    _emit();
  }

  /// A thread synthesised from a message that arrived before any read.
  ///
  /// An SMS can start the process, so the very first thing Weft learns about a
  /// conversation is sometimes a message in it. Dropping that until the next
  /// provider read would lose the one notification the user is waiting for.
  SmsThread _threadFrom(SmsMessage message) => SmsThread(
    id: message.threadId,
    addresses: message.address.isEmpty ? const [] : [message.address],
    snippet: message.body,
    unreadCount: message.isOutgoing ? 0 : 1,
    lastMessageAt: message.timestamp,
  );

  WeftMessage _toWeftMessage(SmsMessage message, String roomId) =>
      message.toWeftMessage(senderName: _nameFor(roomId, message));

  /// The best name available for a message's sender.
  ///
  /// The thread title when contacts resolved one and the thread is one person;
  /// the raw address otherwise, which is what every other SMS app shows and is
  /// still better than an empty label. Never a name for a *group* thread's
  /// member: the title there names the group, not whoever just spoke.
  String? _nameFor(String roomId, SmsMessage message) {
    if (message.isOutgoing) return null;
    final thread = _threads[roomId];
    if (thread == null || thread.isGroup) return null;
    final title = thread.title;
    return title == null || title.isEmpty ? null : title;
  }

  /// The inbox preview built from the provider's `snippet` column.
  ///
  /// Deliberately not `isOwn`: the column says what the last message was, not
  /// who wrote it, and claiming a received message was sent by the user paints
  /// it on the wrong side of the thread. Reading the thread replaces this with
  /// the real message, which does know.
  WeftMessage? _snippetPreview(SmsThread thread) {
    final at = thread.lastMessageAt;
    if (at == null) return null;
    return WeftMessage(
      // Not [smsEventId] of anything: this stands in for a row rather than
      // being one, and an id that could collide with a real message's would let
      // a delivery report land on a preview.
      eventId: 'sms:snippet:${thread.id}',
      roomId: thread.roomId,
      network: ChatNetwork.sms,
      senderId: thread.addresses.firstOrNull ?? '',
      senderName: thread.title ?? thread.addresses.join(', '),
      timestamp: at,
      kind: MessageKind.text,
      isOwn: false,
      body: thread.snippet ?? '',
    );
  }

  /// Promotes a real message to the thread's inbox preview when it is newer.
  void _remember(WeftMessage message) {
    final current = _previews[message.roomId];
    if (current == null || !current.timestamp.isAfter(message.timestamp)) {
      _previews[message.roomId] = message;
    }
  }

  void _index(String roomId, List<WeftMessage> messages) {
    final index = indexer;
    if (index == null || messages.isEmpty) return;
    index(roomId, messages, chatTitle: _threads[roomId]?.title ?? '');
  }

  Future<List<WeftMessage>> _read(String threadId, int limit) async {
    final roomId = smsRoomId(threadId);
    final rows = await _gateway.messages(threadId, limit: limit);
    final messages = [for (final row in rows) _toWeftMessage(row, roomId)];
    // Newest first, matching [TimelineSource]'s contract. The provider orders
    // by date descending already; sorting again costs nothing and means a
    // provider that does not is a wrong order rather than a corrupt timeline.
    messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return messages;
  }

  String? _handleIdFor(SmsThread thread) {
    if (thread.isGroup) return null;
    final address = thread.addresses.firstOrNull;
    if (address == null) return null;
    return linkSmsIdentity(address, parser: _parser)?.id;
  }

  String _threadIdOf(String roomId) =>
      roomId.substring(kSmsRoomIdPrefix.length);

  void _emit() {
    if (!_updates.isClosed) _updates.add(null);
  }
}
