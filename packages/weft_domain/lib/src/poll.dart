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
    this.ownVotes = const {},
    this.ended = false,
    this.maxSelections = 1,
  });

  final String question;
  final List<PollOption> options;

  /// Option id → vote count, from the latest response per voter.
  final Map<String, int> votes;

  /// The local user's current selection.
  final Set<String> ownVotes;

  /// A closed poll shows results only; taps do nothing.
  final bool ended;

  final int maxSelections;

  int get totalVotes => votes.values.fold(0, (sum, v) => sum + v);
}
