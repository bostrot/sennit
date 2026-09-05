import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'rule.dart';

/// Why a message produced no auto-reply.
///
/// Every value is a rule someone can reason about, for the same reason
/// `NotificationSuppression` names its cases rather than returning a bare
/// bool: when a user asks why their holiday responder stayed quiet, the reason
/// *is* the diagnosis, and it is what the dry-run preview shows them.
enum AutoReplyRefusal {
  /// The user sent it. Answering your own message is the shortest loop there
  /// is.
  ownMessage,

  /// The event was redacted; there is nothing left to answer.
  redacted,

  /// A state or call event rather than something a person said.
  nonMessageEvent,

  /// The incoming message is itself an auto-reply — [WeftMessage.isAutoReply],
  /// read from the sender's `com.bostrot.weft.auto_reply` key. Matrix-native
  /// only: the key survives no bridge, which is why the cap below exists.
  autoReplyEcho,

  /// Nothing to answer: an empty body and no transcript. A photo with no
  /// caption lands here, and that is deliberate — a model handed no words
  /// invents some.
  emptyMessage,

  /// The conversation is a pending chat request from someone the user has not
  /// answered. **Never** auto-replied to: the whole promise of holding a
  /// stranger's message is that they learn nothing, and a machine-written
  /// answer tells them the handle is live, is read, and is worth trying again.
  pendingRequest,

  /// A bridge's management room. Its bot parses what it is sent, and a model
  /// improvising at it is how a bridge gets logged out.
  serviceChat,

  /// A status / broadcast conversation. Nobody is being spoken to.
  broadcast,

  /// No enabled rule with a prompt covers this conversation.
  noRuleMatched,

  /// A rule covers it, but none of the matching rules is inside its window.
  outsideSchedule,

  /// [kAutoReplyMaxPerConversation] have already gone out in this conversation
  /// within [kAutoReplyCapWindow]. The loop guard, and the only one that needs
  /// no cooperation from whoever is on the other end.
  conversationCap,

  /// The winning rule's cooldown has not elapsed since the last auto-reply
  /// here.
  cooling,
}

/// What [shouldReply] decided.
@immutable
sealed class AutoReplyDecision {
  const AutoReplyDecision();

  /// The rule that will answer, or null when nothing will.
  AutoReplyRule? get rule => null;

  /// Why nothing will be sent, or null when something will.
  AutoReplyRefusal? get refusal => null;

  bool get willReply => rule != null;
}

/// Nothing is sent, and [reason] is why.
@immutable
final class AutoReplyRefused extends AutoReplyDecision {
  const AutoReplyRefused(this.reason);

  final AutoReplyRefusal reason;

  @override
  AutoReplyRefusal? get refusal => reason;

  @override
  bool operator ==(Object other) =>
      other is AutoReplyRefused && other.reason == reason;

  @override
  int get hashCode => Object.hash(AutoReplyRefused, reason);

  @override
  String toString() => 'AutoReplyRefused(${reason.name})';
}

/// [rule] wins and its prompt should be run.
@immutable
final class AutoReplyPlanned extends AutoReplyDecision {
  const AutoReplyPlanned(this.winner);

  final AutoReplyRule winner;

  @override
  AutoReplyRule? get rule => winner;

  @override
  bool operator ==(Object other) =>
      other is AutoReplyPlanned && other.winner == winner;

  @override
  int get hashCode => Object.hash(AutoReplyPlanned, winner);

  @override
  String toString() => 'AutoReplyPlanned(${winner.id})';
}

/// One auto-reply that has already been sent, as the ledger remembers it.
@immutable
class AutoReplySent {
  const AutoReplySent({required this.ruleId, required this.at, this.eventId});

  final String ruleId;
  final DateTime at;

  /// The event the reply became, when the send reported one. Null for a reply
  /// whose transport does not hand back an id — SMS — and for one recorded
  /// before the homeserver answered.
  final String? eventId;

  @override
  bool operator ==(Object other) =>
      other is AutoReplySent &&
      other.ruleId == ruleId &&
      other.at == at &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(ruleId, at, eventId);

  @override
  String toString() => 'AutoReplySent($ruleId at ${at.toIso8601String()})';
}

/// Everything about a conversation the engine needs and cannot look up.
///
/// The same discipline `evaluateNotification` follows: every fact that lives
/// somewhere else is passed in, so this package never re-derives an answer the
/// app has already given. [labels] are app settings, [isServiceChat] is the
/// repository's bridge-room fold, and [recentReplies] is the ledger — none of
/// the three is reachable from a `Chat`.
@immutable
class AutoReplyChatState {
  const AutoReplyChatState({
    required this.chat,
    this.labels = const {},
    this.isServiceChat = false,
    this.isBroadcast = false,
    this.recentReplies = const [],
  });

  final Chat chat;

  /// What the user has filed this conversation under, from `ChatLabels`.
  final Set<String> labels;

  /// A room that exists to operate a bridge, from
  /// `ChatRepository.serviceChatIds`.
  final bool isServiceChat;

  /// A status / broadcast conversation, from `isStatusBroadcastChat`.
  final bool isBroadcast;

  /// Auto-replies already sent in this conversation, newest last.
  final List<AutoReplySent> recentReplies;
}

/// Whether [message] should be auto-replied to, and by which rule.
///
/// The `shouldReply(message, chatState, rules, now)` of the design, with named
/// parameters because everything else in this codebase takes them and because
/// four positional arguments of which two are collections is a call site nobody
/// can read.
///
/// **Order matters.** The guards that cannot be argued with come first, then
/// rule selection, then the ledger. The first refusal wins and is reported as
/// *the* reason, so a stranger's message inside a rule's window reads as
/// [AutoReplyRefusal.pendingRequest] — the fact that decides it — rather than
/// as whatever a later check would have said.
///
/// The four guards at the top are the ones the phase brief calls out, and none
/// of them is a setting:
///
/// - **Never a chat-start request from an unknown sender.** A reply is proof
///   the handle is live and read. See [AutoReplyRefusal.pendingRequest].
/// - **Never the user's own message.** [WeftMessage.isOwn] is the primary
///   witness; [ownUserIds] catches the case where the mapper had no own-user id
///   to compare against, which is every background isolate.
/// - **Never another auto-reply.** [WeftMessage.isAutoReply], set from the
///   sender's `com.bostrot.weft.auto_reply` key.
/// - **Never more than [kAutoReplyMaxPerConversation] per
///   [kAutoReplyCapWindow].** Under every rule, unreachable from the UI.
///
/// [now] is a parameter rather than a `clock.now()` inside, so the schedule
/// boundaries and the cooldown expiry are testable at the exact minute they
/// turn over.
AutoReplyDecision shouldReply({
  required WeftMessage message,
  required AutoReplyChatState chat,
  required List<AutoReplyRule> rules,
  required DateTime now,
  Set<String> ownUserIds = const {},
}) {
  if (message.isOwn || ownUserIds.contains(message.senderId)) {
    return const AutoReplyRefused(AutoReplyRefusal.ownMessage);
  }
  if (message.redacted) {
    return const AutoReplyRefused(AutoReplyRefusal.redacted);
  }
  if (message.kind == MessageKind.event) {
    return const AutoReplyRefused(AutoReplyRefusal.nonMessageEvent);
  }
  if (message.isAutoReply) {
    return const AutoReplyRefused(AutoReplyRefusal.autoReplyEcho);
  }
  if (message.searchableText.trim().isEmpty) {
    return const AutoReplyRefused(AutoReplyRefusal.emptyMessage);
  }
  if (chat.chat.isPendingRequest) {
    return const AutoReplyRefused(AutoReplyRefusal.pendingRequest);
  }
  if (chat.isServiceChat) {
    return const AutoReplyRefused(AutoReplyRefusal.serviceChat);
  }
  if (chat.isBroadcast) {
    return const AutoReplyRefused(AutoReplyRefusal.broadcast);
  }

  // Audience first, window second, and the split is what makes an out-of-hours
  // rule fall through to a wider one that *is* open rather than shadowing it.
  final covering = [
    for (final rule in rules)
      if (rule.isUsable &&
          rule.audience.matches(
            chat: chat.chat,
            labels: chat.labels,
            network: message.network,
          ))
        rule,
  ];
  if (covering.isEmpty) {
    return const AutoReplyRefused(AutoReplyRefusal.noRuleMatched);
  }

  final open = [
    for (final rule in covering)
      if (rule.window?.isActiveAt(now) ?? true) rule,
  ];
  if (open.isEmpty) {
    return const AutoReplyRefused(AutoReplyRefusal.outsideSchedule);
  }

  final winner = pickAutoReplyRule(open);

  // Before the cooldown, because the cap is the anti-loop guard and deserves to
  // be named as such when it fires. A conversation that has hit it is not
  // "waiting a while"; it is being stopped.
  final inWindow = autoRepliesSince(
    chat.recentReplies,
    now.subtract(kAutoReplyCapWindow),
  );
  if (inWindow.length >= kAutoReplyMaxPerConversation) {
    return const AutoReplyRefused(AutoReplyRefusal.conversationCap);
  }

  final last = newestAutoReply(chat.recentReplies);
  if (last != null && now.difference(last.at) < winner.cooldown) {
    return const AutoReplyRefused(AutoReplyRefusal.cooling);
  }

  return AutoReplyPlanned(winner);
}

/// Which of several matching rules answers.
///
/// Most specific audience first — see [autoReplyAudiencePrecedence] — and, when
/// two rules are equally specific, the one earlier in the list. The list is the
/// user's own order on the settings screen, so "the first one I wrote wins" is
/// a rule they can see and rearrange rather than an accident of a hash.
///
/// Deliberately total: [open] is never empty at the one call site, and a stable
/// sort means the same inputs always pick the same rule, which is what makes
/// the precedence testable at all.
AutoReplyRule pickAutoReplyRule(List<AutoReplyRule> open) {
  var best = 0;
  for (var i = 1; i < open.length; i++) {
    final challenger = autoReplyAudiencePrecedence(open[i].audience);
    if (challenger > autoReplyAudiencePrecedence(open[best].audience)) {
      best = i;
    }
  }
  return open[best];
}

/// The entries at or after [since], oldest first.
List<AutoReplySent> autoRepliesSince(
  List<AutoReplySent> replies,
  DateTime since,
) => [
  for (final reply in replies)
    if (!reply.at.isBefore(since)) reply,
];

/// The most recent entry, or null. Does not assume [replies] is sorted — the
/// ledger keeps it that way, and a function that quietly depended on it would
/// break the first time something appended out of order.
AutoReplySent? newestAutoReply(List<AutoReplySent> replies) {
  AutoReplySent? newest;
  for (final reply in replies) {
    if (newest == null || reply.at.isAfter(newest.at)) newest = reply;
  }
  return newest;
}

/// What has been auto-replied to, per conversation.
///
/// Held rather than derived, because the alternative is scanning every
/// conversation's timeline for the auto-reply marker on every incoming message
/// — and that answer would be wrong anyway on a bridged leg, where the marker
/// does not survive the round trip.
///
/// Bounded twice over: entries older than [kAutoReplyCapWindow] are dropped on
/// every write, and a conversation that never comes up again is forgotten when
/// its last entry expires. Nothing here grows with the size of the account.
class AutoReplyLedger {
  AutoReplyLedger({this.retention = kAutoReplyCapWindow});

  /// How long an entry is kept. Never shorter than the cap window, or the cap
  /// could be defeated by waiting for the ledger to forget.
  final Duration retention;

  final Map<String, List<AutoReplySent>> _byChat = {};

  /// Auto-replies in [chatId] still inside [retention] at [now], oldest first.
  List<AutoReplySent> repliesIn(String chatId, {required DateTime now}) {
    final kept = autoRepliesSince(
      _byChat[chatId] ?? const [],
      now.subtract(retention),
    );
    return List.unmodifiable(kept);
  }

  /// Records a reply and prunes what has expired.
  ///
  /// Pruning on write rather than on a timer: the only thing that makes a
  /// ledger grow is writes, so the only place it needs to shrink is here.
  void record(String chatId, AutoReplySent sent) {
    final kept = autoRepliesSince(
      _byChat[chatId] ?? const [],
      sent.at.subtract(retention),
    );
    _byChat[chatId] = [...kept, sent];
  }

  /// Drops everything expired at [now], including conversations left empty.
  void prune(DateTime now) {
    final cutoff = now.subtract(retention);
    _byChat.removeWhere((_, replies) {
      final kept = autoRepliesSince(replies, cutoff);
      if (kept.isEmpty) return true;
      replies
        ..clear()
        ..addAll(kept);
      return false;
    });
  }

  void clear() => _byChat.clear();

  /// Conversations with at least one live entry. For tests and diagnostics.
  @visibleForTesting
  int get conversationCount => _byChat.length;
}
