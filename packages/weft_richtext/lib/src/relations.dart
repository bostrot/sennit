import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// A single `m.annotation`, as it arrived off one source room's timeline.
///
/// Reactions never pass through the message mapper — `mapEvent` filters to
/// `m.room.message` and friends and returns null for everything else — so they
/// reach this layer as their own list rather than as fields on a [WeftMessage].
@immutable
class ReactionEvent {
  const ReactionEvent({
    required this.eventId,
    required this.roomId,
    required this.senderId,
    required this.targetEventId,
    required this.key,
    required this.timestamp,
  });

  /// The annotation event itself. Kept because un-reacting is a redaction of
  /// this id, not of the message it points at.
  final String eventId;

  /// The source room the annotation lives in. In a merged chat this identifies
  /// which leg the reaction came in on, and it is the room a redaction has to
  /// be sent to.
  final String roomId;

  /// The sender as the homeserver saw them — for a bridged reaction, the bridge
  /// ghost (`@whatsapp_49…:example.org`), not the human.
  final String senderId;

  final String targetEventId;

  /// `key` off `m.relates_to`. Usually an emoji, occasionally a short string,
  /// and normalised before it is tallied.
  final String key;

  final DateTime timestamp;

  @override
  String toString() =>
      'ReactionEvent($key by $senderId on $targetEventId in $roomId)';
}

/// A single `m.replace`, carrying the replacement body from `m.new_content`.
@immutable
class EditEvent {
  const EditEvent({
    required this.eventId,
    required this.roomId,
    required this.senderId,
    required this.targetEventId,
    required this.body,
    required this.timestamp,
    this.formattedBody,
  });

  final String eventId;
  final String roomId;
  final String senderId;
  final String targetEventId;

  /// The replacement body, already stripped of the `* ` fallback prefix that
  /// the spec has senders prepend for clients which do not understand edits.
  final String body;

  final String? formattedBody;

  /// The *replacement's* origin timestamp — when the edit was made, not when
  /// the original was sent. This is the number an "edited 14:02" indicator
  /// shows, and the mapper currently reads the original's timestamp instead.
  final DateTime timestamp;

  @override
  String toString() => 'EditEvent($eventId replaces $targetEventId)';
}

/// Collapses a sender id to whatever identifies the *person* behind it.
///
/// Given a sender id as it arrived — a bridge ghost, a native Matrix id — this
/// returns a stable key that is equal for two handles the user has merged into
/// one contact, and distinct otherwise. In practice the app wires this to
/// `IdentityGraph.contactIdOf`, resolved from the ghost's `matrixUserId`.
///
/// A function rather than an interface, and taken as a parameter rather than
/// constructed here, because `weft_richtext` must not depend on `weft_merge`:
/// the aggregation is a pure fold over events and the identity question belongs
/// to whoever owns the graph.
///
/// Two rules for implementors. Return the input unchanged when the sender is
/// unknown — an unrecognised ghost is a person of their own, not a collision
/// waiting to happen. And resolve only through *recorded* merge decisions:
/// heuristics like `networkFromUserId` guess from the shape of an id, and two
/// ghosts that merely look alike are not one person. A wrong merge here does
/// not show a bad suggestion, it silently deletes someone's reaction.
typedef MergedIdentityResolver = String Function(String senderId);

/// The resolver for a conversation with nothing merged: every sender is their
/// own person. The correct default for an unmerged chat, and what tests use
/// when identity is not what they are testing.
String senderIsIdentity(String senderId) => senderId;

/// Codepoints that spell the same reaction two ways.
///
/// U+FE0E/U+FE0F choose the text or emoji presentation of the preceding
/// character, and U+1F3FB–U+1F3FF are the skin-tone modifiers. Neither changes
/// which reaction was meant, but both change the string: `👍` and `👍️` are
/// different bytes and would tally as two chips saying the same thing.
///
/// Zero-width joiners are deliberately *not* stripped. A ZWJ sequence is a
/// different emoji, not a decorated one — flattening `👨‍👩‍👧` into `👨` would
/// merge two reactions that genuinely differ.
final RegExp _reactionNoise = RegExp(
  r'[\u{FE0E}\u{FE0F}\u{1F3FB}-\u{1F3FF}]',
  unicode: true,
);

/// Normalises a reaction key so equivalent spellings tally together.
///
/// Surrounding whitespace goes (bridges pad keys often enough to matter), then
/// variation selectors and skin-tone modifiers. A key made of nothing but those
/// is returned as it arrived rather than as the empty string: it is a reaction
/// this code does not understand, and dropping it would be worse than showing
/// it.
String normaliseReactionKey(String key) {
  final trimmed = key.trim();
  final stripped = trimmed.replaceAll(_reactionNoise, '');
  return stripped.isEmpty ? trimmed : stripped;
}

/// Groups annotations into per-key tallies, one entry per *person*.
///
/// The failure this prevents. A merged conversation is several source rooms
/// shown as one, and the same human reaches it down more than one of them.
/// Anna thumbs-ups a message on WhatsApp, the bridge echoes the conversation
/// into Signal, and she thumbs-ups it again there. That is two `m.annotation`
/// events, in two rooms, from two different bridge ghosts, carrying the same
/// key — and a tally that counts events renders `👍 2` for one person pressing
/// one button twice. Worse, the local user's own double reaction renders as
/// two, and a single un-react then appears to do nothing because the other
/// leg's annotation is still standing. So senders are collapsed through
/// [resolveSender] first and counted afterwards.
///
/// [localUserId] is resolved through the same function, so the local user's
/// reaction is recognised on whichever leg it was sent from.
///
/// [events] are the annotations for *one* message. This function does not read
/// [ReactionEvent.targetEventId] — the caller has already grouped by it, and a
/// caller that hands over a whole room's annotations gets one bar carrying every
/// reaction in the conversation.
///
/// Ordering is by first reaction — the earliest annotation carrying each key,
/// with event id as tie-break — and never by count. A bar sorted by count
/// reorders itself while the reader is looking at it, and moves the chip out
/// from under a thumb already travelling towards it.
List<ReactionTally> aggregateReactions({
  required List<ReactionEvent> events,
  required MergedIdentityResolver resolveSender,
  String? localUserId,
}) {
  if (events.isEmpty) return const [];

  final localIdentity = localUserId == null ? null : resolveSender(localUserId);

  // Sort before folding rather than after: "first reaction" has to mean first
  // by timestamp, not first in whatever order the SDK handed the events over,
  // and the same input in a different order must produce the same bar.
  final ordered = [...events]
    ..sort(
      (a, b) =>
          _compareRelation(a.timestamp, a.eventId, b.timestamp, b.eventId),
    );

  final accumulators = <String, _TallyBuilder>{};
  for (final event in ordered) {
    final key = normaliseReactionKey(event.key);
    if (key.isEmpty) continue;

    final identity = resolveSender(event.senderId);
    final builder = accumulators.putIfAbsent(
      key,
      () => _TallyBuilder(
        key: key,
        firstReactedAt: event.timestamp,
        firstEventId: event.eventId,
      ),
    );

    // Second event from the same person — the other leg of a merged chat, or a
    // duplicate the timeline replayed. Either way they reacted once.
    if (!builder.identities.add(identity)) continue;
    builder.senderIds.add(event.senderId);
    if (identity == localIdentity) {
      builder.byLocalUser = true;
      builder.localEventId = event.eventId;
    }
  }

  final builders = accumulators.values.toList()
    ..sort(
      (a, b) => _compareRelation(
        a.firstReactedAt,
        a.firstEventId,
        b.firstReactedAt,
        b.firstEventId,
      ),
    );

  return builders
      .map(
        (b) => ReactionTally(
          key: b.key,
          senderIds: List.unmodifiable(b.senderIds),
          firstReactedAt: b.firstReactedAt,
          byLocalUser: b.byLocalUser,
          localEventId: b.localEventId,
        ),
      )
      .toList(growable: false);
}

class _TallyBuilder {
  _TallyBuilder({
    required this.key,
    required this.firstReactedAt,
    required this.firstEventId,
  });

  final String key;
  final DateTime firstReactedAt;
  final String firstEventId;
  final Set<String> identities = {};
  final List<String> senderIds = [];
  bool byLocalUser = false;
  String? localEventId;
}

/// What [applyEdits] worked out: the message as it now reads, and how it got
/// there.
///
/// A result type rather than a mutated [WeftMessage] because the history has
/// nowhere to live on the message yet — `WeftMessage.editHistory` is added in
/// the mapping task, and until then [message] is the part that fits through
/// today's `copyWith` and [history] is the part the history sheet will read.
@immutable
class EditResolution {
  const EditResolution({
    required this.message,
    required this.history,
    required this.rejected,
  });

  /// The message with the winning body and the *edit's* timestamp as
  /// `editedAt`.
  final WeftMessage message;

  /// Every version oldest first, the original included, ending with the version
  /// [message] now shows. Empty when no edit applied, which is how "never
  /// edited" is told apart from "edited back to what it said".
  final List<EditRecord> history;

  /// Edits that were not applied: wrong sender, or aimed at another event.
  /// Surfaced rather than swallowed so a mapper can log a bridge that is
  /// attributing edits incorrectly instead of quietly losing them.
  final List<EditEvent> rejected;

  bool get wasEdited => history.isNotEmpty;

  @override
  String toString() =>
      'EditResolution(${message.eventId}, ${history.length} versions, '
      '${rejected.length} rejected)';
}

/// Applies `m.replace` events to [original], last write wins.
///
/// Ordering is by origin timestamp with event id as tie-break, and the tie-break
/// is not decoration: two clients editing within the same millisecond is rare,
/// but two *homeservers* stamping the same millisecond is not, and without a
/// total order two readers of the same room would see different text.
///
/// An edit from anyone other than the original sender is rejected. Matrix's
/// `m.replace` is only meaningful from the original sender, and a room where
/// anyone can rewrite anyone's words is a room where a screenshot means
/// nothing — the homeserver does not enforce this for us, so the client must.
///
/// The winning version's `formatted_body` replaces the original's, null
/// included — an edit is a whole new content block, not a patch, so a
/// replacement sent as plain text leaves a message with no formatting rather
/// than one wearing its previous markup.
///
/// This does not double-apply. When the SDK has already resolved edits into
/// `event.body` the winning body simply equals the body already there; what is
/// gained is the [EditResolution.history] the sheet needs and a correct
/// `editedAt`. The one caveat is that history can only contain what it is
/// given: pass the *unedited* original if the first entry is to show the words
/// that were actually replaced.
EditResolution applyEdits(List<EditEvent> edits, WeftMessage original) {
  final accepted = <EditEvent>[];
  final rejected = <EditEvent>[];
  final seen = <String>{};

  for (final edit in edits) {
    if (edit.targetEventId != original.eventId ||
        edit.senderId != original.senderId) {
      rejected.add(edit);
      continue;
    }
    // A timeline can hand the same replacement over twice across a pagination
    // boundary; the second copy is not a second version.
    if (!seen.add(edit.eventId)) continue;
    accepted.add(edit);
  }

  if (accepted.isEmpty) {
    return EditResolution(
      message: original,
      history: const [],
      rejected: List.unmodifiable(rejected),
    );
  }

  accepted.sort(
    (a, b) => _compareRelation(a.timestamp, a.eventId, b.timestamp, b.eventId),
  );
  final winner = accepted.last;

  final history = <EditRecord>[
    EditRecord(
      eventId: original.eventId,
      body: original.body,
      timestamp: original.timestamp,
    ),
    for (final edit in accepted)
      EditRecord(
        eventId: edit.eventId,
        body: edit.body,
        formattedBody: edit.formattedBody,
        timestamp: edit.timestamp,
      ),
  ];

  return EditResolution(
    message: original.copyWith(
      body: winner.body,
      // Explicitly the winner's, null included: an edit that drops formatting
      // has to clear the old HTML, or the bubble renders the previous version's
      // markup wrapped around the new words.
      formattedBody: winner.formattedBody,
      editedAt: winner.timestamp,
    ),
    history: List.unmodifiable(history),
    rejected: List.unmodifiable(rejected),
  );
}

/// Default length of a reply chip's one-line preview.
const int kReplyPreviewLength = 120;

/// Finds what a reply was answering, across every source room of a merged chat.
///
/// [loaded] is the whole merged candidate set, not one room's messages. In a
/// merged conversation a reply sent on the Signal leg can answer a message that
/// only exists on the WhatsApp leg — the bridge relayed it — and searching the
/// reply's own room would resolve nothing and render a stub over a message that
/// is on screen two bubbles up. Matrix event ids are globally unique, so the
/// search is deliberately unscoped by room; the target's own `roomId` comes back
/// on the preview because that is where a tap has to scroll to.
///
/// Returns null only when there is nothing to resolve — the message is not a
/// reply. A reply whose target has not been paginated in yet resolves to
/// [ReplyPreview.stub], never to null: an answer with no visible question is a
/// worse lie than an answer above a greyed-out "message not loaded".
ReplyPreview? resolveReplyTarget({
  required String? replyToEventId,
  required Iterable<WeftMessage> loaded,
  int previewLength = kReplyPreviewLength,
}) {
  final targetId = replyToEventId?.trim();
  if (targetId == null || targetId.isEmpty) return null;

  for (final candidate in loaded) {
    if (candidate.eventId != targetId) continue;
    return ReplyPreview(
      eventId: candidate.eventId,
      roomId: candidate.roomId,
      senderId: candidate.senderId,
      senderName: candidate.senderName,
      kind: candidate.kind,
      network: candidate.network,
      body: replyPreviewText(candidate, maxLength: previewLength),
      redacted: candidate.redacted,
    );
  }
  return ReplyPreview.stub(targetId);
}

/// One line of a message, for a reply chip.
///
/// The target's own reply fallback goes first — quoting a reply must not quote
/// the quote it carried — then newlines collapse, because a chip is one line
/// and a body with three of them would otherwise push the bubble down the
/// screen.
String replyPreviewText(
  WeftMessage message, {
  int maxLength = kReplyPreviewLength,
}) {
  if (message.redacted) return '';

  final collapsed = stripReplyFallback(
    message.body,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= maxLength) return collapsed;

  // By runes, so truncating never lands inside a surrogate pair and leaves a
  // lone half of an emoji in the chip.
  final runes = collapsed.runes.toList(growable: false);
  if (runes.length <= maxLength) return collapsed;
  return '${String.fromCharCodes(runes.take(maxLength)).trimRight()}…';
}

/// Longest a thread title taken from a root message's body may be.
///
/// The indicator is one line under a bubble that already carries the same words
/// in full, so this only has to be enough to tell forty topics apart.
const int kThreadTitleLength = 48;

/// Splits [messages] into the room-level timeline and the threads hanging off it.
///
/// [messages] is in whatever order the timeline hands over — newest first, for
/// a `MergedTimelineView` — and that order is preserved in
/// [ThreadGrouping.messages]. Nothing here sorts: re-sorting would silently
/// disagree with the merge's own watermark ordering, which is the only ordering
/// that is safe across sources.
///
/// **A reply whose root is not loaded stays in the flat timeline.** This is the
/// case that decides whether the feature loses messages or not. Scrolling back
/// through a forum group reaches thread replies long before it reaches the
/// topic roots they hang off, and taking those replies out of the flat list on
/// the strength of a relation to an event nobody can see would hide them behind
/// an indicator that does not exist. They are shown where they are until their
/// root arrives, at which point the next grouping folds them in.
///
/// [readUpTo] is the timestamp of the last message the user has read in this
/// room, and everything newer than it counts as unread. Null means "no read
/// marker yet", which is treated as *nothing* unread rather than everything: a
/// freshly-opened chat whose receipt has not synced would otherwise light up
/// every topic at once, which is indistinguishable from noise.
///
/// [titleFor] overrides how a thread is named. The default is
/// [threadTitleFromRoot] with the bridge's announced name preferred over it —
/// see [ThreadSummary.title] — and takes the replies as well as the root,
/// because the bridges disagree about which event carries a Telegram forum
/// topic's name.
ThreadGrouping groupThreads({
  required Iterable<WeftMessage> messages,
  DateTime? readUpTo,
  String? Function(WeftMessage root, List<WeftMessage> replies)? titleFor,
  bool Function(WeftMessage message)? isOwn,
}) {
  final flat = <WeftMessage>[];
  final repliesByRoot = <String, List<WeftMessage>>{};

  for (final message in messages) {
    final root = message.threadRootId;
    if (root == null || root.isEmpty) {
      flat.add(message);
    } else {
      repliesByRoot.putIfAbsent(root, () => []).add(message);
    }
  }

  if (repliesByRoot.isEmpty) return ThreadGrouping.flatten(flat);

  final roots = <String, WeftMessage>{
    for (final message in flat) message.eventId: message,
  };

  final summaries = <String, ThreadSummary>{};
  for (final entry in repliesByRoot.entries) {
    final root = roots[entry.key];
    if (root == null) continue;

    final replies = entry.value;
    WeftMessage? latest;
    var unread = 0;
    for (final reply in replies) {
      if (latest == null ||
          _compareRelation(
                latest.timestamp,
                latest.eventId,
                reply.timestamp,
                reply.eventId,
              ) <
              0) {
        latest = reply;
      }
      // The user's own reply is never unread to them, whichever device it was
      // sent from — and in a thread the user is participating in, that is most
      // of the traffic.
      final own = isOwn?.call(reply) ?? reply.isOwn;
      if (!own && readUpTo != null && reply.timestamp.isAfter(readUpTo)) {
        unread++;
      }
    }

    summaries[root.eventId] = ThreadSummary(
      rootEventId: root.eventId,
      roomId: root.roomId,
      title: (titleFor ?? threadTitle)(root, replies),
      replyCount: replies.length,
      latestReply: latest,
      unreadCount: unread,
    );
  }

  // Replies whose root never turned up go back where they were, in the position
  // the timeline gave them. Rebuilt by a second walk rather than by inserting
  // into `flat` as we go, because "is this root loaded?" is not answerable until
  // the whole list has been seen.
  final orphaned = <WeftMessage>[
    for (final entry in repliesByRoot.entries)
      if (!summaries.containsKey(entry.key)) ...entry.value,
  ];
  if (orphaned.isEmpty) {
    return ThreadGrouping(
      messages: List.unmodifiable(flat),
      threads: Map.unmodifiable(summaries),
    );
  }

  final orphanedIds = {for (final message in orphaned) message.eventId};
  final restored = <WeftMessage>[
    for (final message in messages)
      if (message.threadRootId == null ||
          message.threadRootId!.isEmpty ||
          orphanedIds.contains(message.eventId))
        message,
  ];
  return ThreadGrouping(
    messages: List.unmodifiable(restored),
    threads: Map.unmodifiable(summaries),
  );
}

/// Every message belonging to one thread, root first, oldest to newest.
///
/// Read order rather than the timeline's newest-first, because a thread view is
/// read top to bottom from the message that started it — which is also why the
/// root is included: a thread opened without the thing it is about is a set of
/// answers to a missing question.
List<WeftMessage> threadMessages({
  required Iterable<WeftMessage> messages,
  required String rootEventId,
}) {
  final belonging = <WeftMessage>[
    for (final message in messages)
      if (message.eventId == rootEventId || message.threadRootId == rootEventId)
        message,
  ];
  belonging.sort(
    (a, b) => _compareRelation(a.timestamp, a.eventId, b.timestamp, b.eventId),
  );
  // The root leads whatever its timestamp says. A bridge that backfills a forum
  // topic can stamp the first reply at or before the root's own origin time,
  // and a thread that opens on an answer reads as though the question is
  // missing.
  final rootIndex = belonging.indexWhere((m) => m.eventId == rootEventId);
  if (rootIndex > 0) {
    final root = belonging.removeAt(rootIndex);
    belonging.insert(0, root);
  }
  return List.unmodifiable(belonging);
}

/// What to call a thread: the bridge's name for it, or the root's own words.
///
/// The announced name wins wherever it turns up, root or reply, because the
/// bridges disagree about which event carries it and a Telegram forum topic
/// called "Bugs" must not be labelled with the first thing anyone said in it.
/// Falls through to [threadTitleFromRoot] for a plain Matrix thread, which has
/// no name at all.
String? threadTitle(WeftMessage root, List<WeftMessage> replies) {
  var announced = root.threadName;
  if (announced == null) {
    for (final reply in replies) {
      if (reply.threadName != null) {
        announced = reply.threadName;
        break;
      }
    }
  }
  if (announced != null && announced.trim().isNotEmpty) {
    return announced.trim();
  }
  return threadTitleFromRoot(root);
}

/// A thread's name taken from the message it hangs off.
///
/// What a Matrix thread has instead of a name. Collapsed to one line and
/// truncated by runes, the same way a reply chip is, and empty for a root that
/// is all attachment — the indicator says "4 replies" on its own rather than
/// showing a blank title, which reads as a bug.
String? threadTitleFromRoot(
  WeftMessage root, {
  int maxLength = kThreadTitleLength,
}) {
  final text = replyPreviewText(root, maxLength: maxLength);
  return text.isEmpty ? null : text;
}

/// Total order for relation events: origin timestamp, then event id.
///
/// The tie-break is what makes it *total*. Two events sharing a millisecond is
/// ordinary, and an order that leaves them unranked means two clients folding
/// the same events can disagree about which one won.
int _compareRelation(DateTime aTime, String aId, DateTime bTime, String bId) {
  final byTime = aTime.compareTo(bTime);
  return byTime != 0 ? byTime : aId.compareTo(bId);
}
