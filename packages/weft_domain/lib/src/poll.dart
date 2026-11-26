import 'package:meta/meta.dart';

/// One choice in a poll.
@immutable
class PollOption {
  const PollOption({required this.id, required this.text});

  final String id;
  final String text;
}

/// A poll as the timeline has aggregated it: the question, the choices, and
/// where the votes currently stand.
///
/// Carried on a [MessageKind.poll] message rather than modelled as its own
/// timeline entity, because a poll *is* a message — it is ordered, replied to
/// and deleted like one, and only its content is richer.
@immutable
class PollData {
  const PollData({
    required this.question,
    required this.options,
    this.votes = const {},
    this.voters = const {},
    this.voterCount = 0,
    this.ownVotes = const {},
    this.ended = false,
    this.undisclosed = false,
    this.maxSelections = 1,
  });

  final String question;
  final List<PollOption> options;

  /// Option id → vote count, from the latest response per voter.
  final Map<String, int> votes;

  /// Option id → the names of the people whose latest response chose it.
  ///
  /// Empty where the source cannot say (a peer on an older Sennit, say); the
  /// counts in [votes] are what a reader can always rely on.
  final Map<String, List<String>> voters;

  /// How many people have a counted vote. Differs from [totalVotes] when
  /// people may pick more than one answer.
  final int voterCount;

  /// The local user's current selection.
  final Set<String> ownVotes;

  /// A closed poll shows results only; taps do nothing.
  final bool ended;

  /// MSC3381's undisclosed kind: nobody sees the tally until the poll ends.
  final bool undisclosed;

  final int maxSelections;

  int get totalVotes => votes.values.fold(0, (sum, v) => sum + v);

  /// Whether more than one answer may be picked.
  bool get multipleChoice => maxSelections > 1;

  /// Whether counts may be shown: always for a disclosed poll, and for an
  /// undisclosed one only once it has ended.
  bool get resultsVisible => !undisclosed || ended;

  /// The selection that tapping [optionId] leads to, or null when the tap
  /// changes nothing.
  ///
  /// Single choice replaces the vote (tapping the current answer keeps it).
  /// Multiple choice toggles, up to [maxSelections]; a tap past the limit is
  /// ignored rather than silently dropping an earlier pick.
  Set<String>? selectionAfterTap(String optionId) {
    if (!multipleChoice) {
      if (ownVotes.length == 1 && ownVotes.contains(optionId)) return null;
      return {optionId};
    }
    if (ownVotes.contains(optionId)) {
      return {...ownVotes}..remove(optionId);
    }
    if (ownVotes.length >= maxSelections) return null;
    return {...ownVotes, optionId};
  }
}

/// What a conversation can carry when the user starts a poll there.
///
/// Read from what the bridge declares about the room (its bridge room
/// features): a bridge that cannot carry polls would take
/// the event and the other side would never see it, so the composer is
/// withheld rather than offered. A plain Matrix room carries everything.
@immutable
class PollSupport {
  const PollSupport({
    this.available = true,
    this.maxOptions = maxAnswers,
    this.optionMaxLength = 0,
    this.multipleChoiceOnly = false,
    this.undisclosed = true,
    this.canEnd = true,
    this.uniqueOptions = false,
  });

  /// Nothing to offer: no poll composer, no "end poll".
  const PollSupport.unavailable()
    : available = false,
      maxOptions = 0,
      optionMaxLength = 0,
      multipleChoiceOnly = false,
      undisclosed = false,
      canEnd = false,
      uniqueOptions = false;

  /// The most answers the composer offers anywhere.
  static const int maxAnswers = 20;

  /// The fewest answers a poll can have.
  static const int minAnswers = 2;

  final bool available;

  /// At most this many answers, already capped at [maxAnswers].
  final int maxOptions;

  /// Longest answer the network takes, in characters; 0 for no limit.
  final int optionMaxLength;

  /// The network only has polls where everyone may pick several answers
  /// (Messenger and Instagram).
  final bool multipleChoiceOnly;

  /// Whether results can stay hidden until the poll ends.
  final bool undisclosed;

  /// Whether ending a poll reaches the other side.
  final bool canEnd;

  /// The network refuses two answers with the same text.
  final bool uniqueOptions;
}
