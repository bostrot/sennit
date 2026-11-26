import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_remote/weft_remote.dart';

import '../services/remote/remote_protocol.dart';
import 'chat_repository.dart';
import 'send_queue_source.dart';

/// Sennit Web's data: the phone's [ChatRepository], seen through a link.
///
/// Holds a mirror of what the screens read synchronously, kept current by the
/// phone's pushed state (see `RemoteChatHost`), and forwards every action as a
/// call. Nothing here talks to Matrix: the session, its keys and the homeserver
/// stay on the phone, and the browser only ever sees what the phone shows.
class RemoteChatRepository implements ChatRepository, SendQueueSource {
  RemoteChatRepository(RemoteLink link) {
    _peer = RpcPeer(link, onEvent: _onEvent);
  }

  late final RpcPeer _peer;
  final _chatsController = StreamController<List<Chat>>.broadcast();
  final Map<String, Chat> _chatById = {};
  List<String> _order = const [];
  List<Chat> _chats = const [];
  List<ChatNetwork> _networks = const [];
  Set<String> _service = const {};
  int _epoch = 0;
  IdentityGraph _graph = IdentityGraph(handles: const []);
  final Map<String, Map<String, Object?>> _live = {};
  final Map<String, Future<MergedTimeline>> _timelineByChat = {};
  final Map<int, _RemoteTimeline> _timelines = {};
  final _firstState = Completer<void>();
  final _settingsController =
      StreamController<Map<String, String?>>.broadcast();
  Map<String, String?> _pendingSettings = {};
  Map<String, SendFailure> _failures = const {};
  final _failuresController =
      StreamController<Map<String, SendFailure>>.broadcast();

  /// The phone's preferences as they change; null removes. The first event
  /// after [connect] carries all of them.
  Stream<Map<String, String?>> get settingsChanges =>
      _settingsController.stream;

  /// Settings received before anyone listened — the first snapshot arrives
  /// with [connect], before the app has a listener.
  Map<String, String?> takePendingSettings() {
    final out = _pendingSettings;
    _pendingSettings = {};
    return out;
  }

  /// Completes when the link to the phone closes.
  Future<void> get done => _peer.done;

  /// Says hello and waits for the first snapshot, so the inbox draws whole.
  Future<void> connect() async {
    final hello = await _peer.call(RemoteMethods.hello);
    final version = (hello as Map?)?['protocol'];
    if (version != kRemoteProtocolVersion) {
      throw RemoteException('protocol', 'phone speaks $version');
    }
    await _firstState.future;
  }

  Future<void> dispose() async {
    await _peer.close();
    await _chatsController.close();
    await _settingsController.close();
    await _failuresController.close();
  }

  /// A picture the phone fetches with its homeserver credentials.
  Future<Uint8List?> fetchMedia(String url) async {
    final data = await _call(RemoteMethods.mediaFetch, {'url': url});
    return data is String ? base64.decode(data) : null;
  }

  void _onEvent(String name, Object? data) {
    if (name != RemoteMethods.stateEvent || data is! Map) return;
    final frame = data.cast<String, Object?>();

    if (frame['chats'] case final Map<Object?, Object?> chats) {
      final set = (chats['set'] as Map?)?.cast<String, Object?>() ?? const {};
      for (final MapEntry(:key, :value) in set.entries) {
        _chatById[key] = DomainCodec.chatFrom(
          (value! as Map).cast<String, Object?>(),
        );
      }
      _order = [for (final id in chats['order']! as List) id! as String];
      _chatById.removeWhere((id, _) => !_order.contains(id));
      _chats = [for (final id in _order) ?_chatById[id]];
    }
    if (frame['networks'] case final List<Object?> networks) {
      _networks = [for (final n in networks) ChatNetwork.fromId(n! as String)];
    }
    if (frame['service'] case final List<Object?> service) {
      _service = {for (final s in service) s! as String};
    }
    if (frame['epoch'] case final int epoch when epoch != _epoch) {
      _epoch = epoch;
      _timelineByChat.clear();
    }
    if (frame['failures'] case final Map<Object?, Object?> failures) {
      _failures = {
        for (final MapEntry(:key, :value) in failures.entries)
          key! as String: ?SendFailure.fromName(value as String?),
      };
      if (!_failuresController.isClosed) _failuresController.add(_failures);
    }
    if (frame['identity'] case final Map<Object?, Object?> identity) {
      _graph = IdentityGraph(
        handles: [
          for (final h in identity['handles']! as List)
            DomainCodec.handleFrom((h! as Map).cast<String, Object?>()),
        ],
        decisions: [
          for (final d in identity['decisions']! as List)
            decisionFromJson((d! as Map).cast<String, Object?>()),
        ],
      );
    }
    if (frame['live'] case final Map<Object?, Object?> live) {
      for (final MapEntry(:key, :value) in live.entries) {
        _live[key! as String] = (value! as Map).cast<String, Object?>();
      }
    }
    if (frame['timelines'] case final Map<Object?, Object?> timelines) {
      for (final MapEntry(:key, :value) in timelines.entries) {
        _timelines[int.parse(key! as String)]?.apply(
          (value! as Map).cast<String, Object?>(),
        );
      }
    }

    if (frame['settings'] case final Map<Object?, Object?> settings) {
      final changes = {
        for (final MapEntry(:key, :value) in settings.entries)
          key! as String: value as String?,
      };
      if (_settingsController.hasListener) {
        _settingsController.add(changes);
      } else {
        _pendingSettings.addAll(changes);
      }
    }

    if (!_firstState.isCompleted) _firstState.complete();
    // A fresh list on every frame, as the native repository does on every
    // sync: the chat screen refreshes its timeline, typing and receipts on
    // this heartbeat.
    if (!_chatsController.isClosed) _chatsController.add(List.of(_chats));
  }

  Future<Object?> _call(String method, Map<String, Object?> params) async {
    try {
      return await _peer.call(method, params);
    } on RemoteException catch (e) {
      throw switch (e.code) {
        RemoteErrors.notFound => ArgumentError(e.message),
        RemoteErrors.state => StateError(e.message),
        _ => e,
      };
    }
  }

  Future<void> _act(String method, Map<String, Object?> params) async {
    await _call(method, params);
  }

  // --------------------------------------------------------------- reading

  @override
  List<ChatNetwork> get availableNetworks => _networks;

  @override
  Stream<List<Chat>> watchChats() async* {
    yield _chats;
    yield* _chatsController.stream;
  }

  @override
  Chat? chatForRoom(String roomId) {
    for (final chat in _chats) {
      if (chat.sources.any((s) => s.roomId == roomId)) return chat;
    }
    return null;
  }

  @override
  int get timelineEpoch => _epoch;

  /// The phone's send queue, as it pushes it.
  @override
  Map<String, SendFailure> get sendFailures => _failures;

  @override
  Stream<Map<String, SendFailure>> get sendFailureChanges =>
      _failuresController.stream;

  @override
  Set<String> get serviceChatIds => _service;

  @override
  IdentityGraph get identityGraph => _graph;

  @override
  String? avatarUrlFor(String userId, {String? roomId}) => null;

  @override
  Future<MergedTimeline> timelineFor(String chatId) =>
      _timelineByChat[chatId] ??= _openTimeline(chatId).catchError((Object e) {
        _timelineByChat.remove(chatId);
        throw e;
      });

  Future<MergedTimeline> _openTimeline(String chatId) async {
    final result =
        (await _call(RemoteMethods.timelineOpen, {'chat': chatId}))! as Map;
    final id = result['id']! as int;
    final remote = _RemoteTimeline(this, id);
    remote.apply((result['timeline']! as Map).cast<String, Object?>());
    _timelines[id] = remote;
    return MergedTimeline(sources: remote.sources.values.toList());
  }

  @override
  List<String> typingIn(String chatId) => [
    for (final t in (_live[chatId]?['typing'] as List?) ?? const [])
      t as String,
  ];

  @override
  ({bool online, DateTime? lastActiveAt})? presenceFor(String chatId) {
    final p = (_live[chatId]?['presence'] as Map?)?.cast<String, Object?>();
    if (p == null) return null;
    return (online: p['online'] == true, lastActiveAt: _time(p['at']));
  }

  @override
  List<({String roomId, String userId, String eventId, DateTime at})>
  peerReadUpTo(String chatId) => [
    for (final raw in (_live[chatId]?['peer'] as List?) ?? const [])
      if ((raw as Map).cast<String, Object?>() case final r)
        (
          roomId: r['room']! as String,
          userId: r['user']! as String,
          eventId: r['event']! as String,
          at: _time(r['at'])!,
        ),
  ];

  @override
  List<({String roomId, String eventId, DateTime at})> ownReadUpTo(
    String chatId,
  ) => [
    for (final raw in (_live[chatId]?['own'] as List?) ?? const [])
      if ((raw as Map).cast<String, Object?>() case final r)
        (
          roomId: r['room']! as String,
          eventId: r['event']! as String,
          at: _time(r['at'])!,
        ),
  ];

  static DateTime? _time(Object? v) =>
      v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;

  /// The phone indexes what it shows; the browser keeps no index of its own.
  @override
  void indexMessages(
    String chatId,
    List<WeftMessage> messages, {
    String chatTitle = '',
  }) {}

  /// Names from an address book belong to the device that has one.
  @override
  void setDeviceContacts(ContactBook contacts) {}

  // --------------------------------------------------------------- acting

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) =>
      _act(RemoteMethods.send, {'chat': chatId, 'body': body, 'via': ?via?.id});

  @override
  Future<void> sendReply(
    String chatId,
    String body, {
    required String replyToEventId,
    ChatNetwork? via,
  }) => _act(RemoteMethods.sendReply, {
    'chat': chatId,
    'body': body,
    'replyTo': replyToEventId,
    'via': ?via?.id,
  });

  @override
  Future<void> sendThreadReply(
    String chatId,
    String body, {
    required String threadRootId,
    String? replyToEventId,
    String? threadLatestEventId,
  }) => _act(RemoteMethods.sendThreadReply, {
    'chat': chatId,
    'body': body,
    'root': threadRootId,
    'replyTo': ?replyToEventId,
    'latest': ?threadLatestEventId,
  });

  @override
  Future<void> sendLocation(
    String chatId, {
    required double latitude,
    required double longitude,
    ChatNetwork? via,
  }) => _act(RemoteMethods.sendLocation, {
    'chat': chatId,
    'lat': latitude,
    'lon': longitude,
    'via': ?via?.id,
  });

  @override
  Future<void> sendCalendarInvite(
    String chatId, {
    required String title,
    required DateTime start,
    DateTime? end,
    ChatNetwork? via,
  }) => _act(RemoteMethods.sendCalendarInvite, {
    'chat': chatId,
    'title': title,
    'start': start.millisecondsSinceEpoch,
    'end': ?end?.millisecondsSinceEpoch,
    'via': ?via?.id,
  });

  @override
  Future<void> editCalendarInvite(
    String roomId,
    String inviteEventId, {
    required String title,
    required DateTime start,
    DateTime? end,
  }) => _act(RemoteMethods.editCalendarInvite, {
    'room': roomId,
    'event': inviteEventId,
    'title': title,
    'start': start.millisecondsSinceEpoch,
    'end': ?end?.millisecondsSinceEpoch,
  });

  @override
  Future<void> respondCalendarInvite(
    String roomId,
    String inviteEventId, {
    required CalendarReply reply,
    DateTime? proposedStart,
  }) => _act(RemoteMethods.respondCalendarInvite, {
    'room': roomId,
    'event': inviteEventId,
    'reply': reply.name,
    'proposed': ?proposedStart?.millisecondsSinceEpoch,
  });

  @override
  Future<void> createPoll(
    String chatId, {
    required String question,
    required List<String> options,
    ChatNetwork? via,
  }) => _act(RemoteMethods.createPoll, {
    'chat': chatId,
    'question': question,
    'options': options,
    'via': ?via?.id,
  });

  @override
  Future<void> votePoll(
    String roomId,
    String startEventId,
    Set<String> answerIds,
  ) => _act(RemoteMethods.votePoll, {
    'room': roomId,
    'event': startEventId,
    'answers': answerIds.toList(),
  });

  @override
  Future<void> react(String chatId, String eventId, String key) =>
      _act(RemoteMethods.react, {'chat': chatId, 'event': eventId, 'key': key});

  @override
  Future<void> unreact(String chatId, String reactionEventId) =>
      _act(RemoteMethods.unreact, {'chat': chatId, 'event': reactionEventId});

  @override
  Future<void> editMessage(String chatId, String eventId, String newBody) =>
      _act(RemoteMethods.editMessage, {
        'chat': chatId,
        'event': eventId,
        'body': newBody,
      });

  @override
  Future<void> redact(String chatId, String eventId) =>
      _act(RemoteMethods.redact, {'chat': chatId, 'event': eventId});

  @override
  Future<void> setSendNetwork(String chatId, ChatNetwork network) => _act(
    RemoteMethods.setSendNetwork,
    {'chat': chatId, 'network': network.id},
  );

  @override
  Future<void> markRead(String chatId) =>
      _act(RemoteMethods.markRead, {'chat': chatId});

  @override
  Future<void> markUnread(String chatId) =>
      _act(RemoteMethods.markUnread, {'chat': chatId});

  @override
  Future<void> markUnreadFrom(
    String chatId,
    String roomId,
    String eventId, {
    String? before,
    int count = 1,
  }) => _act(RemoteMethods.markUnreadFrom, {
    'chat': chatId,
    'room': roomId,
    'event': eventId,
    'before': ?before,
    'count': count,
  });

  @override
  Future<void> retryFailedSend(String roomId, String eventId) =>
      _act(RemoteMethods.retryFailedSend, {'room': roomId, 'event': eventId});

  @override
  Future<void> discardFailedSend(String roomId, String eventId) =>
      _act(RemoteMethods.discardFailedSend, {'room': roomId, 'event': eventId});

  @override
  Future<void> forgetLocally(String roomId, String eventId) =>
      _act(RemoteMethods.forgetLocally, {'room': roomId, 'event': eventId});

  @override
  Future<void> setArchived(String chatId, {required bool archived}) =>
      _act(RemoteMethods.setArchived, {'chat': chatId, 'on': archived});

  @override
  Future<void> setMuted(String chatId, {required bool muted}) =>
      _act(RemoteMethods.setMuted, {'chat': chatId, 'on': muted});

  @override
  Future<void> deleteChat(String chatId) =>
      _act(RemoteMethods.deleteChat, {'chat': chatId});

  @override
  Future<void> setTyping(String chatId, {required bool typing}) =>
      _act(RemoteMethods.setTyping, {'chat': chatId, 'on': typing});

  @override
  Future<void> mergeHandles(String handleIdA, String handleIdB) =>
      _act(RemoteMethods.mergeHandles, {'a': handleIdA, 'b': handleIdB});

  @override
  Future<void> unmergeHandle(String handleId) =>
      _act(RemoteMethods.unmergeHandle, {'handle': handleId});

  @override
  Future<void> rejectSuggestion(String handleIdA, String handleIdB) =>
      _act(RemoteMethods.rejectSuggestion, {'a': handleIdA, 'b': handleIdB});

  @override
  Future<String?> createDirectChat(String matrixUserId) async =>
      await _call(RemoteMethods.createDirectChat, {'user': matrixUserId})
          as String?;

  @override
  Future<String?> createGroupChat(
    String name,
    List<String> inviteMatrixIds,
  ) async =>
      await _call(RemoteMethods.createGroupChat, {
            'name': name,
            'invite': inviteMatrixIds,
          })
          as String?;

  @override
  Future<bool> startBridgeChat(ChatNetwork network, String identifier) async =>
      await _call(RemoteMethods.startBridgeChat, {
        'network': network.id,
        'identifier': identifier,
      }) ==
      true;

  @override
  Future<ChatRequestState?> answerChatRequest(
    String chatId,
    ChatRequestAction action,
  ) async {
    final name = await _call(RemoteMethods.answerChatRequest, {
      'chat': chatId,
      'action': action.name,
    });
    return name is String ? ChatRequestState.values.byName(name) : null;
  }

  // ---------------------------------------------------------- attachments

  @override
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  }) async {
    final data = await _call(RemoteMethods.attachmentBytes, {
      'room': roomId,
      'event': eventId,
      'thumb': thumbnail,
    });
    return data is String ? base64.decode(data) : null;
  }

  /// No address the browser could fetch: media is behind the homeserver's
  /// authentication, which stays on the phone. [attachmentBytes] carries it.
  @override
  Future<AttachmentLocation?> attachmentLocation(
    String roomId,
    String eventId,
  ) async => null;

  /// Sending a file from the browser needs its bytes carried to the phone,
  /// which this version does not do yet; the composer hides the button.
  @override
  Future<void> sendAttachment(
    String chatId,
    AttachmentSource source, {
    ChatNetwork? via,
    bool isVoiceNote = false,
    int? durationMs,
    String? caption,
  }) => throw UnsupportedError('Attachments are sent from the phone');

  @override
  Stream<List<UploadTask>> watchUploads(String chatId) =>
      Stream.value(const []);

  @override
  Future<void> retryUpload(String taskId) async {}

  @override
  Future<void> cancelUpload(String taskId) async {}

  Future<Object?> _more(int id, String room, int count) => _call(
    RemoteMethods.timelineMore,
    {'id': id, 'room': room, 'count': count},
  );
}

/// One open timeline: a source per room, refreshed by pushed state and by
/// the answers to [TimelineSource.loadMore].
class _RemoteTimeline {
  _RemoteTimeline(this._repo, this.id);

  final RemoteChatRepository _repo;
  final int id;
  final Map<String, _RemoteSource> sources = {};

  void apply(Map<String, Object?> json) {
    for (final MapEntry(:key, :value) in json.entries) {
      final j = (value! as Map).cast<String, Object?>();
      final source = sources.putIfAbsent(
        key,
        () => _RemoteSource(
          timeline: this,
          roomId: key,
          network: ChatNetwork.fromId(j['net']! as String),
          clockOffset: Duration(milliseconds: (j['offset'] as int?) ?? 0),
        ),
      );
      source
        .._hasMore = j['more'] == true
        .._loaded = [
          for (final m in j['loaded']! as List)
            DomainCodec.messageFrom((m! as Map).cast<String, Object?>()),
        ];
    }
  }

  Future<int> loadMore(String room, int count) async {
    final result = (await _repo._more(id, room, count))! as Map;
    apply((result['timeline']! as Map).cast<String, Object?>());
    return result['added']! as int;
  }
}

class _RemoteSource extends TimelineSource {
  _RemoteSource({
    required _RemoteTimeline timeline,
    required this.roomId,
    required this.network,
    required Duration clockOffset,
  }) : _timeline = timeline,
       _clockOffset = clockOffset;

  final _RemoteTimeline _timeline;
  final Duration _clockOffset;

  @override
  final String roomId;

  @override
  final ChatNetwork network;

  List<WeftMessage> _loaded = const [];
  bool _hasMore = false;

  @override
  Duration get clockOffset => _clockOffset;

  @override
  List<WeftMessage> get loaded => _loaded;

  @override
  bool get hasMore => _hasMore;

  @override
  Future<int> loadMore({int count = 30}) => _timeline.loadMore(roomId, count);
}
