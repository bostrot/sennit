import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

import 'mapping.dart';

/// What a push gateway hands the app for one poke.
///
/// With [kEventIdOnlyFormat] this is nearly the whole payload: which room,
/// which event, and how many the server thinks are unread. Everything the user
/// eventually reads is fetched and decrypted afterwards, by
/// [MatrixNotificationPipeline].
@immutable
class MatrixPushPayload {
  const MatrixPushPayload({
    this.roomId,
    this.eventId,
    this.unreadCount,
    this.deviceIds = const [],
  });

  final String? roomId;
  final String? eventId;

  /// The homeserver's unread count *at push time*. Useful for a badge and
  /// nothing else — it is stale the moment the user reads on another device.
  final int? unreadCount;

  /// Pushkeys the poke was addressed to. Present so a device can notice a push
  /// meant for a token it has since rotated away from.
  final List<String> deviceIds;

  /// A poke with no event: the homeserver telling the app its unread count has
  /// dropped, typically to zero, because the user read the room somewhere else.
  ///
  /// It is a *dismissal*, not a notification, and the platform layer should
  /// clear the room's posted notifications rather than post anything. Sygnal
  /// sends these routinely; treating one as a malformed message payload is how
  /// a notification ends up outliving the message it was for.
  bool get isClearing => eventId == null;

  /// Parses whatever the platform handed over.
  ///
  /// Three shapes reach this, and all three are real:
  ///
  /// - the gateway's own `{"notification": {...}}` envelope, when the payload
  ///   is passed through verbatim;
  /// - a flattened FCM data map, where **every value is a string** because that
  ///   is all an FCM data message can carry — so `unread` arrives as `"3"`;
  /// - an APNs payload, where the Matrix keys sit beside `aps`.
  ///
  /// Returns null only when there is nothing Matrix-shaped in [data] at all.
  /// A payload with a room and no event is *not* null: see [isClearing].
  static MatrixPushPayload? fromJson(Map<Object?, Object?> data) {
    final envelope = data['notification'];
    final source = envelope is Map ? envelope : data;

    final roomId = _asString(source['room_id']);
    final eventId = _asString(source['event_id']);
    final counts = source['counts'];
    final unread = counts is Map
        ? _asInt(counts['unread'])
        : _asInt(source['unread']);

    if (roomId == null && eventId == null && unread == null) return null;

    final devices = source['devices'];
    return MatrixPushPayload(
      roomId: roomId,
      eventId: eventId,
      unreadCount: unread,
      deviceIds: devices is List
          ? [
              for (final device in devices)
                ?_asString(device is Map ? device['pushkey'] : device),
            ]
          : const [],
    );
  }

  @override
  String toString() =>
      'MatrixPushPayload(room: $roomId, event: $eventId, unread: $unreadCount)';
}

/// A notification that should be posted, and how loudly.
@immutable
class MatrixNotification {
  const MatrixNotification({required this.content, required this.decision});

  final NotificationContent content;

  /// The verdict it came from. Carried whole rather than flattened to a bool so
  /// the platform layer can read [DeliveredDecision.mentioned] for priority as
  /// well as [isSilent] for the channel.
  final DeliveredDecision decision;

  /// Post without sound or vibration. Reached only through quiet hours with
  /// `deliverSilently`.
  bool get isSilent => decision is SilentDecision;

  @override
  String toString() =>
      'MatrixNotification(${content.groupKey}, '
      'silent: $isSilent, mention: ${content.isMention})';
}

/// The slice of a live session the notification path needs.
///
/// Deliberately expressed in [WeftMessage]s rather than `sdk.Event`s: the whole
/// point of the seam is that everything SDK-shaped — fetching an event by id,
/// decrypting it, working out which network a room belongs to — happens on the
/// far side of it, so the pipeline above can be tested by handing it messages.
abstract class MatrixNotificationSession {
  /// Reads through to a live client.
  factory MatrixNotificationSession.forClient(sdk.Client client) =
      _ClientNotificationSession;

  /// Every id that counts as "the user". A set because the user is their
  /// Matrix id on their homeserver and may be reachable under others.
  Set<String> get ownUserIds;

  /// The textual forms a mention can take: the user's Matrix display name plus
  /// whatever each bridge calls them, since a bridged mention arrives as the
  /// literal characters of a name and nothing else.
  Set<String> get ownDisplayNames;

  /// Messages as they arrive on sync, already decrypted and mapped.
  ///
  /// This is the foreground half of the contract: the app that is open must
  /// reach the same verdict as the app that was asleep.
  Stream<WeftMessage> get incomingMessages;

  /// Fetches and decrypts one event, for a push that carried only its id.
  ///
  /// Null when the room is not known to this session, the event has been
  /// redacted away, or it could not be decrypted — all of which are ordinary
  /// and none of which is worth posting a notification about.
  Future<WeftMessage?> messageFor({
    required String roomId,
    required String eventId,
  });

  /// When the user last read [roomId], from their own read receipt.
  ///
  /// The receipt is account-wide, so this is how "already read on my laptop"
  /// becomes observable on the phone. Null when no receipt has been seen, which
  /// means "no idea", not "never read".
  DateTime? lastReadAt(String roomId);
}

/// The chat a room belongs to, as the app has already resolved it.
///
/// Injected rather than derived, and that is the single most important choice
/// in this file: the merge fold lives in `MatrixChatRepository._applyMerges`
/// and produces `merged:<contactId>` for a contact with two legs. Re-deriving a
/// conversation from a room id here would be a second answer to a question the
/// app has already answered, and the two would drift into a merged contact with
/// two notification threads.
typedef ChatForRoom = Chat? Function(String roomId);

/// The user's current notification policy, read per message.
///
/// A function rather than a value because the policy changes while the app
/// runs — a mute applied from the notification shade must affect the next
/// message, not the next launch.
typedef NotificationPolicyLookup = NotificationPolicy Function();

/// Turns Matrix events into notification decisions, whichever way they arrive.
///
/// Two entry points, one body: [handlePush] for an `event_id_only` poke that
/// woke the app, and the [MatrixNotificationSession.incomingMessages]
/// subscription for the app that is already running. They share the policy, the
/// clock, the read-marker lookup and — critically — the [NotificationDedupe],
/// because a message arriving by both routes is the normal case and must buzz
/// once.
///
/// What it does *not* do is post anything. Decisions and rendered content come
/// out of [notifications]; `flutter_local_notifications`, FCM and the platform
/// channels live above this in `apps/weft`, and nothing here imports them.
class MatrixNotificationPipeline {
  MatrixNotificationPipeline({
    required MatrixNotificationSession session,
    required ChatForRoom chatForRoom,
    required NotificationPolicyLookup policy,
    NotificationDedupe? dedupe,
    DateTime Function()? now,
  }) : _session = session,
       _chatForRoom = chatForRoom,
       _policy = policy,
       _dedupe = dedupe ?? NotificationDedupe(),
       _now = now ?? DateTime.now;

  final MatrixNotificationSession _session;
  final ChatForRoom _chatForRoom;
  final NotificationPolicyLookup _policy;
  final NotificationDedupe _dedupe;
  final DateTime Function() _now;

  final _controller = StreamController<MatrixNotification>.broadcast();
  StreamSubscription<WeftMessage>? _sub;

  /// Notifications to post, in the order they were decided.
  Stream<MatrixNotification> get notifications => _controller.stream;

  /// The shared ledger of event ids already decided on. Exposed so a dismissed
  /// notification can be forgotten and allowed to notify again.
  NotificationDedupe get dedupe => _dedupe;

  /// Starts the foreground path. Idempotent.
  void start() {
    _sub ??= _session.incomingMessages.listen(
      (message) => unawaited(_handle(message)),
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _controller.close();
  }

  /// Decides what to do about a push poke.
  ///
  /// Returns null when there is no verdict to reach — a clearing push, a room
  /// this session has never synced, an event that would not decrypt, or a room
  /// the inbox has not folded into a chat yet. Null is not a suppression: it
  /// means the question could not be asked, and the caller should neither post
  /// nor record a reason.
  Future<NotificationDecision?> handlePush(Map<Object?, Object?> data) async {
    final payload = MatrixPushPayload.fromJson(data);
    final roomId = payload?.roomId;
    final eventId = payload?.eventId;
    if (payload == null || roomId == null || eventId == null) return null;

    // Cheapest possible early out, and the one that matters most on battery:
    // the sync path has very often already decided this exact event by the time
    // the push lands, and fetching it again would cost a round trip and a
    // decrypt to reach the same answer.
    if (_dedupe.contains(eventId)) {
      return const NotificationDecision.suppress(
        NotificationSuppression.duplicate,
      );
    }

    final message = await _session.messageFor(roomId: roomId, eventId: eventId);
    if (message == null) return null;

    return _handle(message);
  }

  /// Decides what to do about a message that arrived on sync.
  ///
  /// Public because the foreground subscription is not the only caller: a
  /// re-evaluation after the user changes their policy goes through here too.
  Future<NotificationDecision?> handleMessage(WeftMessage message) =>
      _handle(message);

  Future<NotificationDecision?> _handle(WeftMessage message) async {
    final chat = _chatForRoom(message.roomId);
    // No chat means the inbox has not seen this room yet — during first sync,
    // or for a room that has just been joined. Grouping without it would have
    // to invent a key, and an invented key is the failure this whole path is
    // designed around.
    if (chat == null) return null;

    final policy = _policy();
    final decision = evaluateNotification(
      message: message,
      chat: chat,
      policy: policy,
      now: _now(),
      lastReadAt: _session.lastReadAt(message.roomId),
      ownUserIds: _session.ownUserIds,
      ownDisplayNames: _session.ownDisplayNames,
      dedupe: _dedupe,
    );

    if (decision case final DeliveredDecision delivered) {
      final content = NotificationContent.forMessage(
        message: message,
        chat: chat,
        policy: policy,
        decision: delivered,
      );
      if (!_controller.isClosed) {
        _controller.add(
          MatrixNotification(content: content, decision: delivered),
        );
      }
    }
    return decision;
  }
}

/// [MatrixNotificationSession] over a live SDK client.
class _ClientNotificationSession implements MatrixNotificationSession {
  _ClientNotificationSession(this._client);

  final sdk.Client _client;

  @override
  Set<String> get ownUserIds {
    final id = _client.userID;
    return id == null ? const {} : {id};
  }

  @override
  Set<String> get ownDisplayNames {
    final id = _client.userID;
    if (id == null) return const {};

    // Per room, not once: a bridge sets its own display name for the user in
    // the rooms it manages, so the name a WhatsApp contact would type is only
    // visible on that room's member event. Collecting them all is what lets a
    // mention by any of those names be recognised.
    final names = <String>{};
    for (final room in _client.rooms) {
      final name = room.unsafeGetUserFromMemoryOrFallback(id).displayName;
      if (name != null && name.trim().isNotEmpty) names.add(name.trim());
    }
    return names;
  }

  @override
  Stream<WeftMessage> get incomingMessages async* {
    await for (final event in _client.onTimelineEvent.stream) {
      // Sync decrypts before this stream fires; an event still typed
      // `m.room.encrypted` here is one whose keys have not arrived. It is
      // queued for a later decrypt by the SDK, and notifying about a message
      // nobody can read yet would be worse than staying quiet.
      if (event.type == sdk.EventTypes.Encrypted) continue;

      final room = event.room;
      final message = mapEvent(
        event,
        network: networkForRoom(room),
        ownUserId: _client.userID,
      );
      if (message != null) yield message;
    }
  }

  @override
  Future<WeftMessage?> messageFor({
    required String roomId,
    required String eventId,
  }) async {
    final room = _client.getRoomById(roomId);
    if (room == null) return null;

    try {
      // Decrypts on the way out for an encrypted room, which is the half of
      // `event_id_only` push that has to work: the payload carried no text, so
      // this call *is* the message.
      final event = await room.getEventById(eventId);
      if (event == null || event.type == sdk.EventTypes.Encrypted) return null;

      return mapEvent(
        event,
        network: networkForRoom(room),
        ownUserId: _client.userID,
      );
    } on Exception {
      // An unreachable server or a failed decrypt. The event will come down
      // sync later and be decided then.
      return null;
    }
  }

  @override
  DateTime? lastReadAt(String roomId) {
    final room = _client.getRoomById(roomId);
    // `latestOwnReceipt` is the newest of the user's public and private read
    // receipts, so a message read on their laptop stops the phone notifying
    // about it as soon as that receipt syncs.
    return room?.receiptState.global.latestOwnReceipt?.timestamp;
  }
}

String? _asString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// FCM data messages carry only strings, so `"3"` and `3` are the same number
/// arriving by two transports.
int? _asInt(Object? value) => switch (value) {
  final int v => v,
  final num v => v.round(),
  final String v => int.tryParse(v.trim()),
  _ => null,
};
