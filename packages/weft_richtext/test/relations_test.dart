import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

/// Fixed epoch so every timestamp in this file is written as an offset from one
/// place and no test depends on the wall clock.
final DateTime _t0 = DateTime.utc(2026, 8, 18, 14);

DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

ReactionEvent _reaction({
  required String id,
  required String sender,
  required String key,
  String room = '!wa:example.org',
  String target = r'$msg1',
  int at = 0,
}) => ReactionEvent(
  eventId: id,
  roomId: room,
  senderId: sender,
  targetEventId: target,
  key: key,
  timestamp: _at(at),
);

WeftMessage _message({
  String eventId = r'$msg1',
  String roomId = '!wa:example.org',
  String sender = '@whatsapp_anna:example.org',
  String senderName = 'Anna',
  String body = 'original text',
  ChatNetwork network = ChatNetwork.whatsapp,
  MessageKind kind = MessageKind.text,
  bool redacted = false,
  int at = 0,
}) => WeftMessage(
  eventId: eventId,
  roomId: roomId,
  network: network,
  senderId: sender,
  senderName: senderName,
  timestamp: _at(at),
  kind: kind,
  isOwn: false,
  body: body,
  redacted: redacted,
);

EditEvent _edit({
  required String id,
  required String body,
  String sender = '@whatsapp_anna:example.org',
  String target = r'$msg1',
  String room = '!wa:example.org',
  int at = 60,
}) => EditEvent(
  eventId: id,
  roomId: room,
  senderId: sender,
  targetEventId: target,
  body: body,
  timestamp: _at(at),
);

/// Anna reaches this conversation on two legs; both ghosts are her.
String _annaMerged(String senderId) => switch (senderId) {
  '@whatsapp_anna:example.org' || '@signal_anna:example.org' => 'contact_anna',
  _ => senderId,
};

void main() {
  group('normaliseReactionKey', () {
    test('a variation selector does not make a second reaction', () {
      expect(normaliseReactionKey('\u{1F44D}\u{FE0F}'), '\u{1F44D}');
      expect(
        normaliseReactionKey('\u{1F44D}\u{FE0F}'),
        normaliseReactionKey('\u{1F44D}'),
      );
    });

    test('skin tones tally with the unmodified emoji', () {
      expect(normaliseReactionKey('\u{1F44D}\u{1F3FF}'), '\u{1F44D}');
      expect(normaliseReactionKey('\u{1F44D}\u{1F3FB}'), '\u{1F44D}');
    });

    test('a zwj sequence stays whole — it is a different emoji', () {
      const family = '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}';
      expect(normaliseReactionKey(family), family);
      expect(normaliseReactionKey(family), isNot('\u{1F468}'));
    });

    test('a skin tone inside a zwj sequence still goes', () {
      expect(
        normaliseReactionKey('\u{1F468}\u{1F3FB}\u{200D}\u{1F9B0}'),
        '\u{1F468}\u{200D}\u{1F9B0}',
      );
    });

    test('padding a bridge added goes', () {
      expect(normaliseReactionKey('  \u{1F44D} '), '\u{1F44D}');
    });

    test('a text key is left exactly as it was sent', () {
      expect(normaliseReactionKey('ok'), 'ok');
      expect(normaliseReactionKey('OK'), 'OK');
    });

    test('a key made only of modifiers survives rather than vanishing', () {
      expect(normaliseReactionKey('\u{FE0F}'), '\u{FE0F}');
    });
  });

  group('aggregateReactions', () {
    test('groups by key and counts senders', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(id: r'$r1', sender: '@a:example.org', key: '👍', at: 1),
          _reaction(id: r'$r2', sender: '@b:example.org', key: '👍', at: 2),
          _reaction(id: r'$r3', sender: '@c:example.org', key: '🎉', at: 3),
        ],
        resolveSender: senderIsIdentity,
      );

      expect(tallies.map((t) => t.key), ['👍', '🎉']);
      expect(tallies.first.count, 2);
      expect(tallies.first.senderIds, ['@a:example.org', '@b:example.org']);
      expect(tallies.last.count, 1);
    });

    test('no events is no tallies', () {
      expect(
        aggregateReactions(events: const [], resolveSender: senderIsIdentity),
        isEmpty,
      );
    });

    test('two spellings of one emoji are one chip', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(
            id: r'$r1',
            sender: '@a:example.org',
            key: '\u{1F44D}',
            at: 1,
          ),
          _reaction(
            id: r'$r2',
            sender: '@b:example.org',
            key: '\u{1F44D}\u{FE0F}',
            at: 2,
          ),
          _reaction(
            id: r'$r3',
            sender: '@c:example.org',
            key: '\u{1F44D}\u{1F3FD}',
            at: 3,
          ),
        ],
        resolveSender: senderIsIdentity,
      );

      expect(tallies, hasLength(1));
      expect(tallies.single.count, 3);
      expect(tallies.single.key, '\u{1F44D}');
    });

    test('one person reacting on two legs of a merged chat counts once', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(
            id: r'$r1',
            sender: '@whatsapp_anna:example.org',
            room: '!wa:example.org',
            key: '👍',
            at: 1,
          ),
          _reaction(
            id: r'$r2',
            sender: '@signal_anna:example.org',
            room: '!sig:example.org',
            key: '👍',
            at: 2,
          ),
        ],
        resolveSender: _annaMerged,
      );

      expect(tallies.single.count, 1);
      // The leg she reacted on *first* is the one the sender list shows.
      expect(tallies.single.senderIds, ['@whatsapp_anna:example.org']);
    });

    test('two different people are still two, merged chat or not', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(
            id: r'$r1',
            sender: '@whatsapp_anna:example.org',
            key: '👍',
            at: 1,
          ),
          _reaction(
            id: r'$r2',
            sender: '@signal_bo:example.org',
            room: '!sig:example.org',
            key: '👍',
            at: 2,
          ),
        ],
        resolveSender: _annaMerged,
      );

      expect(tallies.single.count, 2);
    });

    test('a replayed annotation does not double-count', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(id: r'$r1', sender: '@a:example.org', key: '👍', at: 1),
          _reaction(id: r'$r1', sender: '@a:example.org', key: '👍', at: 1),
        ],
        resolveSender: senderIsIdentity,
      );

      expect(tallies.single.count, 1);
    });

    test('the local user is flagged and their annotation id kept', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(id: r'$r1', sender: '@a:example.org', key: '👍', at: 1),
          _reaction(id: r'$r2', sender: '@me:example.org', key: '👍', at: 2),
          _reaction(id: r'$r3', sender: '@a:example.org', key: '🎉', at: 3),
        ],
        resolveSender: senderIsIdentity,
        localUserId: '@me:example.org',
      );

      final thumbs = tallies.firstWhere((t) => t.key == '👍');
      expect(thumbs.byLocalUser, isTrue);
      expect(thumbs.localEventId, r'$r2');
      expect(tallies.firstWhere((t) => t.key == '🎉').byLocalUser, isFalse);
    });

    test('the local user is recognised through a merged identity', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(
            id: r'$r1',
            sender: '@signal_anna:example.org',
            key: '👍',
            at: 1,
          ),
        ],
        resolveSender: _annaMerged,
        // Signed in on the WhatsApp leg; the reaction came in on the other.
        localUserId: '@whatsapp_anna:example.org',
      );

      expect(tallies.single.byLocalUser, isTrue);
      expect(tallies.single.localEventId, r'$r1');
    });

    test('no local user means nothing is flagged as mine', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(id: r'$r1', sender: '@a:example.org', key: '👍', at: 1),
        ],
        resolveSender: senderIsIdentity,
      );

      expect(tallies.single.byLocalUser, isFalse);
      expect(tallies.single.localEventId, isNull);
    });

    test('order is by first reaction, not by count', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(id: r'$r1', sender: '@a:example.org', key: '🎉', at: 1),
          _reaction(id: r'$r2', sender: '@b:example.org', key: '👍', at: 2),
          _reaction(id: r'$r3', sender: '@c:example.org', key: '👍', at: 3),
          _reaction(id: r'$r4', sender: '@d:example.org', key: '👍', at: 4),
        ],
        resolveSender: senderIsIdentity,
      );

      expect(tallies.map((t) => t.key), ['🎉', '👍']);
      expect(tallies.first.count, 1);
      expect(tallies.last.count, 3);
    });

    test('input order does not change the bar', () {
      final events = [
        _reaction(id: r'$r3', sender: '@c:example.org', key: '👍', at: 3),
        _reaction(id: r'$r1', sender: '@a:example.org', key: '🎉', at: 1),
        _reaction(id: r'$r2', sender: '@b:example.org', key: '👍', at: 2),
      ];

      final forwards = aggregateReactions(
        events: events,
        resolveSender: senderIsIdentity,
      );
      final backwards = aggregateReactions(
        events: events.reversed.toList(),
        resolveSender: senderIsIdentity,
      );

      expect(forwards, backwards);
      expect(forwards.map((t) => t.key), ['🎉', '👍']);
    });

    test('keys sharing a timestamp are ordered by event id', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(id: r'$b', sender: '@a:example.org', key: '🎉', at: 1),
          _reaction(id: r'$a', sender: '@b:example.org', key: '👍', at: 1),
        ],
        resolveSender: senderIsIdentity,
      );

      expect(tallies.map((t) => t.key), ['👍', '🎉']);
    });

    test('an empty key is dropped rather than tallied as a blank chip', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(id: r'$r1', sender: '@a:example.org', key: '   ', at: 1),
          _reaction(id: r'$r2', sender: '@b:example.org', key: '👍', at: 2),
        ],
        resolveSender: senderIsIdentity,
      );

      expect(tallies.map((t) => t.key), ['👍']);
    });

    test('it tallies exactly the events it is given', () {
      // The contract the caller has to honour: annotations are grouped by
      // target *before* they get here. Handing over a whole room's reactions
      // produces one bar carrying the whole conversation, which is why the
      // mapper filters first.
      final tallies = aggregateReactions(
        events: [
          _reaction(id: r'$r1', sender: '@a:example.org', key: '👍', at: 1),
          _reaction(
            id: r'$r2',
            sender: '@b:example.org',
            key: '👍',
            target: r'$someOtherMessage',
            at: 2,
          ),
        ],
        resolveSender: senderIsIdentity,
      );

      expect(tallies.single.count, 2);
    });

    test('the same person on three legs is still one', () {
      String threeLegs(String senderId) =>
          senderId.startsWith('@wa_') ||
              senderId.startsWith('@sig_') ||
              senderId.startsWith('@tg_')
          ? 'contact_anna'
          : senderId;

      final tallies = aggregateReactions(
        events: [
          _reaction(
            id: r'$r1',
            sender: '@wa_anna:example.org',
            key: '👍',
            at: 1,
          ),
          _reaction(
            id: r'$r2',
            sender: '@sig_anna:example.org',
            room: '!sig:example.org',
            key: '👍',
            at: 2,
          ),
          _reaction(
            id: r'$r3',
            sender: '@tg_anna:example.org',
            room: '!tg:example.org',
            key: '👍',
            at: 3,
          ),
        ],
        resolveSender: threeLegs,
      );

      expect(tallies.single.count, 1);
    });

    test('a merged local user keeps the id of the leg they reacted on', () {
      // `unreact` redacts this annotation in the room it lives in, and there is
      // no way back to it from the tally once it has been dropped.
      final tallies = aggregateReactions(
        events: [
          _reaction(
            id: r'$r1',
            sender: '@whatsapp_anna:example.org',
            room: '!wa:example.org',
            key: '👍',
            at: 1,
          ),
          _reaction(
            id: r'$r2',
            sender: '@signal_anna:example.org',
            room: '!sig:example.org',
            key: '👍',
            at: 2,
          ),
        ],
        resolveSender: _annaMerged,
        localUserId: '@signal_anna:example.org',
      );

      expect(tallies.single.byLocalUser, isTrue);
      // The first leg is the one that was counted, so it is the one whose
      // annotation the redaction has to name.
      expect(tallies.single.localEventId, r'$r1');
    });

    test('a merged reaction dedupes across keys independently', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(
            id: r'$r1',
            sender: '@whatsapp_anna:example.org',
            key: '👍',
            at: 1,
          ),
          _reaction(
            id: r'$r2',
            sender: '@signal_anna:example.org',
            room: '!sig:example.org',
            key: '🎉',
            at: 2,
          ),
        ],
        resolveSender: _annaMerged,
      );

      expect(tallies.map((t) => t.key), ['👍', '🎉']);
      expect(tallies.every((t) => t.count == 1), isTrue);
    });

    test('the sender list is not writable by a renderer', () {
      final tallies = aggregateReactions(
        events: [
          _reaction(id: r'$r1', sender: '@a:example.org', key: '👍', at: 1),
        ],
        resolveSender: senderIsIdentity,
      );

      expect(
        () => tallies.single.senderIds.add('@intruder:example.org'),
        throwsUnsupportedError,
      );
    });
  });

  group('applyEdits', () {
    test('no edits leaves the message exactly as it was', () {
      final original = _message();
      final resolved = applyEdits(const [], original);

      expect(resolved.message.body, 'original text');
      expect(resolved.message.editedAt, isNull);
      expect(resolved.wasEdited, isFalse);
      expect(resolved.history, isEmpty);
    });

    test('the latest edit wins and stamps its own timestamp', () {
      final original = _message();
      final resolved = applyEdits([
        _edit(id: r'$e1', body: 'first correction', at: 60),
        _edit(id: r'$e2', body: 'second correction', at: 120),
      ], original);

      expect(resolved.message.body, 'second correction');
      // The *edit's* time, not the original's — an "edited 14:02" indicator
      // reading 14:00 would be a lie about when the text changed.
      expect(resolved.message.editedAt, _at(120));
      expect(resolved.message.isEdited, isTrue);
    });

    test('out-of-order edits still resolve to the latest', () {
      final resolved = applyEdits([
        _edit(id: r'$e2', body: 'second correction', at: 120),
        _edit(id: r'$e1', body: 'first correction', at: 60),
      ], _message());

      expect(resolved.message.body, 'second correction');
      expect(resolved.history.map((r) => r.body), [
        'original text',
        'first correction',
        'second correction',
      ]);
    });

    test('a same-millisecond tie is broken by event id', () {
      final resolved = applyEdits([
        _edit(id: r'$aaa', body: 'from aaa', at: 60),
        _edit(id: r'$zzz', body: 'from zzz', at: 60),
      ], _message());

      expect(resolved.message.body, 'from zzz');
      expect(resolved.message.editedAt, _at(60));
    });

    test('the tie-break does not depend on input order', () {
      final forwards = applyEdits([
        _edit(id: r'$aaa', body: 'from aaa', at: 60),
        _edit(id: r'$zzz', body: 'from zzz', at: 60),
      ], _message());
      final backwards = applyEdits([
        _edit(id: r'$zzz', body: 'from zzz', at: 60),
        _edit(id: r'$aaa', body: 'from aaa', at: 60),
      ], _message());

      expect(forwards.message.body, backwards.message.body);
      expect(
        forwards.history.map((r) => r.eventId),
        backwards.history.map((r) => r.eventId),
      );
    });

    test('the original body is kept as the first version', () {
      final resolved = applyEdits([
        _edit(id: r'$e1', body: 'corrected', at: 60),
      ], _message());

      expect(resolved.history.first.body, 'original text');
      expect(resolved.history.first.eventId, r'$msg1');
      expect(resolved.history.first.timestamp, _at(0));
      expect(resolved.history.last.body, resolved.message.body);
    });

    test('an edit from someone else is rejected, not applied', () {
      final resolved = applyEdits([
        _edit(
          id: r'$e1',
          body: 'i never said this',
          sender: '@mallory:example.org',
          at: 60,
        ),
      ], _message());

      expect(resolved.message.body, 'original text');
      expect(resolved.message.editedAt, isNull);
      expect(resolved.wasEdited, isFalse);
      expect(resolved.rejected.single.eventId, r'$e1');
    });

    test('a foreign edit cannot win over a genuine one', () {
      final resolved = applyEdits([
        _edit(id: r'$e1', body: 'the sender own correction', at: 60),
        _edit(
          id: r'$e2',
          body: 'mallory had the last word',
          sender: '@mallory:example.org',
          at: 120,
        ),
      ], _message());

      expect(resolved.message.body, 'the sender own correction');
      expect(resolved.message.editedAt, _at(60));
      expect(resolved.rejected.single.senderId, '@mallory:example.org');
    });

    test('an edit aimed at another event is rejected', () {
      final resolved = applyEdits([
        _edit(id: r'$e1', body: 'for a different message', target: r'$other'),
      ], _message());

      expect(resolved.message.body, 'original text');
      expect(resolved.rejected, hasLength(1));
    });

    test('a replayed replacement is one version, not two', () {
      final resolved = applyEdits([
        _edit(id: r'$e1', body: 'corrected', at: 60),
        _edit(id: r'$e1', body: 'corrected', at: 60),
      ], _message());

      expect(resolved.history, hasLength(2));
    });

    test('an SDK-resolved body is not double-applied', () {
      // What the mapper hands over today: `body` already carries the edit.
      final alreadyEdited = _message(body: 'corrected');
      final resolved = applyEdits([
        _edit(id: r'$e1', body: 'corrected', at: 60),
      ], alreadyEdited);

      expect(resolved.message.body, 'corrected');
      expect(resolved.message.editedAt, _at(60));
      expect(resolved.history.map((r) => r.body), ['corrected', 'corrected']);
    });

    test('the formatted body of an edit is carried into the history', () {
      final resolved = applyEdits([
        EditEvent(
          eventId: r'$e1',
          roomId: '!wa:example.org',
          senderId: '@whatsapp_anna:example.org',
          targetEventId: r'$msg1',
          body: 'meet at six',
          formattedBody: 'meet at <b>six</b>',
          timestamp: _at(60),
        ),
      ], _message());

      expect(resolved.history.last.formattedBody, 'meet at <b>six</b>');
    });

    test('the history is not writable by a sheet', () {
      final resolved = applyEdits([
        _edit(id: r'$e1', body: 'corrected', at: 60),
      ], _message());

      expect(
        () => resolved.history.add(
          EditRecord(eventId: r'$x', body: 'x', timestamp: _at(0)),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('resolveReplyTarget', () {
    final anna = _message(
      eventId: r'$msg1',
      roomId: '!wa:example.org',
      sender: '@whatsapp_anna:example.org',
      senderName: 'Anna',
      body: 'are we still on for six?',
    );
    final bo = _message(
      eventId: r'$msg2',
      roomId: '!sig:example.org',
      sender: '@signal_bo:example.org',
      senderName: 'Bo',
      network: ChatNetwork.signal,
      body: 'yes, six works',
      at: 30,
    );

    test('not a reply resolves to nothing at all', () {
      expect(
        resolveReplyTarget(replyToEventId: null, loaded: [anna, bo]),
        isNull,
      );
      expect(resolveReplyTarget(replyToEventId: '  ', loaded: [anna]), isNull);
    });

    test('a loaded target resolves with sender, room and preview', () {
      final preview = resolveReplyTarget(
        replyToEventId: r'$msg1',
        loaded: [bo, anna],
      )!;

      expect(preview.isStub, isFalse);
      expect(preview.eventId, r'$msg1');
      expect(preview.roomId, '!wa:example.org');
      expect(preview.senderName, 'Anna');
      expect(preview.network, ChatNetwork.whatsapp);
      expect(preview.body, 'are we still on for six?');
    });

    test('the target is found in another source room of the merged chat', () {
      // A reply sent on the Signal leg, answering the WhatsApp leg. Scoping the
      // search to the reply own room would stub a message that is on screen.
      final preview = resolveReplyTarget(
        replyToEventId: r'$msg1',
        loaded: [bo, anna],
      )!;

      expect(preview.roomId, isNot(bo.roomId));
      expect(preview.roomId, '!wa:example.org');
    });

    test('an unpaginated target is a stub, never a missing chip', () {
      final preview = resolveReplyTarget(
        replyToEventId: r'$notloadedyet',
        loaded: [anna, bo],
      )!;

      expect(preview.isStub, isTrue);
      expect(preview.eventId, r'$notloadedyet');
      expect(preview.senderName, isNull);
      expect(preview.body, isEmpty);
    });

    test('an empty candidate set stubs rather than throwing', () {
      final preview = resolveReplyTarget(
        replyToEventId: r'$msg1',
        loaded: const [],
      )!;

      expect(preview.isStub, isTrue);
    });

    test('a redacted target previews as nothing, not as its old words', () {
      final removed = _message(
        eventId: r'$msg3',
        body: 'something regretted',
        redacted: true,
      );
      final preview = resolveReplyTarget(
        replyToEventId: r'$msg3',
        loaded: [removed],
      )!;

      expect(preview.isStub, isFalse);
      expect(preview.redacted, isTrue);
      expect(preview.body, isEmpty);
    });

    test('the target own reply fallback is not quoted again', () {
      final nested = _message(
        eventId: r'$msg4',
        body:
            '> <@signal_bo:example.org> yes, six works\n\nsee you at the usual place',
      );
      final preview = resolveReplyTarget(
        replyToEventId: r'$msg4',
        loaded: [nested],
      )!;

      expect(preview.body, 'see you at the usual place');
    });

    test('a multi-line body collapses to one line', () {
      final multiline = _message(
        eventId: r'$msg5',
        body: 'first line\n\nsecond   line\nthird',
      );
      final preview = resolveReplyTarget(
        replyToEventId: r'$msg5',
        loaded: [multiline],
      )!;

      expect(preview.body, 'first line second line third');
    });

    test('a long body is truncated with an ellipsis', () {
      final long = _message(eventId: r'$msg6', body: 'x' * 300);
      final preview = resolveReplyTarget(
        replyToEventId: r'$msg6',
        loaded: [long],
        previewLength: 20,
      )!;

      expect(preview.body, '${'x' * 20}…');
    });

    test('truncation never splits an emoji in half', () {
      final long = _message(eventId: r'$msg7', body: '👍' * 40);
      final preview = resolveReplyTarget(
        replyToEventId: r'$msg7',
        loaded: [long],
        previewLength: 5,
      )!;

      expect(preview.body, '${'👍' * 5}…');
      expect(preview.body.runes.length, 6);
    });

    test('an attachment target previews by kind, with an empty body', () {
      final photo = _message(
        eventId: r'$msg8',
        body: '',
        kind: MessageKind.image,
      );
      final preview = resolveReplyTarget(
        replyToEventId: r'$msg8',
        loaded: [photo],
      )!;

      expect(preview.kind, MessageKind.image);
      expect(preview.body, isEmpty);
      expect(preview.isStub, isFalse);
    });
  });

  group('replyPreviewText', () {
    // Exported on its own for the composer's reply bar, which has a message in
    // hand and no reply to resolve.
    test('a one-line body comes back as it was written', () {
      expect(
        replyPreviewText(_message(body: 'are we still on for six?')),
        'are we still on for six?',
      );
    });

    test('a redacted message previews as nothing', () {
      expect(
        replyPreviewText(_message(body: 'something regretted', redacted: true)),
        isEmpty,
      );
    });

    test('it strips a fallback the target was itself carrying', () {
      expect(
        replyPreviewText(
          _message(body: '> <@signal_bo:example.org> q\n\nmy answer'),
        ),
        'my answer',
      );
    });

    test('the default length is the one the chip was designed around', () {
      final long = _message(body: 'x' * (kReplyPreviewLength + 50));
      expect(replyPreviewText(long), '${'x' * kReplyPreviewLength}…');
      expect(
        replyPreviewText(_message(body: 'x' * kReplyPreviewLength)),
        'x' * kReplyPreviewLength,
      );
    });
  });
}
