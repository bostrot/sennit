/// Why a message the user sent did not leave.
///
/// A red mark with no reason leaves the reader guessing whether to wait, retry
/// or rewrite. These are the reasons worth telling apart because each asks for
/// something different: waiting, shortening, nothing at all, or a manual retry.
enum SendFailure {
  /// The homeserver could not be reached. Sennit sends it by itself once it is.
  offline,

  /// The server refused it for its size.
  tooLarge,

  /// The account may not post in this chat.
  notAllowed,

  /// The server answered and said no, for a reason it did not name.
  rejected;

  /// Whether the queue sends it again without being asked.
  ///
  /// Only a lost connection heals by itself. Re-sending something the server
  /// refused would be refused again, every sync, forever.
  bool get retriesAutomatically => this == SendFailure.offline;

  static SendFailure? fromName(String? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// One failed send: which room it was for and why it failed.
class QueuedSend {
  const QueuedSend({required this.roomId, required this.failure});

  final String roomId;
  final SendFailure failure;

  @override
  bool operator ==(Object other) =>
      other is QueuedSend && other.roomId == roomId && other.failure == failure;

  @override
  int get hashCode => Object.hash(roomId, failure);
}

/// The sends that failed, by the local echo's event id.
///
/// The Matrix SDK keeps the failed echo itself, in its own database, but not
/// why it failed; this keeps the why, so the reason survives a restart and the
/// messages that were only waiting for a connection go out when it returns.
class SendQueue {
  SendQueue([Map<String, QueuedSend>? entries]) : _entries = {...?entries};

  final Map<String, QueuedSend> _entries;

  /// Why [eventId] failed, or null if it did not (or no longer does).
  SendFailure? failureOf(String eventId) => _entries[eventId]?.failure;

  /// Every failure, by event id.
  Map<String, SendFailure> get failures => {
    for (final entry in _entries.entries) entry.key: entry.value.failure,
  };

  /// The sends to try again now that the connection is back, oldest first.
  List<(String eventId, String roomId)> get dueForRetry => [
    for (final entry in _entries.entries)
      if (entry.value.failure.retriesAutomatically)
        (entry.key, entry.value.roomId),
  ];

  bool get isEmpty => _entries.isEmpty;

  /// Records that [eventId] failed for [failure]. Returns whether that changed
  /// anything.
  bool record(String eventId, String roomId, SendFailure failure) {
    final entry = QueuedSend(roomId: roomId, failure: failure);
    if (_entries[eventId] == entry) return false;
    // Removed first so a re-failure moves to the back of the queue.
    _entries
      ..remove(eventId)
      ..[eventId] = entry;
    return true;
  }

  /// Forgets [eventId]: it was sent, or the user discarded it. Returns whether
  /// it was there.
  bool clear(String eventId) => _entries.remove(eventId) != null;

  Map<String, Object?> toJson() => {
    for (final entry in _entries.entries)
      entry.key: {'room': entry.value.roomId, 'why': entry.value.failure.name},
  };

  /// Reads what [toJson] wrote, skipping anything it does not recognise rather
  /// than failing the whole queue on one bad row.
  factory SendQueue.fromJson(Map<String, Object?>? json) {
    final entries = <String, QueuedSend>{};
    for (final entry in (json ?? const {}).entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final room = value['room'];
      final failure = SendFailure.fromName(value['why'] as String?);
      if (room is! String || failure == null) continue;
      entries[entry.key] = QueuedSend(roomId: room, failure: failure);
    }
    return SendQueue(entries);
  }
}
