/// Threads as the timeline sees them.
///
/// A thread is not a room and not a chat: it is a set of messages in one room
/// that hang off one other message in the same room, by `m.thread` relation.
/// Telegram forum topics arrive over the bridge in exactly this shape, which is
/// what makes the feature worth having at all — a forum group with forty topics
/// is otherwise forty conversations flattened into one unreadable stream.
///
/// Like everything else in `weft_domain`, this is the *noun*. The verb that
/// produces one — walking a timeline, grouping replies onto their roots,
/// counting what is unread — is `groupThreads` in `weft_richtext`, beside the
/// other relation aggregations.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'message.dart';
import 'network.dart';

/// Whether a network has anything to map a Matrix thread onto.
///
/// Only two of the bridged networks have a native concept: Telegram forum
/// topics and Discord/Slack threads. Everywhere else a thread is a Matrix-side
/// construct the remote network never sees, and the honest behaviour there is to
/// render the messages flat — see [ThreadGrouping.flatten].
///
/// Stated as a function over [ChatNetwork] rather than as a field on the enum
/// because it is a question about *bridge* behaviour, not about what a network
/// is, and the enum is shared with code that has no bridges in it at all.
bool networkSupportsThreads(ChatNetwork network) => switch (network) {
  ChatNetwork.matrix ||
  ChatNetwork.telegram ||
  ChatNetwork.discord ||
  ChatNetwork.slack ||
  ChatNetwork.mattermost => true,
  _ => false,
};

/// One thread, as a row in the flat timeline needs to know it.
///
/// Deliberately a summary and not the messages. The flat timeline draws an
/// indicator under the root — "4 replies · Anna: on the way" — and the replies
/// themselves are only loaded and rendered once the thread is opened. Carrying
/// them here would mean every root in a forty-topic group holds its whole
/// sub-conversation in memory to draw one line.
@immutable
class ThreadSummary {
  const ThreadSummary({
    required this.rootEventId,
    required this.roomId,
    required this.replyCount,
    this.title,
    this.latestReply,
    this.unreadCount = 0,
  });

  /// The message the thread hangs off. Always a real event in [roomId]: a
  /// summary is only ever built for a root that was actually found.
  final String rootEventId;

  final String roomId;

  /// The topic's name, when the bridge gave one.
  ///
  /// Telegram forum topics have real names — "Bugs", "Off-topic" — and losing
  /// them is losing the only thing that tells forty threads apart. Null where
  /// the bridge said nothing, which is every non-forum thread; the indicator
  /// then falls back to the root message's own words, which is what a Matrix
  /// thread has instead of a name.
  final String? title;

  /// How many replies hang off the root, not counting the root itself.
  final int replyCount;

  /// The newest reply, for the one line of preview under the root.
  final WeftMessage? latestReply;

  /// Replies the user has not read.
  ///
  /// Counted per thread rather than inherited from the room, because that is the
  /// whole point: in a forum group the room badge says "68" and answers nothing,
  /// while "Bugs has 3 new" is the thing the user actually acts on.
  final int unreadCount;

  bool get hasUnread => unreadCount > 0;

  @override
  bool operator ==(Object other) =>
      other is ThreadSummary &&
      other.rootEventId == rootEventId &&
      other.roomId == roomId &&
      other.title == title &&
      other.replyCount == replyCount &&
      other.latestReply == latestReply &&
      other.unreadCount == unreadCount;

  @override
  int get hashCode => Object.hash(
    rootEventId,
    roomId,
    title,
    replyCount,
    latestReply,
    unreadCount,
  );

  @override
  String toString() =>
      'ThreadSummary($rootEventId, "${title ?? ''}", '
      '$replyCount replies, $unreadCount unread)';
}

/// A timeline split into what the flat view shows and what the threads hold.
///
/// The two halves are produced together because they are two readings of one
/// pass: a message is either a room-level message or a thread reply, and the
/// summary under a root is built from the replies that were taken out of the
/// flat list. Deriving them separately is how the indicator ends up claiming
/// four replies over a list that shows three.
@immutable
class ThreadGrouping {
  const ThreadGrouping({required this.messages, required this.threads});

  /// A grouping that took nothing out — every message stays where it was.
  ///
  /// What a network with no thread concept gets, and the reason it is a named
  /// constructor rather than a caller's `if`: **degrading must not lose
  /// messages**. A Signal conversation whose events happen to carry an
  /// `m.thread` relation — because a Matrix user in the room threaded a reply —
  /// renders as one flat conversation with every message present, rather than
  /// as a timeline with an indicator nobody on Signal can open and replies
  /// nobody can see.
  ThreadGrouping.flatten(List<WeftMessage> messages)
    : messages = List.unmodifiable(messages),
      threads = const {};

  /// The room-level timeline: everything that is not a thread reply, in the
  /// order it came in.
  final List<WeftMessage> messages;

  /// Summaries by root event id. Only roots that are present in [messages] and
  /// actually have replies appear here.
  final Map<String, ThreadSummary> threads;

  /// The summary hanging off [message], or null when nothing does.
  ThreadSummary? threadFor(WeftMessage message) => threads[message.eventId];

  /// Threads with unread replies, newest activity first — what a "jump to the
  /// next unread topic" affordance reads.
  List<ThreadSummary> get unreadThreads {
    final unread = threads.values.where((t) => t.hasUnread).toList()
      ..sort((a, b) {
        final at = a.latestReply?.timestamp;
        final bt = b.latestReply?.timestamp;
        if (at == null || bt == null) return 0;
        return bt.compareTo(at);
      });
    return List.unmodifiable(unread);
  }

  @override
  bool operator ==(Object other) =>
      other is ThreadGrouping &&
      const ListEquality<WeftMessage>().equals(other.messages, messages) &&
      const MapEquality<String, ThreadSummary>().equals(other.threads, threads);

  @override
  int get hashCode => Object.hash(
    const ListEquality<WeftMessage>().hash(messages),
    const MapEquality<String, ThreadSummary>().hash(threads),
  );

  @override
  String toString() =>
      'ThreadGrouping(${messages.length} messages, ${threads.length} threads)';
}
