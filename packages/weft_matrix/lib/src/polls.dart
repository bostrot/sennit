import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// MSC3381 polls on the wire, and the rules for counting them.
///
/// Two generations of event types are in use. The mautrix bridges send and
/// accept only the unstable `org.matrix.msc3381.*` prefix, so that is what
/// Sennit sends; both are read, because a client on the stable spec sends
/// `m.poll.*`. WhatsApp and Signal by default deliver a poll as an ordinary
/// `m.room.message` with the poll block riding along — which is why
/// [pollStartBlock] looks at content, not at the event type.
const String kPollStartUnstable = 'org.matrix.msc3381.poll.start';
const String kPollStartStable = 'm.poll.start';
const String kPollResponseUnstable = 'org.matrix.msc3381.poll.response';
const String kPollResponseStable = 'm.poll.response';
const String kPollEndUnstable = 'org.matrix.msc3381.poll.end';
const String kPollEndStable = 'm.poll.end';

/// The bridge room features: the state event in which a mautrix bridge
/// declares what a room carries.
const String roomFeaturesStateType = 'com.beeper.room_features';

const String _kindUndisclosedUnstable = 'org.matrix.msc3381.poll.undisclosed';
const String _kindUndisclosedStable = 'm.poll.undisclosed';

bool isPollResponseType(String type) =>
    type == kPollResponseUnstable || type == kPollResponseStable;

bool isPollEndType(String type) =>
    type == kPollEndUnstable || type == kPollEndStable;

/// The poll definition in [content], normalised to one shape, or null when
/// the content carries no usable poll.
///
/// Unstable: `{org.matrix.msc3381.poll.start: {question: {org.matrix.msc1767
/// .text}, answers: [{id, org.matrix.msc1767.text}]}}`. Stable: `{m.poll:
/// {question: {m.text: [{body}]}, answers: [{m.id, m.text}]}}`.
PollStartBlock? pollStartBlock(Map<String, Object?> content) {
  final unstable = content[kPollStartUnstable];
  final stable = content['m.poll'];
  final block = unstable is Map ? unstable : (stable is Map ? stable : null);
  if (block == null) return null;

  final question = pollText(block['question'])?.trim() ?? '';
  final rawAnswers = block['answers'];
  if (question.isEmpty || rawAnswers is! List) return null;

  final seen = <String>{};
  final options = <PollOption>[];
  for (final answer in rawAnswers) {
    if (answer is! Map) continue;
    final id = _answerId(answer);
    // A repeated id would make two rows one vote; the first one wins.
    if (id == null || !seen.add(id)) continue;
    options.add(PollOption(id: id, text: pollText(answer) ?? ''));
  }
  if (options.isEmpty) return null;

  final kind = block['kind'];
  return PollStartBlock(
    question: question,
    options: options,
    maxSelections: switch (block['max_selections']) {
      final int n when n > 0 => n.clamp(1, options.length),
      _ => 1,
    },
    undisclosed:
        kind == _kindUndisclosedUnstable || kind == _kindUndisclosedStable,
  );
}

String? _answerId(Map<Object?, Object?> answer) {
  final id = answer['id'] ?? answer['m.id'];
  return id is String && id.isNotEmpty ? id : null;
}

/// MSC1767 text: `{'org.matrix.msc1767.text': '…'}` or `{'m.text': …}`.
String? pollText(Object? block) {
  if (block is! Map) return null;
  final unstable = block['org.matrix.msc1767.text'];
  if (unstable is String) return unstable;
  final stable = block['m.text'];
  if (stable is String) return stable;
  // m.text may itself be a list of representations.
  if (stable is List) {
    for (final rep in stable) {
      if (rep is Map && rep['body'] is String) return rep['body'] as String;
    }
  }
  return null;
}

/// A parsed poll definition, before any votes.
@immutable
class PollStartBlock {
  const PollStartBlock({
    required this.question,
    required this.options,
    required this.maxSelections,
    required this.undisclosed,
  });

  final String question;
  final List<PollOption> options;
  final int maxSelections;
  final bool undisclosed;
}

/// A response or end event that references a poll, stripped to what the
/// count needs.
@immutable
class PollRelatedEvent {
  const PollRelatedEvent({
    required this.type,
    required this.senderId,
    required this.timestamp,
    required this.content,
    this.senderName,
  });

  final String type;
  final String senderId;
  final String? senderName;
  final DateTime timestamp;
  final Map<String, Object?> content;
}

/// The answer ids a response picked, or null when [content] is no response.
List<String>? pollResponseAnswers(Map<String, Object?> content) {
  final unstable = content[kPollResponseUnstable];
  if (unstable is Map && unstable['answers'] is List) {
    return (unstable['answers'] as List).whereType<String>().toList();
  }
  final stable = content['m.selections'];
  if (stable is List) return stable.whereType<String>().toList();
  return null;
}

/// Counts [related] against [start], by MSC3381's rules.
///
/// - Each voter's latest response is the one that counts; an empty one
///   withdraws their vote.
/// - The poll ends at the first end event its creator sent; responses after
///   that moment are not counted.
/// - Answer ids the poll does not have are dropped, and a response naming
///   more answers than allowed counts only the first `max_selections` of them.
PollData foldPoll(
  PollStartBlock start, {
  required String creatorId,
  required Iterable<PollRelatedEvent> related,
  String? ownUserId,
}) {
  DateTime? endedAt;
  for (final event in related) {
    if (!isPollEndType(event.type) || event.senderId != creatorId) continue;
    if (endedAt == null || event.timestamp.isBefore(endedAt)) {
      endedAt = event.timestamp;
    }
  }

  final latest = <String, PollRelatedEvent>{};
  for (final event in related) {
    if (!isPollResponseType(event.type)) continue;
    if (endedAt != null && event.timestamp.isAfter(endedAt)) continue;
    if (pollResponseAnswers(event.content) == null) continue;
    final previous = latest[event.senderId];
    if (previous == null || !event.timestamp.isBefore(previous.timestamp)) {
      latest[event.senderId] = event;
    }
  }

  final validIds = {for (final option in start.options) option.id};
  final votes = <String, int>{};
  final voters = <String, List<String>>{};
  final ownVotes = <String>{};
  var voterCount = 0;
  for (final MapEntry(key: voter, value: response) in latest.entries) {
    final chosen = pollResponseAnswers(
      response.content,
    )!.where(validIds.contains).toSet().take(start.maxSelections).toList();
    if (chosen.isEmpty) continue;
    voterCount++;
    for (final id in chosen) {
      votes[id] = (votes[id] ?? 0) + 1;
      (voters[id] ??= []).add(response.senderName ?? voter);
      if (voter == ownUserId) ownVotes.add(id);
    }
  }

  return PollData(
    question: start.question,
    options: start.options,
    votes: votes,
    voters: voters,
    voterCount: voterCount,
    ownVotes: ownVotes,
    ended: endedAt != null,
    undisclosed: start.undisclosed,
    maxSelections: start.maxSelections,
  );
}

/// The content of a new poll, in the shape the mautrix bridges read, with a
/// plain-text fallback for clients that do not know polls.
Map<String, Object?> pollStartContent({
  required String question,
  required List<String> options,
  bool multipleChoice = false,
  bool undisclosed = false,
}) {
  final fallback = [
    question,
    for (var i = 0; i < options.length; i++) '${i + 1}. ${options[i]}',
  ].join('\n');
  return {
    kPollStartUnstable: {
      'question': {'org.matrix.msc1767.text': question},
      'kind': undisclosed
          ? _kindUndisclosedUnstable
          : 'org.matrix.msc3381.poll.disclosed',
      'max_selections': multipleChoice ? options.length : 1,
      'answers': [
        for (var i = 0; i < options.length; i++)
          {'id': 'option_$i', 'org.matrix.msc1767.text': options[i]},
      ],
    },
    'org.matrix.msc1767.text': fallback,
    // What a client that knows neither extensible events nor polls shows.
    'msgtype': 'm.text',
    'body': fallback,
  };
}

/// A vote on [startEventId]; an empty [answerIds] withdraws it.
Map<String, Object?> pollResponseContent(
  String startEventId,
  Iterable<String> answerIds,
) => {
  'm.relates_to': {'rel_type': 'm.reference', 'event_id': startEventId},
  kPollResponseUnstable: {'answers': answerIds.toList()},
};

/// Closes [startEventId]; [fallback] is what clients without polls show.
Map<String, Object?> pollEndContent(String startEventId, String fallback) => {
  'm.relates_to': {'rel_type': 'm.reference', 'event_id': startEventId},
  kPollEndUnstable: <String, Object?>{},
  'org.matrix.msc1767.text': fallback,
  'msgtype': 'm.text',
  'body': fallback,
};

/// What the bridge says a room can do with polls.
///
/// [features] is each bridge room features state the room holds (a
/// bridge writes one under its own state key). [bridged] is whether a bridge
/// serves the room at all: an unbridged Matrix room carries every kind of
/// poll, while a bridged one that declares nothing is assumed not to — the
/// legacy bridges that predate the declaration never learnt polls either.
PollSupport pollSupportFromFeatures(
  Iterable<Map<String, Object?>> features, {
  required bool bridged,
}) {
  final declared = features.toList();
  if (declared.isEmpty) {
    return bridged ? const PollSupport.unavailable() : const PollSupport();
  }
  int level(String key) {
    var best = -2;
    for (final f in declared) {
      final value = f[key];
      final n = value is int ? value : 0;
      if (n > best) best = n;
    }
    return best;
  }

  bool flag(String key) => declared.any((f) => f[key] == true);
  int limit(String key) {
    var lowest = 0;
    for (final f in declared) {
      final value = f[key];
      if (value is int && value > 0 && (lowest == 0 || value < lowest)) {
        lowest = value;
      }
    }
    return lowest;
  }

  // 1 is "partial support" (Meta turns any poll into a multiple-choice one),
  // which is still a poll on the other side.
  if (level('poll') < 1) return const PollSupport.unavailable();
  final max = limit('poll_max_options');
  return PollSupport(
    maxOptions: max == 0 ? PollSupport.maxAnswers : max.clamp(2, 20),
    optionMaxLength: limit('poll_option_max_length'),
    multipleChoiceOnly: flag('poll_multiple_choice_only'),
    undisclosed: level('poll_hidden_votes') >= 1,
    canEnd: level('poll_end') >= 1,
    uniqueOptions: level('poll_duplicate_options') < 1,
  );
}
