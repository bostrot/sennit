import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  final start = DateTime(2026, 11, 26, 18);

  Map<String, Object?> unstablePoll({
    int maxSelections = 1,
    String kind = 'org.matrix.msc3381.poll.disclosed',
  }) => {
    kPollStartUnstable: {
      'question': {'org.matrix.msc1767.text': 'Lunch where?'},
      'kind': kind,
      'max_selections': maxSelections,
      'answers': [
        {'id': 'a', 'org.matrix.msc1767.text': 'Pizza'},
        {'id': 'b', 'org.matrix.msc1767.text': 'Sushi'},
        {'id': 'c', 'org.matrix.msc1767.text': 'Salad'},
      ],
    },
  };

  PollRelatedEvent vote(
    String sender,
    List<String> answers, {
    int minutes = 1,
    bool stable = false,
  }) => PollRelatedEvent(
    type: stable ? kPollResponseStable : kPollResponseUnstable,
    senderId: sender,
    senderName: sender.substring(1, sender.indexOf(':')),
    timestamp: start.add(Duration(minutes: minutes)),
    content: stable
        ? {'m.selections': answers}
        : {
            kPollResponseUnstable: {'answers': answers},
          },
  );

  PollRelatedEvent end(String sender, {int minutes = 5}) => PollRelatedEvent(
    type: kPollEndUnstable,
    senderId: sender,
    timestamp: start.add(Duration(minutes: minutes)),
    content: {kPollEndUnstable: <String, Object?>{}},
  );

  PollData fold(
    List<PollRelatedEvent> related, {
    Map<String, Object?>? content,
  }) => foldPoll(
    pollStartBlock(content ?? unstablePoll())!,
    creatorId: '@ann:example.org',
    ownUserId: '@me:example.org',
    related: related,
  );

  group('pollStartBlock', () {
    test('reads the unstable shape the bridges send', () {
      final block = pollStartBlock(unstablePoll(maxSelections: 2))!;
      expect(block.question, 'Lunch where?');
      expect(block.options.map((o) => o.text), ['Pizza', 'Sushi', 'Salad']);
      expect(block.maxSelections, 2);
      expect(block.undisclosed, isFalse);
    });

    test('reads the stable m.poll shape', () {
      final block = pollStartBlock({
        'm.poll': {
          'kind': 'm.poll.undisclosed',
          'max_selections': 1,
          'question': {
            'm.text': [
              {'body': 'Which day?'},
            ],
          },
          'answers': [
            {
              'm.id': 'mon',
              'm.text': [
                {'body': 'Monday'},
              ],
            },
            {
              'm.id': 'tue',
              'm.text': [
                {'body': 'Tuesday'},
              ],
            },
          ],
        },
      })!;
      expect(block.question, 'Which day?');
      expect(block.options.map((o) => o.id), ['mon', 'tue']);
      expect(block.undisclosed, isTrue);
    });

    test('reads a WhatsApp poll riding an m.room.message', () {
      // mautrix-whatsapp with extev_polls off, the default.
      final block = pollStartBlock({
        'msgtype': 'm.text',
        'body':
            'Lunch?\n\n1. Yes\n2. No\n\n(This message is a poll. '
            'Please open WhatsApp to vote.)',
        'org.matrix.msc3381.poll.start': {
          'kind': 'org.matrix.msc3381.poll.disclosed',
          'max_selections': 2,
          'question': {'org.matrix.msc1767.text': 'Lunch?'},
          'answers': [
            {'id': 'h1', 'org.matrix.msc1767.text': 'Yes'},
            {'id': 'h2', 'org.matrix.msc1767.text': 'No'},
          ],
        },
      })!;
      expect(block.question, 'Lunch?');
      expect(block.options, hasLength(2));
      expect(block.maxSelections, 2);
    });

    test('rejects a poll without question or answers', () {
      expect(pollStartBlock({}), isNull);
      expect(
        pollStartBlock({
          kPollStartUnstable: {
            'question': {'org.matrix.msc1767.text': ''},
            'answers': [
              {'id': 'a', 'org.matrix.msc1767.text': 'A'},
            ],
          },
        }),
        isNull,
      );
      expect(
        pollStartBlock({
          kPollStartUnstable: {
            'question': {'org.matrix.msc1767.text': 'Q'},
            'answers': [
              {'org.matrix.msc1767.text': 'no id'},
            ],
          },
        }),
        isNull,
      );
    });

    test('keeps the first of two answers with the same id', () {
      final block = pollStartBlock({
        kPollStartUnstable: {
          'question': {'org.matrix.msc1767.text': 'Q'},
          'max_selections': 9,
          'answers': [
            {'id': 'a', 'org.matrix.msc1767.text': 'First'},
            {'id': 'a', 'org.matrix.msc1767.text': 'Second'},
          ],
        },
      })!;
      expect(block.options.single.text, 'First');
      // And a max_selections above the answer count means "all of them".
      expect(block.maxSelections, 1);
    });
  });

  group('foldPoll', () {
    test('the latest vote per person wins', () {
      final poll = fold([
        vote('@bob:example.org', ['a'], minutes: 1),
        vote('@bob:example.org', ['b'], minutes: 3),
        vote('@cat:example.org', ['b'], minutes: 2),
        // Arrived out of order: older than Bob's change of mind.
        vote('@bob:example.org', ['c'], minutes: 2),
      ]);
      expect(poll.votes, {'b': 2});
      expect(poll.voterCount, 2);
      expect(poll.voters['b'], ['bob', 'cat']);
    });

    test('votes after the end are not counted', () {
      final poll = fold([
        vote('@bob:example.org', ['a'], minutes: 1),
        end('@ann:example.org', minutes: 5),
        vote('@bob:example.org', ['b'], minutes: 6),
        vote('@cat:example.org', ['c'], minutes: 7),
      ]);
      expect(poll.ended, isTrue);
      expect(poll.votes, {'a': 1});
      expect(poll.voterCount, 1);
    });

    test('only the creator ends the poll', () {
      final poll = fold([
        end('@mallory:example.org', minutes: 1),
        vote('@bob:example.org', ['a'], minutes: 2),
      ]);
      expect(poll.ended, isFalse);
      expect(poll.votes, {'a': 1});
    });

    test('invalid answer ids are ignored', () {
      final poll = fold([
        vote('@bob:example.org', ['zzz']),
        vote('@cat:example.org', ['zzz', 'a']),
      ]);
      expect(poll.votes, {'a': 1});
      // Bob named nothing the poll has: no vote, not a vote for nothing.
      expect(poll.voterCount, 1);
    });

    test('a response over the limit counts its first answers only', () {
      final single = fold([
        vote('@bob:example.org', ['b', 'a']),
      ]);
      expect(single.votes, {'b': 1});

      final multi = fold([
        vote('@bob:example.org', ['a', 'a', 'b', 'c']),
      ], content: unstablePoll(maxSelections: 2));
      expect(multi.votes, {'a': 1, 'b': 1});
      expect(multi.totalVotes, 2);
      expect(multi.voterCount, 1);
    });

    test('an empty response withdraws a vote', () {
      final poll = fold([
        vote('@bob:example.org', ['a'], minutes: 1),
        vote('@bob:example.org', [], minutes: 2),
      ]);
      expect(poll.votes, isEmpty);
      expect(poll.voterCount, 0);
    });

    test('knows the reader\'s own pick, from either generation', () {
      final poll = fold([
        vote('@me:example.org', ['c'], stable: true),
      ]);
      expect(poll.ownVotes, {'c'});
      expect(poll.votes, {'c': 1});
    });

    test('an undisclosed poll shows results only once ended', () {
      final content = unstablePoll(kind: 'org.matrix.msc3381.poll.undisclosed');
      final open = fold([
        vote('@bob:example.org', ['a']),
      ], content: content);
      expect(open.undisclosed, isTrue);
      expect(open.resultsVisible, isFalse);

      final closed = fold([
        vote('@bob:example.org', ['a']),
        end('@ann:example.org'),
      ], content: content);
      expect(closed.resultsVisible, isTrue);
    });
  });

  group('content', () {
    test('a new poll carries the bridge shape and a text fallback', () {
      final content = pollStartContent(
        question: 'Lunch where?',
        options: ['Pizza', 'Sushi'],
        multipleChoice: true,
        undisclosed: true,
      );
      final block = pollStartBlock(content)!;
      expect(block.question, 'Lunch where?');
      expect(block.maxSelections, 2);
      expect(block.undisclosed, isTrue);
      expect(content['body'], 'Lunch where?\n1. Pizza\n2. Sushi');
      expect(content['org.matrix.msc1767.text'], content['body']);
    });

    test('a vote and an end reference the poll', () {
      final response = pollResponseContent(r'$poll', ['a']);
      expect(response['m.relates_to'], {
        'rel_type': 'm.reference',
        'event_id': r'$poll',
      });
      expect(pollResponseAnswers(response), ['a']);

      final ended = pollEndContent(r'$poll', 'The poll has ended.');
      expect(ended[kPollEndUnstable], isEmpty);
      expect(ended['body'], 'The poll has ended.');
    });
  });

  group('pollSupportFromFeatures', () {
    test('a plain Matrix room carries every kind of poll', () {
      final support = pollSupportFromFeatures(const [], bridged: false);
      expect(support.available, isTrue);
      expect(support.maxOptions, 20);
      expect(support.undisclosed, isTrue);
      expect(support.canEnd, isTrue);
    });

    test('a bridge that declares nothing carries no polls', () {
      // mautrix-discord, the last legacy bridge, never wrote room features.
      expect(
        pollSupportFromFeatures(const [], bridged: true).available,
        isFalse,
      );
    });

    test('WhatsApp: twelve answers, no hidden results, no end', () {
      final support = pollSupportFromFeatures([
        {
          'poll': 2,
          'poll_end': 0,
          'poll_hidden_votes': 0,
          'poll_duplicate_options': 0,
          'poll_max_options': 12,
          'poll_option_max_length': 100,
        },
      ], bridged: true);
      expect(support.available, isTrue);
      expect(support.maxOptions, 12);
      expect(support.optionMaxLength, 100);
      expect(support.undisclosed, isFalse);
      expect(support.canEnd, isFalse);
      expect(support.uniqueOptions, isTrue);
      expect(support.multipleChoiceOnly, isFalse);
    });

    test('Messenger groups: partial support, multiple choice only', () {
      final support = pollSupportFromFeatures([
        {'poll': 1, 'poll_multiple_choice_only': true},
      ], bridged: true);
      expect(support.available, isTrue);
      expect(support.multipleChoiceOnly, isTrue);
    });

    test('a bridge that says no means no', () {
      // Google Messages, Mattermost, a Messenger DM.
      expect(
        pollSupportFromFeatures([
          {'reply': 2},
        ], bridged: true).available,
        isFalse,
      );
    });
  });
}
