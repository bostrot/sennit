import 'package:weft_domain/weft_domain.dart';

/// The domain as JSON, for the browser client and the phone that serves it.
///
/// Written out by hand rather than generated: the domain package has no
/// serialisation of its own and should not grow a code generator for one
/// consumer. Every reader tolerates a missing optional field, so an older
/// browser bundle keeps working against a newer phone for fields it does not
/// know. Times are milliseconds since the epoch, UTC. 64-bit hashes travel as
/// strings, because a browser's numbers cannot hold them exactly.
abstract final class DomainCodec {
  // ------------------------------------------------------------------ chats

  static Map<String, Object?> chat(Chat c) => {
    'id': c.id,
    'title': c.title,
    'sources': [for (final s in c.sources) source(s)],
    'contactId': ?c.contactId,
    'avatarUrl': ?c.avatarUrl,
    'last': ?_opt(c.lastMessage, message),
    'reaction': ?_opt(c.lastReaction, message),
    'activityAt': ?c.lastActivityAt?.millisecondsSinceEpoch,
    if (c.unreadCount != 0) 'unread': c.unreadCount,
    if (c.isGroup) 'group': true,
    if (c.pinned) 'pinned': true,
    if (c.archived) 'archived': true,
    if (c.muted) 'muted': true,
    'request': ?c.request?.name,
    'participants': ?c.participantCount,
    'reactedUpTo': ?c.reactedUpTo?.millisecondsSinceEpoch,
    'via': ?c.preferredSendNetwork?.id,
  };

  static Chat chatFrom(Map<String, Object?> j) => Chat(
    id: j['id']! as String,
    title: j['title']! as String,
    sources: [for (final s in _list(j['sources'])) sourceFrom(_map(s))],
    contactId: j['contactId'] as String?,
    avatarUrl: j['avatarUrl'] as String?,
    lastMessage: j['last'] == null ? null : messageFrom(_map(j['last'])),
    lastReaction: j['reaction'] == null
        ? null
        : messageFrom(_map(j['reaction'])),
    activityAt: _time(j['activityAt']),
    unreadCount: (j['unread'] as int?) ?? 0,
    isGroup: j['group'] == true,
    pinned: j['pinned'] == true,
    archived: j['archived'] == true,
    muted: j['muted'] == true,
    request: _enum(ChatRequestState.values, j['request']),
    participantCount: j['participants'] as int?,
    reactedUpTo: _time(j['reactedUpTo']),
    preferredSendNetwork: _network(j['via']),
  );

  static Map<String, Object?> source(ChatSource s) => {
    'room': s.roomId,
    'net': s.network.id,
    'handle': ?s.handleId,
    if (s.muted) 'muted': true,
    if (s.unread != 0) 'unread': s.unread,
  };

  static ChatSource sourceFrom(Map<String, Object?> j) => ChatSource(
    roomId: j['room']! as String,
    network: ChatNetwork.fromId(j['net']! as String),
    handleId: j['handle'] as String?,
    muted: j['muted'] == true,
    unread: (j['unread'] as int?) ?? 0,
  );

  // --------------------------------------------------------------- messages

  static Map<String, Object?> message(WeftMessage m) => {
    'id': m.eventId,
    'room': m.roomId,
    'net': m.network.id,
    'sender': m.senderId,
    'senderName': m.senderName,
    'ts': m.timestamp.millisecondsSinceEpoch,
    'kind': m.kind.name,
    if (m.isOwn) 'own': true,
    if (m.isAutoReply) 'auto': true,
    if (m.isBridgeNotice) 'notice': true,
    'reactionKey': ?m.reactionKey,
    if (m.body.isNotEmpty) 'body': m.body,
    'html': ?m.formattedBody,
    'transcript': ?m.transcript,
    'replyTo': ?m.replyToEventId,
    'reply': ?_opt(m.replyPreview, _reply),
    'thread': ?m.threadRootId,
    'threadName': ?m.threadName,
    if (m.reactions.isNotEmpty)
      'reactions': [for (final r in m.reactions) _reaction(r)],
    if (m.editHistory.isNotEmpty)
      'edits': [for (final e in m.editHistory) _edit(e)],
    'editedAt': ?m.editedAt?.millisecondsSinceEpoch,
    if (m.redacted) 'redacted': true,
    'delivery': ?m.deliveryState?.name,
    'url': ?m.attachmentUrl,
    'file': ?m.attachmentName,
    'geo': ?m.geoUri,
    'poll': ?_opt(m.poll, _poll),
    'invite': ?_opt(m.calendarInvite, _invite),
    'duration': ?m.durationMs,
    'w': ?m.mediaWidth,
    'h': ?m.mediaHeight,
    'size': ?m.mediaSizeBytes,
    'mime': ?m.mediaMimeType,
    if (m.playsAsGif) 'gif': true,
    if (m.encrypted) 'e2e': true,
    'previews': ?m.bridgedLinkPreviews,
  };

  static WeftMessage messageFrom(Map<String, Object?> j) => WeftMessage(
    eventId: j['id']! as String,
    roomId: j['room']! as String,
    network: ChatNetwork.fromId(j['net']! as String),
    senderId: j['sender']! as String,
    senderName: j['senderName']! as String,
    timestamp: _time(j['ts'])!,
    kind: _enum(MessageKind.values, j['kind']) ?? MessageKind.text,
    isOwn: j['own'] == true,
    isAutoReply: j['auto'] == true,
    isBridgeNotice: j['notice'] == true,
    reactionKey: j['reactionKey'] as String?,
    body: (j['body'] as String?) ?? '',
    formattedBody: j['html'] as String?,
    transcript: j['transcript'] as String?,
    replyToEventId: j['replyTo'] as String?,
    replyPreview: j['reply'] == null ? null : _replyFrom(_map(j['reply'])),
    threadRootId: j['thread'] as String?,
    threadName: j['threadName'] as String?,
    reactions: [for (final r in _list(j['reactions'])) _reactionFrom(_map(r))],
    editHistory: [for (final e in _list(j['edits'])) _editFrom(_map(e))],
    editedAt: _time(j['editedAt']),
    redacted: j['redacted'] == true,
    deliveryState: _enum(DeliveryState.values, j['delivery']),
    attachmentUrl: j['url'] as String?,
    attachmentName: j['file'] as String?,
    geoUri: j['geo'] as String?,
    poll: j['poll'] == null ? null : _pollFrom(_map(j['poll'])),
    calendarInvite: j['invite'] == null ? null : _inviteFrom(_map(j['invite'])),
    durationMs: j['duration'] as int?,
    mediaWidth: j['w'] as int?,
    mediaHeight: j['h'] as int?,
    mediaSizeBytes: j['size'] as int?,
    mediaMimeType: j['mime'] as String?,
    playsAsGif: j['gif'] == true,
    encrypted: j['e2e'] == true,
    bridgedLinkPreviews: j['previews'] == null
        ? null
        : [for (final p in _list(j['previews'])) _map(p)],
  );

  static Map<String, Object?> _reply(ReplyPreview r) => {
    'id': r.eventId,
    'room': ?r.roomId,
    'sender': ?r.senderId,
    'senderName': ?r.senderName,
    'kind': ?r.kind?.name,
    'net': ?r.network?.id,
    if (r.body.isNotEmpty) 'body': r.body,
    if (r.redacted) 'redacted': true,
  };

  static ReplyPreview _replyFrom(Map<String, Object?> j) => ReplyPreview(
    eventId: j['id']! as String,
    roomId: j['room'] as String?,
    senderId: j['sender'] as String?,
    senderName: j['senderName'] as String?,
    kind: _enum(MessageKind.values, j['kind']),
    network: _network(j['net']),
    body: (j['body'] as String?) ?? '',
    redacted: j['redacted'] == true,
  );

  static Map<String, Object?> _reaction(ReactionTally r) => {
    'key': r.key,
    'by': r.senderIds,
    'at': r.firstReactedAt.millisecondsSinceEpoch,
    if (r.byLocalUser) 'mine': true,
    'local': ?r.localEventId,
  };

  static ReactionTally _reactionFrom(Map<String, Object?> j) => ReactionTally(
    key: j['key']! as String,
    senderIds: [for (final s in _list(j['by'])) s! as String],
    firstReactedAt: _time(j['at'])!,
    byLocalUser: j['mine'] == true,
    localEventId: j['local'] as String?,
  );

  static Map<String, Object?> _edit(EditRecord e) => {
    'id': e.eventId,
    'body': e.body,
    'html': ?e.formattedBody,
    'ts': e.timestamp.millisecondsSinceEpoch,
  };

  static EditRecord _editFrom(Map<String, Object?> j) => EditRecord(
    eventId: j['id']! as String,
    body: j['body']! as String,
    formattedBody: j['html'] as String?,
    timestamp: _time(j['ts'])!,
  );

  static Map<String, Object?> _poll(PollData p) => {
    'q': p.question,
    'options': [
      for (final o in p.options) {'id': o.id, 'text': o.text},
    ],
    'votes': p.votes,
    'mine': p.ownVotes.toList(),
    if (p.ended) 'ended': true,
    if (p.undisclosed) 'hidden': true,
    'max': p.maxSelections,
    if (p.voters.isNotEmpty) 'voters': p.voters,
    'n': p.voterCount,
  };

  static PollData _pollFrom(Map<String, Object?> j) => PollData(
    question: j['q']! as String,
    options: [
      for (final o in _list(j['options']))
        PollOption(
          id: _map(o)['id']! as String,
          text: _map(o)['text']! as String,
        ),
    ],
    votes: {
      for (final MapEntry(:key, :value) in _map(j['votes']).entries)
        key: value! as int,
    },
    ownVotes: {for (final v in _list(j['mine'])) v! as String},
    ended: j['ended'] == true,
    undisclosed: j['hidden'] == true,
    maxSelections: (j['max'] as int?) ?? 1,
    voters: {
      for (final MapEntry(:key, :value) in _map(j['voters']).entries)
        key: [for (final name in _list(value)) name! as String],
    },
    voterCount: (j['n'] as int?) ?? 0,
  );

  static Map<String, Object?> pollSupport(PollSupport s) => {
    'on': s.available,
    'max': s.maxOptions,
    'len': s.optionMaxLength,
    if (s.multipleChoiceOnly) 'multiOnly': true,
    if (s.undisclosed) 'hidden': true,
    if (s.canEnd) 'end': true,
    if (s.uniqueOptions) 'unique': true,
  };

  static PollSupport pollSupportFrom(Map<String, Object?> j) => j['on'] != true
      ? const PollSupport.unavailable()
      : PollSupport(
          maxOptions: (j['max'] as int?) ?? PollSupport.maxAnswers,
          optionMaxLength: (j['len'] as int?) ?? 0,
          multipleChoiceOnly: j['multiOnly'] == true,
          undisclosed: j['hidden'] == true,
          canEnd: j['end'] == true,
          uniqueOptions: j['unique'] == true,
        );

  static Map<String, Object?> _invite(CalendarInvite i) => {
    'uid': i.uid,
    'title': i.title,
    'start': i.start.millisecondsSinceEpoch,
    'end': ?i.end?.millisecondsSinceEpoch,
    'responses': [
      for (final r in i.responses)
        {
          'sender': r.senderId,
          'senderName': r.senderName,
          'reply': r.reply.name,
          'proposed': ?r.proposedStart?.millisecondsSinceEpoch,
        },
    ],
  };

  static CalendarInvite _inviteFrom(Map<String, Object?> j) => CalendarInvite(
    uid: j['uid']! as String,
    title: j['title']! as String,
    start: _time(j['start'])!,
    end: _time(j['end']),
    responses: [
      for (final raw in _list(j['responses']))
        if (_enum(CalendarReply.values, _map(raw)['reply']) case final reply?)
          CalendarResponse(
            senderId: _map(raw)['sender']! as String,
            senderName: _map(raw)['senderName']! as String,
            reply: reply,
            proposedStart: _time(_map(raw)['proposed']),
          ),
    ],
  );

  // ---------------------------------------------------------------- handles

  static Map<String, Object?> handle(NetworkHandle h) => {
    'id': h.id,
    'net': h.network.id,
    'remote': h.remoteId,
    'mxid': h.matrixUserId,
    'room': ?h.roomId,
    'name': ?h.displayName,
    'avatar': ?h.avatarUrl,
    'phone': ?h.phoneE164,
    'email': ?h.email,
    'dhash': ?h.avatarDHash?.toString(),
    'contact': ?h.unifiedContactId,
  };

  static NetworkHandle handleFrom(Map<String, Object?> j) => NetworkHandle(
    id: j['id']! as String,
    network: ChatNetwork.fromId(j['net']! as String),
    remoteId: j['remote']! as String,
    matrixUserId: j['mxid']! as String,
    roomId: j['room'] as String?,
    displayName: j['name'] as String?,
    avatarUrl: j['avatar'] as String?,
    phoneE164: j['phone'] as String?,
    email: j['email'] as String?,
    avatarDHash: int.tryParse((j['dhash'] as String?) ?? ''),
    unifiedContactId: j['contact'] as String?,
  );

  // ---------------------------------------------------------------- helpers

  static Object? _opt<T extends Object>(T? v, Object? Function(T) f) =>
      v == null ? null : f(v);

  static List<Object?> _list(Object? v) => v is List ? v : const [];

  static Map<String, Object?> _map(Object? v) =>
      v is Map ? v.cast<String, Object?>() : const {};

  static DateTime? _time(Object? v) => v is int
      ? DateTime.fromMillisecondsSinceEpoch(v, isUtc: true).toLocal()
      : null;

  static ChatNetwork? _network(Object? v) =>
      v is String ? ChatNetwork.fromId(v) : null;

  static T? _enum<T extends Enum>(List<T> values, Object? name) {
    if (name is! String) return null;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }
}
