import 'dart:async';

import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

/// One piece of activity in a room: which event, and when.
///
/// [event] is the event itself once it is at hand — from the sync that
/// brought it, or read back from the SDK's database after a restart. The id
/// and time are what is kept between runs; the event is not, because its
/// content is a message and the settings table is no place for one.
class ActivityMark {
  ActivityMark(this.eventId, this.at, {this.event});

  String eventId;
  DateTime at;
  sdk.Event? event;

  /// For a reaction: the message it was put on, once read.
  sdk.Event? target;

  Map<String, Object?> toJson() => {
    'id': eventId,
    'ts': at.millisecondsSinceEpoch,
  };

  static ActivityMark? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final ts = json['ts'];
    if (id is! String || ts is! int) return null;
    return ActivityMark(id, DateTime.fromMillisecondsSinceEpoch(ts));
  }
}

/// The newest message and the newest reaction a room has seen.
class RoomActivity {
  ActivityMark? message;
  ActivityMark? reaction;

  /// Whether the cached timeline has been read for this room once. A room
  /// that has, and found nothing, is not read again on every start.
  bool scanned = false;

  Map<String, Object?> toJson() => {
    'm': ?message?.toJson(),
    'r': ?reaction?.toJson(),
    if (scanned) 's': true,
  };

  static RoomActivity fromJson(Object? json) {
    final activity = RoomActivity();
    if (json is Map) {
      activity
        ..message = ActivityMark.fromJson(json['m'])
        ..reaction = ActivityMark.fromJson(json['r'])
        ..scanned = json['s'] == true;
    }
    return activity;
  }
}

/// What last *happened* in each room, kept apart from what Matrix says last
/// happened in it.
///
/// The SDK's `Room.lastEvent` is the wrong clock for the inbox in three ways.
/// A sync that arrives limited — a bridge backfilling, a profile change that
/// fans out into a burst of state, a phone that was offline — replaces it with
/// a placeholder stamped with the burst's *first* event, which is how a
/// contact changing their profile picture put the conversation on top. An
/// edit replaces it too, at the edit's time. And a reaction never moves it.
///
/// So the inbox keeps its own: per room, the newest event [roomActivityOf]
/// counts as a message and the newest it counts as a reaction. Fed by every
/// timeline event the sync delivers, seeded once per room from the cached
/// timeline, and stored on this device so a restart starts from it.
class RoomActivityLog {
  RoomActivityLog({SettingsStore? settings}) : _settings = settings {
    final stored = settings?.getJson(WeftSettings.roomActivity);
    if (stored == null) return;
    for (final entry in stored.entries) {
      _rooms[entry.key] = RoomActivity.fromJson(entry.value);
    }
  }

  final SettingsStore? _settings;
  final Map<String, RoomActivity> _rooms = {};

  /// What is known about [roomId], or null for a room never seen.
  RoomActivity? operator [](String roomId) => _rooms[roomId];

  RoomActivity _of(String roomId) =>
      _rooms.putIfAbsent(roomId, RoomActivity.new);

  /// Takes [event] into account. True when it changed what [roomId] shows.
  ///
  /// An event replaces the mark only when it is at least as new, or when it
  /// *is* the marked event in a later state — the server's echo of a message
  /// the user just sent carries the transaction id the local echo was filed
  /// under, and a server clock a second behind the phone's must not leave the
  /// row on the echo for good.
  bool record(String roomId, sdk.Event event) {
    final kind = roomActivityOf(event);
    if (kind == null) return false;
    final activity = _of(roomId);
    final mark = switch (kind) {
      RoomActivityKind.message => activity.message,
      RoomActivityKind.reaction => activity.reaction,
    };
    final at = event.originServerTs;
    if (mark != null) {
      final same =
          mark.eventId == event.eventId ||
          (event.transactionId != null && mark.eventId == event.transactionId);
      if (!same && at.isBefore(mark.at)) return false;
      if (same) {
        final moved = mark.eventId != event.eventId || mark.at != at;
        final fresher = !identical(mark.event, event);
        mark
          ..eventId = event.eventId
          ..at = at
          ..event = event;
        if (moved) _persistSoon();
        return moved || fresher;
      }
    }
    final fresh = ActivityMark(event.eventId, at, event: event);
    switch (kind) {
      case RoomActivityKind.message:
        activity.message = fresh;
      case RoomActivityKind.reaction:
        activity.reaction = fresh;
    }
    _persistSoon();
    return true;
  }

  /// Forgets [roomId]'s reaction mark: the reaction was withdrawn, and what
  /// the row should show is whatever was newest before it.
  void dropReaction(String roomId) {
    final activity = _rooms[roomId];
    if (activity?.reaction == null) return;
    activity!
      ..reaction = null
      ..scanned = false;
    _persistSoon();
  }

  void markScanned(String roomId) {
    final activity = _of(roomId);
    if (activity.scanned) return;
    activity.scanned = true;
    _persistSoon();
  }

  /// Forgets rooms the account no longer has.
  void retainOnly(Set<String> roomIds) {
    final before = _rooms.length;
    _rooms.removeWhere((id, _) => !roomIds.contains(id));
    if (_rooms.length != before) _persistSoon();
  }

  Timer? _persistTimer;

  /// Written at most every few seconds: the initial sync can record an event
  /// per room per tick, and one JSON row rewritten that often is pure waste.
  void _persistSoon() {
    if (_settings == null) return;
    _persistTimer ??= Timer(const Duration(seconds: 3), flush);
  }

  /// Writes what is known now.
  void flush() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _settings?.setJson(WeftSettings.roomActivity, {
      for (final entry in _rooms.entries) entry.key: entry.value.toJson(),
    });
  }
}
