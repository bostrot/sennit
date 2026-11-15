import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// When the clock on a self-deleting message starts running.
///
/// Two anchors rather than one because the two questions people actually ask of
/// a disappearing message are different. "Nothing in this chat older than a
/// week" is about the conversation's shape and is answered from the moment a
/// message arrived. "Gone an hour after I have seen it" is about a single
/// message and cannot be answered until somebody has looked at it — a message
/// waiting unread on a locked phone has not started its clock, and one that
/// deleted itself before it was read would be a messenger that loses mail.
enum RetentionAnchor {
  /// From the moment the message arrived, read or not.
  arrival('arrival'),

  /// From the moment the conversation was read past this message. A message
  /// nobody has read yet never expires.
  read('read');

  const RetentionAnchor(this.id);

  /// The stable string this is persisted as. Never the enum's `name`: a rename
  /// in Dart would silently reinterpret every policy already on disk.
  final String id;

  static RetentionAnchor fromId(String? id) =>
      values.firstWhereOrNull((anchor) => anchor.id == id) ?? arrival;
}

/// How long one conversation keeps a message before Sennit deletes it.
///
/// The unit Sennit can honestly promise, and the wording matters because the two
/// halves of "delete" are not equally true:
///
/// * **The user's own messages are redacted** — removed for everyone the
///   homeserver can reach, and relayed onward as a delete by every bridge that
///   supports one.
/// * **Messages other people sent are removed from this device**: from the
///   local timeline, from Sennit's own message record, and from any media staged
///   on disk. Nobody else's copy is Sennit's to delete, and a client that said
///   otherwise would be lying about the one thing a disappearing message is
///   asked to do.
///
/// [off] is not a special case anywhere below — it is a policy whose [after] is
/// zero, and [isActive] is the single place that decides a policy does nothing.
@immutable
class RetentionPolicy {
  const RetentionPolicy({
    required this.after,
    this.anchor = RetentionAnchor.arrival,
  });

  /// Keep everything, forever. The default for every chat, and the only
  /// default that can be right: deleting a person's history is not something
  /// to opt them out of.
  static const RetentionPolicy off = RetentionPolicy(after: Duration.zero);

  /// How long a message survives past its anchor. Zero means never delete.
  final Duration after;

  final RetentionAnchor anchor;

  /// Whether this policy deletes anything at all.
  bool get isActive => after > Duration.zero;

  /// When a message sent at [sentAt] and read at [readAt] falls due, or null
  /// when it never does.
  ///
  /// Null has two causes and they are not the same: an inactive policy, and a
  /// [RetentionAnchor.read] policy over a message nobody has read yet. Both
  /// mean "do not delete this now", which is why one return value serves both.
  ///
  /// A read stamp *earlier* than the message it covers is not impossible — a
  /// backfilled message can land behind a read marker that was recorded before
  /// it arrived, and two devices' clocks need not agree — so the anchor is the
  /// later of the two. Without that, a message could be born expired and
  /// vanish in the same sweep that first saw it.
  DateTime? expiryFor({required DateTime sentAt, DateTime? readAt}) {
    if (!isActive) return null;
    switch (anchor) {
      case RetentionAnchor.arrival:
        return sentAt.add(after);
      case RetentionAnchor.read:
        if (readAt == null) return null;
        final anchoredAt = readAt.isAfter(sentAt) ? readAt : sentAt;
        return anchoredAt.add(after);
    }
  }

  /// Whether a message is due for deletion at [now].
  ///
  /// Inclusive of the expiry instant itself, which only matters to a test with
  /// a frozen clock — but a test that had to add a millisecond to see a
  /// deletion would be describing an off-by-one rather than the rule.
  bool hasExpired({
    required DateTime now,
    required DateTime sentAt,
    DateTime? readAt,
  }) {
    final due = expiryFor(sentAt: sentAt, readAt: readAt);
    return due != null && !due.isAfter(now);
  }

  Map<String, Object?> toJson() => {
    'seconds': after.inSeconds,
    'anchor': anchor.id,
  };

  /// Reads a policy back, or null when the blob is not one.
  ///
  /// Lenient in the same way `NotificationPolicy.fromJson` is, and for the same
  /// reason — a blob written by a newer build must not take the rest of the
  /// settings down with it — with one deliberate asymmetry: anything
  /// unreadable degrades to *no deletion* rather than to a default duration.
  /// The failure mode of guessing wrong here is deleted messages, and there is
  /// no undo for those.
  static RetentionPolicy? fromJson(Object? json) {
    if (json is! Map) return null;
    final seconds = json['seconds'];
    if (seconds is! int || seconds < 0) return null;
    return RetentionPolicy(
      after: Duration(seconds: seconds),
      anchor: RetentionAnchor.fromId(json['anchor'] as String?),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RetentionPolicy &&
      other.after == after &&
      // Two inactive policies are the same policy whatever anchor they carry:
      // an anchor that deletes nothing is not a difference the user can see,
      // and comparing it would make "off" unequal to "off".
      (!isActive || other.anchor == anchor);

  @override
  int get hashCode => Object.hash(after, isActive ? anchor : null);

  @override
  String toString() => isActive
      ? 'RetentionPolicy(${after.inMinutes}m from ${anchor.id})'
      : 'RetentionPolicy.off';
}

/// Every chat that self-deletes, and how.
///
/// One value written to one settings key rather than a row per chat, for the
/// reason `NotificationPolicy` gives about its own blob: the whole map is read
/// on every sweep and written whole by the picker, and a map that degrades
/// entry by entry keeps the chats a newer build's blob still describes.
///
/// Chats with no policy are simply absent — [forChat] answers [
/// RetentionPolicy.off] for them — so the common case, which is every chat,
/// costs nothing to store.
@immutable
class RetentionSettings {
  const RetentionSettings({this.byChat = const {}});

  static const RetentionSettings empty = RetentionSettings();

  final Map<String, RetentionPolicy> byChat;

  /// Whether any chat deletes anything. False lets the sweeper return before it
  /// touches the database at all, which is the state almost every install is in.
  bool get isDormant => byChat.values.none((policy) => policy.isActive);

  RetentionPolicy forChat(String chatId) =>
      byChat[chatId] ?? RetentionPolicy.off;

  /// This map with [chatId] set to [policy], or with the entry dropped when the
  /// policy does nothing — so turning retention off leaves no trace behind.
  RetentionSettings withChat(String chatId, RetentionPolicy policy) {
    final next = Map<String, RetentionPolicy>.of(byChat);
    if (policy.isActive) {
      next[chatId] = policy;
    } else {
      next.remove(chatId);
    }
    return RetentionSettings(byChat: Map.unmodifiable(next));
  }

  Map<String, Object?> toJson() => {
    'chats': {
      for (final entry in byChat.entries)
        if (entry.value.isActive) entry.key: entry.value.toJson(),
    },
  };

  static RetentionSettings fromJson(Object? json) {
    if (json is! Map) return empty;
    final chats = json['chats'];
    if (chats is! Map) return empty;
    final out = <String, RetentionPolicy>{};
    for (final entry in chats.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final policy = RetentionPolicy.fromJson(entry.value);
      if (policy != null && policy.isActive) out[key] = policy;
    }
    return RetentionSettings(byChat: Map.unmodifiable(out));
  }

  @override
  bool operator ==(Object other) =>
      other is RetentionSettings && _equality.equals(other.byChat, byChat);

  @override
  int get hashCode => _equality.hash(byChat);

  static const MapEquality<String, RetentionPolicy> _equality = MapEquality();
}
