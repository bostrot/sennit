import 'dart:async';
import 'dart:convert';

import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_remote/weft_remote.dart';

import '../../data/chat_repository.dart';
import 'remote_protocol.dart';

/// The phone's side of Sennit Web: serves one browser from the real
/// [ChatRepository], which keeps the Matrix session and every key.
///
/// The browser reads most of the repository synchronously — the inbox, the
/// identity graph, who is typing, what is loaded of a timeline — so the host
/// pushes a snapshot of those after every change, and only the parts that
/// changed since the last push. Everything that does something is a call.
class RemoteChatHost {
  RemoteChatHost(
    this._repo,
    RemoteLink link, {
    Map<String, RpcHandler> extraHandlers = const {},
    Map<String, String> Function()? settings,
  }) : _settings = settings {
    _peer = RpcPeer(link, handlers: {..._handlers(), ...extraHandlers});
    _chats = _repo.watchChats().listen((chats) {
      _lastChats = chats;
      _schedulePush();
    });
    unawaited(_peer.done.then((_) => dispose()));
  }

  final ChatRepository _repo;
  final Map<String, String> Function()? _settings;
  final Map<String, String> _sentSettings = {};
  late final RpcPeer _peer;
  late final StreamSubscription<List<Chat>> _chats;

  final Map<String, String> _sentChats = {};
  List<String> _sentOrder = const [];
  String? _sentNetworks;
  String? _sentService;
  String? _sentIdentity;
  int? _sentEpoch;
  final Map<int, _OpenTimeline> _timelines = {};
  int _nextTimeline = 1;
  bool _pushScheduled = false;
  bool _disposed = false;

  Future<void> get done => _peer.done;

  /// Pushes whatever changed outside the chat stream — a setting, a pairing.
  void refresh() => _schedulePush();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_chats.cancel());
    unawaited(_peer.close());
  }

  /// Folds a burst of repository updates into one frame.
  void _schedulePush() {
    if (_pushScheduled || _disposed || !_ready) return;
    _pushScheduled = true;
    scheduleMicrotask(() {
      _pushScheduled = false;
      _push();
    });
  }

  List<Chat> _lastChats = const [];

  /// Nothing is pushed before the browser said hello: until then it has no
  /// mirror to apply a diff to.
  bool _ready = false;

  void _push() {
    if (_disposed) return;
    final frame = <String, Object?>{};

    final chats = _lastChats;
    final order = [for (final c in chats) c.id];
    final changed = <String, Object?>{};
    for (final chat in chats) {
      final json = jsonEncode(DomainCodec.chat(chat));
      if (_sentChats[chat.id] != json) {
        _sentChats[chat.id] = json;
        changed[chat.id] = jsonDecode(json);
      }
    }
    _sentChats.removeWhere((id, _) => !order.contains(id));
    if (changed.isNotEmpty || !_sameList(order, _sentOrder)) {
      frame['chats'] = {'order': order, 'set': changed};
      _sentOrder = order;
    }

    final networks = jsonEncode([
      for (final n in _repo.availableNetworks) n.id,
    ]);
    if (networks != _sentNetworks) {
      frame['networks'] = jsonDecode(networks);
      _sentNetworks = networks;
    }
    final service = jsonEncode(_repo.serviceChatIds.toList()..sort());
    if (service != _sentService) {
      frame['service'] = jsonDecode(service);
      _sentService = service;
    }
    final epoch = _repo.timelineEpoch;
    if (epoch != _sentEpoch) {
      frame['epoch'] = epoch;
      _sentEpoch = epoch;
    }
    final identity = jsonEncode(_identity(_repo.identityGraph));
    if (identity != _sentIdentity) {
      frame['identity'] = jsonDecode(identity);
      _sentIdentity = identity;
    }

    // Live state for the conversations the browser has open — small, and it
    // moves on nearly every sync, so it is sent whole rather than diffed.
    final live = <String, Object?>{};
    for (final t in _timelines.values) {
      live[t.chatId] = _live(t.chatId);
    }
    if (live.isNotEmpty) frame['live'] = live;

    final timelines = <String, Object?>{};
    for (final MapEntry(:key, :value) in _timelines.entries) {
      final json = value.encode();
      if (json != value.sent) {
        value.sent = json;
        timelines['$key'] = jsonDecode(json);
      }
    }
    if (timelines.isNotEmpty) frame['timelines'] = timelines;

    // The phone's preferences, so the browser behaves the way the phone was
    // set up — which network sends, what Return does, how statuses show.
    if (_settings case final read?) {
      final now = read();
      final changed = <String, Object?>{
        for (final MapEntry(:key, :value) in now.entries)
          if (_sentSettings[key] != value) key: value,
        for (final key in _sentSettings.keys)
          if (!now.containsKey(key)) key: null,
      };
      if (changed.isNotEmpty) {
        frame['settings'] = changed;
        _sentSettings
          ..clear()
          ..addAll(now);
      }
    }

    if (frame.isNotEmpty) _peer.emit(RemoteMethods.stateEvent, frame);
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, Object?> _identity(IdentityGraph graph) => {
    'handles': [
      for (final h in graph.handles)
        DomainCodec.handle(
          h.copyWith(unifiedContactId: graph.contactIdOf(h.id)),
        ),
    ],
    'decisions': [for (final d in graph.decisions) decisionToJson(d)],
  };

  Map<String, Object?> _live(String chatId) {
    final presence = _repo.presenceFor(chatId);
    return {
      'typing': _repo.typingIn(chatId),
      if (presence != null)
        'presence': {
          'online': presence.online,
          'at': ?presence.lastActiveAt?.millisecondsSinceEpoch,
        },
      'peer': [
        for (final r in _repo.peerReadUpTo(chatId))
          {
            'room': r.roomId,
            'user': r.userId,
            'event': r.eventId,
            'at': r.at.millisecondsSinceEpoch,
          },
      ],
      'own': [
        for (final r in _repo.ownReadUpTo(chatId))
          {
            'room': r.roomId,
            'event': r.eventId,
            'at': r.at.millisecondsSinceEpoch,
          },
      ],
    };
  }

  // ---------------------------------------------------------------- calls

  Map<String, RpcHandler> _handlers() {
    String s(Map<String, Object?> p, String k) => p[k]! as String;
    String? os(Map<String, Object?> p, String k) => p[k] as String?;
    ChatNetwork? via(Map<String, Object?> p) =>
        p['via'] is String ? ChatNetwork.fromId(p['via']! as String) : null;
    DateTime? time(Map<String, Object?> p, String k) => p[k] is int
        ? DateTime.fromMillisecondsSinceEpoch(p[k]! as int, isUtc: true)
        : null;
    RpcHandler act(Future<void> Function(Map<String, Object?> p) f) =>
        (p) => _guard(() async {
          await f(p);
          return null;
        });

    return {
      RemoteMethods.hello: (_) async {
        _ready = true;
        // A browser reconnecting starts from nothing; so does this.
        _sentChats.clear();
        _sentOrder = const [];
        _sentNetworks = _sentService = _sentIdentity = null;
        _sentEpoch = null;
        _sentSettings.clear();
        _schedulePush();
        return {'protocol': kRemoteProtocolVersion};
      },
      RemoteMethods.timelineOpen: (p) => _guard(() async {
        final chatId = s(p, 'chat');
        final timeline = await _repo.timelineFor(chatId);
        final id = _nextTimeline++;
        final open = _OpenTimeline(chatId, timeline);
        _timelines[id] = open;
        open.sent = open.encode();
        return {'id': id, 'timeline': jsonDecode(open.sent!)};
      }),
      RemoteMethods.timelineMore: (p) => _guard(() async {
        final open = _timelines[p['id']];
        if (open == null) throw ArgumentError('timeline closed');
        final room = s(p, 'room');
        final source = open.timeline.sources.firstWhere(
          (src) => src.roomId == room,
        );
        final added = await source.loadMore(count: (p['count'] as int?) ?? 30);
        open.sent = open.encode();
        return {'added': added, 'timeline': jsonDecode(open.sent!)};
      }),
      RemoteMethods.timelineClose: (p) async {
        _timelines.remove(p['id']);
        return null;
      },
      RemoteMethods.attachmentBytes: (p) => _guard(() async {
        final bytes = await _repo.attachmentBytes(
          s(p, 'room'),
          s(p, 'event'),
          thumbnail: p['thumb'] != false,
        );
        return bytes == null ? null : base64.encode(bytes);
      }),
      RemoteMethods.send: act(
        (p) => _repo.send(s(p, 'chat'), s(p, 'body'), via: via(p)),
      ),
      RemoteMethods.sendReply: act(
        (p) => _repo.sendReply(
          s(p, 'chat'),
          s(p, 'body'),
          replyToEventId: s(p, 'replyTo'),
          via: via(p),
        ),
      ),
      RemoteMethods.sendThreadReply: act(
        (p) => _repo.sendThreadReply(
          s(p, 'chat'),
          s(p, 'body'),
          threadRootId: s(p, 'root'),
          replyToEventId: os(p, 'replyTo'),
          threadLatestEventId: os(p, 'latest'),
        ),
      ),
      RemoteMethods.sendLocation: act(
        (p) => _repo.sendLocation(
          s(p, 'chat'),
          latitude: (p['lat']! as num).toDouble(),
          longitude: (p['lon']! as num).toDouble(),
          via: via(p),
        ),
      ),
      RemoteMethods.sendCalendarInvite: act(
        (p) => _repo.sendCalendarInvite(
          s(p, 'chat'),
          title: s(p, 'title'),
          start: time(p, 'start')!,
          end: time(p, 'end'),
          via: via(p),
        ),
      ),
      RemoteMethods.editCalendarInvite: act(
        (p) => _repo.editCalendarInvite(
          s(p, 'room'),
          s(p, 'event'),
          title: s(p, 'title'),
          start: time(p, 'start')!,
          end: time(p, 'end'),
        ),
      ),
      RemoteMethods.respondCalendarInvite: act(
        (p) => _repo.respondCalendarInvite(
          s(p, 'room'),
          s(p, 'event'),
          reply: CalendarReply.values.byName(s(p, 'reply')),
          proposedStart: time(p, 'proposed'),
        ),
      ),
      RemoteMethods.createPoll: act(
        (p) => _repo.createPoll(
          s(p, 'chat'),
          question: s(p, 'question'),
          options: [for (final o in p['options']! as List) o as String],
          via: via(p),
        ),
      ),
      RemoteMethods.votePoll: act(
        (p) => _repo.votePoll(s(p, 'room'), s(p, 'event'), {
          for (final a in p['answers']! as List) a as String,
        }),
      ),
      RemoteMethods.react: act(
        (p) => _repo.react(s(p, 'chat'), s(p, 'event'), s(p, 'key')),
      ),
      RemoteMethods.unreact: act(
        (p) => _repo.unreact(s(p, 'chat'), s(p, 'event')),
      ),
      RemoteMethods.editMessage: act(
        (p) => _repo.editMessage(s(p, 'chat'), s(p, 'event'), s(p, 'body')),
      ),
      RemoteMethods.redact: act(
        (p) => _repo.redact(s(p, 'chat'), s(p, 'event')),
      ),
      RemoteMethods.setSendNetwork: act(
        (p) => _repo.setSendNetwork(
          s(p, 'chat'),
          ChatNetwork.fromId(s(p, 'network')),
        ),
      ),
      RemoteMethods.markRead: act((p) => _repo.markRead(s(p, 'chat'))),
      RemoteMethods.markUnread: act((p) => _repo.markUnread(s(p, 'chat'))),
      RemoteMethods.retryFailedSend: act(
        (p) => _repo.retryFailedSend(s(p, 'room'), s(p, 'event')),
      ),
      RemoteMethods.discardFailedSend: act(
        (p) => _repo.discardFailedSend(s(p, 'room'), s(p, 'event')),
      ),
      RemoteMethods.forgetLocally: act(
        (p) => _repo.forgetLocally(s(p, 'room'), s(p, 'event')),
      ),
      RemoteMethods.setArchived: act(
        (p) => _repo.setArchived(s(p, 'chat'), archived: p['on'] == true),
      ),
      RemoteMethods.setMuted: act(
        (p) => _repo.setMuted(s(p, 'chat'), muted: p['on'] == true),
      ),
      RemoteMethods.deleteChat: act((p) => _repo.deleteChat(s(p, 'chat'))),
      RemoteMethods.setTyping: act(
        (p) => _repo.setTyping(s(p, 'chat'), typing: p['on'] == true),
      ),
      RemoteMethods.mergeHandles: act(
        (p) => _repo.mergeHandles(s(p, 'a'), s(p, 'b')),
      ),
      RemoteMethods.unmergeHandle: act(
        (p) => _repo.unmergeHandle(s(p, 'handle')),
      ),
      RemoteMethods.rejectSuggestion: act(
        (p) => _repo.rejectSuggestion(s(p, 'a'), s(p, 'b')),
      ),
      RemoteMethods.createDirectChat: (p) =>
          _guard(() => _repo.createDirectChat(s(p, 'user'))),
      RemoteMethods.createGroupChat: (p) => _guard(
        () => _repo.createGroupChat(s(p, 'name'), [
          for (final u in p['invite']! as List) u as String,
        ]),
      ),
      RemoteMethods.startBridgeChat: (p) => _guard(
        () => _repo.startBridgeChat(
          ChatNetwork.fromId(s(p, 'network')),
          s(p, 'identifier'),
        ),
      ),
      RemoteMethods.answerChatRequest: (p) => _guard(() async {
        final state = await _repo.answerChatRequest(
          s(p, 'chat'),
          ChatRequestAction.values.byName(s(p, 'action')),
        );
        return state?.name;
      }),
    };
  }

  /// Runs a call and turns the exceptions screens tell apart into codes.
  Future<Object?> _guard(Future<Object?> Function() f) async {
    try {
      final result = await f();
      _schedulePush();
      return result;
    } on ArgumentError catch (e) {
      throw RemoteException(RemoteErrors.notFound, '${e.message}');
    } on StateError catch (e) {
      throw RemoteException(RemoteErrors.state, e.message);
    }
  }
}

class _OpenTimeline {
  _OpenTimeline(this.chatId, this.timeline);

  final String chatId;
  final MergedTimeline timeline;
  String? sent;

  String encode() => jsonEncode({
    for (final source in timeline.sources)
      source.roomId: {
        'net': source.network.id,
        'offset': source.clockOffset.inMilliseconds,
        'more': source.hasMore,
        'loaded': [for (final m in source.loaded) messageJson(m)],
      },
  });
}
