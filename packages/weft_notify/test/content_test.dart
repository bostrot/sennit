import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

import 'support/fixtures.dart';

/// Renders [message] for [forChat] with everything else defaulted, so each test
/// states only the thing it is about.
NotificationContent render({
  WeftMessage? message,
  Chat? forChat,
  NotificationPolicy? policy,
  DeliveredDecision decision = const NotifyDecision(),
  String? senderAvatarUrl,
  bool? disambiguateSender,
}) {
  return NotificationContent.forMessage(
    message: message ?? msg(),
    chat: forChat ?? chat(),
    policy: policy ?? NotificationPolicy(),
    decision: decision,
    senderAvatarUrl: senderAvatarUrl,
    disambiguateSender: disambiguateSender,
  );
}

/// The chat id a `weft://chat/…` link resolves to, by the same two steps
/// `WeftLink.parse` takes: the custom scheme puts `chat` in the host, and the
/// id is one percent-encoded segment.
String? chatIdFromLink(String link) {
  final uri = Uri.parse(link);
  if (uri.scheme != 'weft' || uri.host != 'chat') return null;
  if (uri.pathSegments.length != 1) return null;
  return Uri.decodeComponent(uri.pathSegments.single);
}

void main() {
  group('group key', () {
    test('both legs of a merged chat land in one thread', () {
      final merged = mergedChat();
      final whatsapp = render(
        message: msg(
          eventId: r'$wa_1',
          roomId: '!wa:example.org',
          network: ChatNetwork.whatsapp,
        ),
        forChat: merged,
      );
      final signal = render(
        message: msg(
          eventId: r'$sg_1',
          roomId: '!sg:example.org',
          network: ChatNetwork.signal,
        ),
        forChat: merged,
      );

      expect(whatsapp.groupKey, signal.groupKey);
      expect(whatsapp.groupKey, 'merged:contact_1');
      // The room ids differ, which is exactly the trap: keying on those would
      // have produced two threads for one person.
      expect(whatsapp.roomId, isNot(signal.roomId));
    });

    test('genuinely different chats do not share a thread', () {
      final grace = render(forChat: chat(id: '!grace:example.org'));
      final hopper = render(forChat: chat(id: '!hopper:example.org'));
      expect(grace.groupKey, isNot(hopper.groupKey));
    });

    test('a merged chat does not collide with either source room', () {
      final merged = notificationGroupKey(mergedChat());
      expect(merged, isNot('!wa:example.org'));
      expect(merged, isNot('!sg:example.org'));
    });

    test('the iOS thread id is the Android group key', () {
      final content = render(forChat: mergedChat());
      expect(content.threadId, content.groupKey);
    });

    test('the group key is the chat id, never the contact id', () {
      // Two group chats have no contact id at all; keying on one would collapse
      // every group in the inbox into a single thread.
      final one = render(forChat: chat(id: '!standup:example.org'));
      final two = render(forChat: chat(id: '!lunch:example.org'));
      expect({one.groupKey, two.groupKey}, hasLength(2));
    });
  });

  group('deep link', () {
    test('a room id round-trips through the link', () {
      final content = render(forChat: chat(id: '!abc:example.org'));
      // `!` is a legal path character and `Uri.encodeComponent` leaves it
      // alone; the `:` is the one that has to be escaped.
      expect(content.deepLink, 'weft://chat/!abc%3Aexample.org');
      expect(chatIdFromLink(content.deepLink), '!abc:example.org');
    });

    test('a merged id round-trips, colon and all', () {
      final content = render(forChat: mergedChat());
      expect(chatIdFromLink(content.deepLink), 'merged:contact_1');
    });

    test('every leg of a merged chat opens the merged conversation', () {
      final merged = mergedChat();
      final whatsapp = render(
        message: msg(roomId: '!wa:example.org'),
        forChat: merged,
      );
      final signal = render(
        message: msg(roomId: '!sg:example.org', network: ChatNetwork.signal),
        forChat: merged,
      );
      expect(whatsapp.deepLink, signal.deepLink);
      expect(chatIdFromLink(signal.deepLink), merged.id);
    });
  });

  group('body rendering', () {
    test('a text message uses its body', () {
      expect(render(message: msg(body: 'on my way')).body, 'on my way');
    });

    test('a voice note uses the transcript when one exists', () {
      final content = render(
        message: msg(
          kind: MessageKind.voice,
          body: '',
          transcript: 'running ten minutes late',
        ),
      );
      expect(content.body, 'running ten minutes late');
    });

    test('a voice note without a transcript says so', () {
      final content = render(
        message: msg(kind: MessageKind.voice, body: 'Voice note.ogg'),
      );
      expect(content.body, 'Voice message');
    });

    test('an image is labelled and keeps its filename', () {
      final content = render(
        message: msg(kind: MessageKind.image, body: 'IMG_4021.jpg'),
      );
      expect(content.body, 'Photo · IMG_4021.jpg');
    });

    test('a video and a file are labelled the same way', () {
      expect(
        render(
          message: msg(kind: MessageKind.video, body: 'clip.mp4'),
        ).body,
        'Video · clip.mp4',
      );
      expect(
        render(
          message: msg(kind: MessageKind.file, body: 'q3.pdf'),
        ).body,
        'File · q3.pdf',
      );
    });

    test('media with no body falls back to the bare label', () {
      expect(
        render(
          message: msg(kind: MessageKind.image, body: ''),
        ).body,
        'Photo',
      );
    });

    test('a location has no filename to show', () {
      expect(
        render(
          message: msg(kind: MessageKind.location, body: 'Pin'),
        ).body,
        'Location',
      );
    });

    test('an empty text body still says something', () {
      expect(render(message: msg(body: '  ')).body, 'New message');
    });

    test('a very long body is truncated rather than carried whole', () {
      final long = List.filled(200, 'lorem').join(' ');
      final body = render(message: msg(body: long)).body;
      expect(body.length, lessThanOrEqualTo(kMaxNotificationBodyLength + 1));
      expect(body, endsWith('…'));
      // Cut at a word boundary, not mid-word.
      expect(body, isNot(contains('lore…')));
    });
  });

  group('preview suppression', () {
    test('previews off degrades the body but still notifies', () {
      final content = render(
        message: msg(body: 'the code is 4821'),
        policy: NotificationPolicy(showPreviews: false),
      );
      expect(content.body, 'New message');
      expect(content.body, isNot(contains('4821')));
    });

    test('previews off hides a transcript too', () {
      final content = render(
        message: msg(
          kind: MessageKind.voice,
          body: '',
          transcript: 'the code is 4821',
        ),
        policy: NotificationPolicy(showPreviews: false),
      );
      expect(content.body, 'New message');
    });

    test('the title and sender survive, so the user knows who it was', () {
      final content = render(
        forChat: chat(title: 'Grace Hopper'),
        policy: NotificationPolicy(showPreviews: false),
      );
      expect(content.title, 'Grace Hopper');
      expect(content.senderName, 'Grace');
    });

    test('a degraded body degrades the summary with it', () {
      final policy = NotificationPolicy(showPreviews: false);
      final summary = summarise([
        render(
          message: msg(eventId: r'$1', body: 'secret'),
          policy: policy,
        ),
        render(
          message: msg(eventId: r'$2', body: 'also secret'),
          policy: policy,
        ),
      ]);
      expect(summary!.lines.join(), isNot(contains('secret')));
    });
  });

  group('sender disambiguation', () {
    test('a merged chat names the network', () {
      final merged = mergedChat();
      final whatsapp = render(forChat: merged);
      final signal = render(
        message: msg(network: ChatNetwork.signal),
        forChat: merged,
      );
      expect(whatsapp.senderName, 'Grace (WhatsApp)');
      expect(signal.senderName, 'Grace (Signal)');
      expect(whatsapp.senderName, isNot(signal.senderName));
    });

    test('a single-source chat does not', () {
      expect(render().senderName, 'Grace');
    });

    test('the caller can force disambiguation either way', () {
      expect(render(disambiguateSender: true).senderName, 'Grace (WhatsApp)');
      expect(
        render(forChat: mergedChat(), disambiguateSender: false).senderName,
        'Grace',
      );
    });

    test('a ghost with no display name falls back to the network', () {
      final content = render(message: msg(senderName: '   '));
      expect(content.senderName, 'WhatsApp');
    });
  });

  group('the rest of the payload', () {
    test('the title is the chat, the sender is the sender', () {
      final content = render(
        message: msg(senderName: 'Grace'),
        forChat: chat(title: 'Deploy squad', isGroup: true),
      );
      expect(content.title, 'Deploy squad');
      expect(content.senderName, 'Grace');
    });

    test('a DM borrows the chat avatar, a group does not', () {
      expect(
        render(
          forChat: chat(avatarUrl: 'mxc://example.org/grace'),
        ).senderAvatarUrl,
        'mxc://example.org/grace',
      );
      expect(
        render(
          forChat: chat(avatarUrl: 'mxc://example.org/room', isGroup: true),
        ).senderAvatarUrl,
        isNull,
      );
    });

    test('an explicit avatar wins over the chat one', () {
      final content = render(
        forChat: chat(avatarUrl: 'mxc://example.org/chat'),
        senderAvatarUrl: 'mxc://example.org/sender',
      );
      expect(content.senderAvatarUrl, 'mxc://example.org/sender');
    });

    test('the source room is carried for the mark-read action', () {
      final content = render(
        message: msg(roomId: '!wa:example.org'),
        forChat: mergedChat(),
      );
      // The group key names a conversation no homeserver has heard of; the read
      // marker has to go to the room the message was actually in.
      expect(content.roomId, '!wa:example.org');
      expect(content.groupKey, 'merged:contact_1');
    });

    test('a mention is carried through from the decision', () {
      expect(render().isMention, isFalse);
      expect(
        render(decision: const NotifyDecision(mentioned: true)).isMention,
        isTrue,
      );
      expect(
        render(decision: const SilentDecision(mentioned: true)).isMention,
        isTrue,
      );
    });

    test('timestamp and network come from the message', () {
      final at = DateTime.utc(2026, 1, 15, 20, 30);
      final content = render(
        message: msg(timestamp: at, network: ChatNetwork.signal),
        forChat: mergedChat(),
      );
      expect(content.timestamp, at);
      expect(content.network, ChatNetwork.signal);
    });
  });

  group('summarisation', () {
    /// [count] messages a minute apart, newest last.
    List<NotificationContent> batch(int count, {Chat? forChat}) => [
      for (var i = 0; i < count; i++)
        render(
          message: msg(
            eventId: '\$event_$i',
            body: 'message $i',
            timestamp: now.add(Duration(minutes: i)),
          ),
          forChat: forChat,
        ),
    ];

    test('nothing summarises to nothing', () {
      expect(summarise(const []), isNull);
    });

    test('one message keeps its own text', () {
      final summary = summarise(batch(1))!;
      expect(summary.count, 1);
      expect(summary.body, 'message 0');
      expect(summary.lines, ['Grace: message 0']);
      expect(summary.hiddenCount, 0);
    });

    test('two messages count', () {
      final summary = summarise(batch(2))!;
      expect(summary.count, 2);
      expect(summary.body, '2 new messages');
      expect(summary.lines, ['Grace: message 0', 'Grace: message 1']);
      expect(summary.hiddenCount, 0);
    });

    test('a backfill of twenty collapses to one row', () {
      final summary = summarise(batch(20))!;
      expect(summary.count, 20);
      expect(summary.body, '20 new messages');
      expect(summary.lines, hasLength(kMaxSummaryLines));
      expect(summary.hiddenCount, 20 - kMaxSummaryLines);
      // The most recent messages are the ones spelled out, oldest of them
      // first, so the list reads like the conversation.
      expect(summary.lines.first, 'Grace: message 15');
      expect(summary.lines.last, 'Grace: message 19');
    });

    test('the summary carries the newest message forward', () {
      final summary = summarise(batch(5))!;
      expect(summary.latest.body, 'message 4');
      expect(summary.timestamp, now.add(const Duration(minutes: 4)));
      expect(summary.title, 'Grace');
      expect(summary.groupKey, '!room:example.org');
      expect(summary.deepLink, 'weft://chat/!room%3Aexample.org');
    });

    test('an out-of-order batch summarises the same way', () {
      final ordered = batch(4);
      final shuffled = [ordered[2], ordered[0], ordered[3], ordered[1]];
      expect(summarise(shuffled)!.lines, summarise(ordered)!.lines);
    });

    test('a merged chat summarises both networks as one conversation', () {
      final merged = mergedChat();
      final summary = summarise([
        render(
          message: msg(eventId: r'$wa', body: 'from whatsapp'),
          forChat: merged,
        ),
        render(
          message: msg(
            eventId: r'$sg',
            body: 'from signal',
            network: ChatNetwork.signal,
            timestamp: now.add(const Duration(minutes: 1)),
          ),
          forChat: merged,
        ),
      ])!;

      expect(summary.count, 2);
      expect(summary.body, '2 new messages');
      expect(summary.networks, {ChatNetwork.whatsapp, ChatNetwork.signal});
      expect(summary.lines, [
        'Grace (WhatsApp): from whatsapp',
        'Grace (Signal): from signal',
      ]);
    });

    test('a mention anywhere in the batch marks the summary', () {
      final summary = summarise([
        ...batch(2),
        render(
          message: msg(eventId: r'$mention', body: 'Ada can you look'),
          decision: const NotifyDecision(mentioned: true),
        ),
      ])!;
      expect(summary.containsMention, isTrue);
      expect(summarise(batch(2))!.containsMention, isFalse);
    });

    test('a newline in a body does not become a second line', () {
      final summary = summarise([
        render(message: msg(body: 'first line\nsecond line')),
      ])!;
      expect(summary.lines.single, 'Grace: first line second line');
    });

    test('the line cap is adjustable for surfaces that show more', () {
      expect(summarise(batch(20), maxLines: 8)!.lines, hasLength(8));
    });
  });
}
