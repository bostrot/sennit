/// A conversation started by someone the user has never talked to.
///
/// Every messenger has this and calls it something different — a message
/// request, a message from a stranger, an invite. What they agree on is the
/// shape: the conversation is *held* rather than delivered, the sender is told
/// nothing, and the user answers before anything else happens.
///
/// Sennit's version has to work across three quite different plumbings. A Matrix
/// invite is a room with `membership: invite` and nothing in it. A bridged chat
/// arrives in a room the bridge has already joined for you, so there is nothing
/// to accept — what makes it a request is that the sender is a stranger. An SMS
/// from an unknown number has no room at all. The state machine below is the
/// same for all three; what differs is [ChatRequestPlan], which says what the
/// verb actually *does* on a given network.
library;

import 'package:meta/meta.dart';

import 'network.dart';

/// Where a conversation stands with a user who has not answered it yet.
///
/// Null on a [Chat], rather than a `none` member here, is what says "an ordinary
/// conversation". A value that had to be checked against `none` everywhere would
/// make the request path the default case and the ordinary path the exception,
/// which is backwards — requests are rare.
enum ChatRequestState {
  /// Waiting for the user. Held out of the inbox proper, notified quietly, and
  /// — the part that matters to the person on the other end — read without
  /// sending a receipt.
  pending,

  /// The user said yes. The conversation is an ordinary one from here on; the
  /// state is kept only long enough for the inbox to move the row.
  accepted,

  /// The user said no. The room is left and the conversation is gone from the
  /// inbox, but the sender is not blocked and can start another.
  declined,

  /// The user said no and does not want to be asked again.
  blocked,
}

/// What the user can do about a pending request.
enum ChatRequestAction { accept, decline, block }

/// Applies [action] to [state].
///
/// Total, and the terminal states really are terminal: accepting a request that
/// was already declined does not un-decline it, because the room has been left
/// and the thing being accepted no longer exists. A UI that offers the buttons
/// on a settled request is the bug this refuses to paper over — it returns the
/// state unchanged rather than inventing a transition that cannot be performed.
ChatRequestState applyChatRequestAction(
  ChatRequestState state,
  ChatRequestAction action,
) {
  if (state != ChatRequestState.pending) return state;
  return switch (action) {
    ChatRequestAction.accept => ChatRequestState.accepted,
    ChatRequestAction.decline => ChatRequestState.declined,
    ChatRequestAction.block => ChatRequestState.blocked,
  };
}

/// Whether a conversation in [state] should still be held out of the inbox.
bool isPendingRequest(ChatRequestState? state) =>
    state == ChatRequestState.pending;

/// What answering a request actually does on one network.
///
/// A value rather than a branch inside the repository, because the interesting
/// part is what is *absent*: [markRead] is false on every plan there is, and
/// stating it is what makes "declining must not tell them you read it" a thing
/// a test can assert rather than a rule someone remembers.
@immutable
class ChatRequestPlan {
  const ChatRequestPlan({
    this.join = false,
    this.leave = false,
    this.ignoreSender = false,
  });

  /// Join the room. Only meaningful where there is an invite to accept: a
  /// bridged chat arrives in a room the bridge already joined for you, and SMS
  /// has no room at all.
  final bool join;

  /// Leave the room. What declining means on Matrix, and what makes the
  /// conversation actually go away rather than merely being hidden.
  final bool leave;

  /// Add the sender to the ignore list. Blocking, and only blocking.
  final bool ignoreSender;

  /// Always false, on every plan.
  ///
  /// A read receipt is the one thing a request must never send. The whole
  /// promise of holding a stranger's message is that they learn nothing: not
  /// that it was delivered, not that it was opened, and not that it was
  /// refused. A receipt sent on decline tells them the message was read by a
  /// person who then chose not to answer, which is strictly more than they knew
  /// before — and it is exactly what a naive "mark read on open" does.
  ///
  /// Stated as a field rather than left implicit so that the rule has somewhere
  /// to be asserted, and so that a future plan that wanted to set it has to say
  /// so out loud.
  bool get markRead => false;

  @override
  bool operator ==(Object other) =>
      other is ChatRequestPlan &&
      other.join == join &&
      other.leave == leave &&
      other.ignoreSender == ignoreSender;

  @override
  int get hashCode => Object.hash(join, leave, ignoreSender);

  @override
  String toString() =>
      'ChatRequestPlan(join: $join, leave: $leave, '
      'ignoreSender: $ignoreSender)';
}

/// What [action] means for a request that arrived over [network].
///
/// Three shapes, and the difference between them is where the conversation
/// physically lives:
///
/// - **Matrix** — a real invite. Accepting joins the room; declining leaves it,
///   which is what tells the server the invite is answered.
/// - **A bridged network** — the bridge joined the room on the user's behalf
///   before Sennit ever saw it, so there is nothing to join. Accepting is purely
///   a local decision to stop holding the conversation. Declining still leaves
///   the room, because that is the only way to stop the bridge relaying into it.
/// - **SMS** — no room, no membership, nothing to join or leave. Accepting and
///   declining are local; blocking reaches the platform's own block list, which
///   is the only durable thing available.
ChatRequestPlan planChatRequest({
  required ChatRequestAction action,
  required ChatNetwork network,
}) {
  final hasRoom = network != ChatNetwork.sms;
  final hasInvite = network == ChatNetwork.matrix;

  return switch (action) {
    ChatRequestAction.accept => ChatRequestPlan(join: hasInvite),
    ChatRequestAction.decline => ChatRequestPlan(leave: hasRoom),
    ChatRequestAction.block => ChatRequestPlan(
      leave: hasRoom,
      ignoreSender: true,
    ),
  };
}

/// Whether a conversation is a request rather than an ordinary chat.
///
/// A pure predicate over four facts the repository can see, kept here so the
/// Matrix repository, the SMS repository and the demo one cannot answer it
/// three different ways — which is how a chat shows as a request in the inbox
/// and as a normal conversation in the shade.
///
/// [invited] is a real Matrix invite and settles it on its own. Everything else
/// is the bridged case, where the room was joined for the user before they saw
/// it: what makes *that* a request is that the sender is a stranger and the
/// user has never spoken there.
///
/// [everSentByUser] is the one that stops this from being a nuisance. A
/// conversation the user has replied in is not a request whatever else is true —
/// a contact deleted from the address book, a number that never had a name, a
/// group they were added to a year ago and have been talking in since. Without
/// it, turning the feature on would sweep a chunk of a real inbox into a
/// requests list overnight.
bool isChatRequest({
  required bool invited,
  required bool everSentByUser,
  required bool knownContact,
  bool isGroup = false,
}) {
  if (everSentByUser) return false;
  if (invited) return true;
  // A stranger who found the user on a bridged network. A group is treated the
  // same way: being added to a group by someone unknown is the same imposition
  // as being messaged by them, and worse, because a group can hold anyone.
  return !knownContact;
}
