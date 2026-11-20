import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_share/weft_share.dart';

import 'support/fixtures.dart';

/// Ranks [chats] with the fixture clock, so each test states only the thing it
/// is about.
List<ShareTargetSlot> rank(
  List<Chat> chats, {
  ShareContent content = const ShareContent(),
  Map<String, ChatShareActivity> activity = const {},
  int maxSlots = kMaxShareTargetSlots,
  ShareTargetRanker? ranker,
}) {
  return (ranker ?? const ShareTargetRanker()).rank(
    chats,
    now: now,
    content: content,
    activity: activity,
    maxSlots: maxSlots,
  );
}

void main() {
  group('recency', () {
    test('orders a fresh account with no send history at all', () {
      final slots = rank([
        chat(id: 'stale', lastMessageAt: ago(const Duration(days: 30))),
        chat(id: 'fresh', lastMessageAt: ago(const Duration(minutes: 2))),
        chat(id: 'middling', lastMessageAt: ago(const Duration(days: 3))),
      ]);

      expect(chatIdsOf(slots), ['fresh', 'middling', 'stale']);
    });

    test('a chat that has never been messaged scores zero, not last', () {
      // Zero is the floor, so a silent chat sorts below anything with a
      // timestamp — but by the tie-break, not by being pushed off the list.
      final slots = rank([
        chat(id: 'silent'),
        chat(id: 'ancient', lastMessageAt: ago(const Duration(days: 400))),
      ]);

      expect(chatIdsOf(slots), ['ancient', 'silent']);
    });

    test(
      'a timestamp in the future decays to 1 rather than being rejected',
      () {
        // A bridged message carries the remote network's send time, and a phone
        // a minute behind the homeserver produces one routinely.
        const ranker = ShareTargetRanker();
        final skewed = chat(
          id: 'skewed',
          lastMessageAt: now.add(const Duration(minutes: 1)),
        );
        final current = chat(id: 'current', lastMessageAt: now);

        expect(
          ranker.scoreFor(skewed, now: now),
          ranker.scoreFor(current, now: now),
        );
      },
    );

    test('halfLife is what "how long ago" is measured in', () {
      const ranker = ShareTargetRanker(halfLife: Duration(days: 7));
      final week = chat(id: 'a', lastMessageAt: ago(const Duration(days: 7)));

      // 0.6 * 0.5, i.e. recencyWeight times one half-life of decay.
      expect(ranker.scoreFor(week, now: now), closeTo(0.3, 1e-9));
    });
  });

  group('recency vs frequency', () {
    test('a habit outranks a slightly more recent one-off', () {
      final slots = rank(
        [
          chat(id: 'oneoff', lastMessageAt: ago(const Duration(days: 3))),
          chat(id: 'habit', lastMessageAt: ago(const Duration(days: 4))),
        ],
        activity: {'habit': sends(40, since: const Duration(days: 4))},
      );

      expect(chatIdsOf(slots), ['habit', 'oneoff']);
    });

    test('frequency cannot rescue a chat that has gone quiet', () {
      // The whole point of decaying the send count: a work group that was the
      // entirety of last quarter must not outrank the person messaged minutes
      // ago, forever.
      final slots = rank(
        [
          chat(
            id: 'lastquarter',
            lastMessageAt: ago(const Duration(days: 120)),
          ),
          chat(id: 'justnow', lastMessageAt: ago(const Duration(minutes: 5))),
        ],
        activity: {'lastquarter': sends(500, since: const Duration(days: 120))},
      );

      expect(chatIdsOf(slots), ['justnow', 'lastquarter']);
    });

    test('recency outweighs frequency at equal age', () {
      const ranker = ShareTargetRanker();
      final at = ago(const Duration(hours: 1));
      final quiet = chat(id: 'quiet', lastMessageAt: at);

      // Frequency maxed out is worth 0.4; recency maxed out is worth 0.6.
      final maxedFrequency = ranker.scoreFor(
        quiet,
        now: now,
        activity: ChatShareActivity(sendCount: 100000, lastSentAt: at),
      );
      expect(maxedFrequency, lessThan(0.6 + 0.4));
      expect(
        maxedFrequency - ranker.scoreFor(quiet, now: now),
        closeTo(0.4, 0.001),
      );
    });

    test(
      'frequency saturates, so the first sends are the ones worth ranking',
      () {
        const ranker = ShareTargetRanker();
        final target = chat(id: 'a', lastMessageAt: now);
        double scoreAt(int count) => ranker.scoreFor(
          target,
          now: now,
          activity: ChatShareActivity(sendCount: count, lastSentAt: now),
        );

        final earlyGap = scoreAt(5) - scoreAt(1);
        final lateGap = scoreAt(500) - scoreAt(100);

        expect(earlyGap, greaterThan(lateGap * 5));
      },
    );

    test('a chat missing from the activity map ranks on recency alone', () {
      // The state of every chat the user has only ever read.
      const ranker = ShareTargetRanker();
      final unread = chat(id: 'a', lastMessageAt: ago(const Duration(days: 1)));

      expect(
        ranker.scoreFor(unread, now: now, activity: ChatShareActivity.none),
        ranker.scoreFor(unread, now: now),
      );
    });

    test('a send count with no lastSentAt contributes nothing', () {
      const ranker = ShareTargetRanker();
      final target = chat(id: 'a', lastMessageAt: now);

      expect(
        ranker.scoreFor(
          target,
          now: now,
          activity: const ChatShareActivity(sendCount: 900),
        ),
        ranker.scoreFor(target, now: now),
      );
    });
  });

  group('pinned', () {
    test(
      'a pinned chat with no history beats the chat messaged seconds ago',
      () {
        final slots = rank([
          chat(id: 'hot', lastMessageAt: ago(const Duration(seconds: 5))),
          chat(id: 'pinned', pinned: true),
        ]);

        expect(chatIdsOf(slots), ['pinned', 'hot']);
      },
    );

    test('pinning is a tier, not a bonus any score can climb past', () {
      final slots = rank(
        [
          chat(id: 'busiest', lastMessageAt: now),
          chat(
            id: 'pinned',
            pinned: true,
            lastMessageAt: ago(const Duration(days: 90)),
          ),
        ],
        activity: {'busiest': sends(10000)},
      );

      expect(chatIdsOf(slots).first, 'pinned');
    });

    test('pinned chats are ordered among themselves by score', () {
      final slots = rank([
        chat(
          id: 'p_old',
          pinned: true,
          lastMessageAt: ago(const Duration(days: 10)),
        ),
        chat(
          id: 'p_new',
          pinned: true,
          lastMessageAt: ago(const Duration(hours: 1)),
        ),
        chat(id: 'unpinned', lastMessageAt: now),
      ]);

      expect(chatIdsOf(slots), ['p_new', 'p_old', 'unpinned']);
    });

    test('the pinned flag rides along on the slot', () {
      final slots = rank([chat(id: 'p', pinned: true), chat(id: 'u')]);

      expect(slots.map((s) => s.pinned), [true, false]);
    });
  });

  group('capability filter', () {
    test('a Signal-only chat is not offered a video Signal will refuse', () {
      final slots = rank([
        chat(id: 'signal', networks: [ChatNetwork.signal]),
        chat(id: 'matrix', networks: [ChatNetwork.matrix]),
      ], content: fileShare('video/mp4', 200 * mib));

      expect(chatIdsOf(slots), ['matrix']);
    });

    test('the cap is inclusive: exactly at the limit is still offered', () {
      final signalOnly = [
        chat(id: 'signal', networks: [ChatNetwork.signal]),
      ];

      expect(
        chatIdsOf(rank(signalOnly, content: fileShare('video/mp4', 100 * mib))),
        ['signal'],
      );
      expect(
        rank(signalOnly, content: fileShare('video/mp4', 100 * mib + 1)),
        isEmpty,
      );
    });

    test('a network that does not carry the kind at all is filtered', () {
      // Bluesky chat takes images and nothing else — a PDF is not a size
      // problem, it is a kind problem.
      final slots = rank([
        chat(id: 'bluesky', networks: [ChatNetwork.bluesky]),
        chat(id: 'telegram', networks: [ChatNetwork.telegram]),
      ], content: fileShare('application/pdf', 12 * kib));

      expect(chatIdsOf(slots), ['telegram']);
    });

    test('one capable leg is enough to keep a merged chat', () {
      // canReach is an any(), not an every(): the sheet offers the chat and
      // then offers the network chip that can actually carry it.
      final slots = rank([
        chat(id: 'merged', networks: [ChatNetwork.signal, ChatNetwork.matrix]),
      ], content: fileShare('video/mp4', 500 * mib));

      expect(chatIdsOf(slots), ['merged']);
    });

    test('every file has to clear the cap, not just the first', () {
      // A share is one gesture. Taking four of five files and failing on the
      // fifth is worse than not offering the target.
      final slots = rank(
        [
          chat(id: 'signal', networks: [ChatNetwork.signal]),
        ],
        content: ShareContent.files([
          item('image/jpeg', 2 * mib),
          item('video/mp4', 300 * mib),
        ]),
      );

      expect(slots, isEmpty);
    });

    test('a text-only share never narrows the target list', () {
      // Every network Weft surfaces carries text, including the ones whose
      // attachment table is nearly empty.
      final slots = rank([
        chat(id: 'bluesky', networks: [ChatNetwork.bluesky]),
        chat(id: 'sms', networks: [ChatNetwork.sms]),
      ], content: const ShareContent.text('https://example.org'));

      expect(chatIdsOf(slots), ['bluesky', 'sms']);
    });

    test('empty content disables the filter, which is the publisher case', () {
      // The Android shortcut publisher ranks with no share in flight and must
      // offer everything: the file it will be handed is not knowable yet.
      final slots = rank([
        chat(id: 'bluesky', networks: [ChatNetwork.bluesky]),
        chat(id: 'sms', networks: [ChatNetwork.sms]),
      ]);

      expect(chatIdsOf(slots), ['bluesky', 'sms']);
    });

    test('an unknown network is permissive rather than hidden', () {
      final slots = rank([
        chat(id: 'mystery', networks: [ChatNetwork.unknown]),
      ], content: fileShare('application/zip', 900 * mib));

      expect(chatIdsOf(slots), ['mystery']);
    });

    test('the filter removes targets, it never reorders them', () {
      final chats = [
        chat(id: 'a', lastMessageAt: ago(const Duration(hours: 1))),
        chat(
          id: 'bluesky',
          networks: [ChatNetwork.bluesky],
          lastMessageAt: ago(const Duration(minutes: 1)),
        ),
        chat(id: 'c', lastMessageAt: ago(const Duration(days: 2))),
      ];

      expect(chatIdsOf(rank(chats)), ['bluesky', 'a', 'c']);
      expect(
        chatIdsOf(rank(chats, content: fileShare('application/pdf', 1 * kib))),
        ['a', 'c'],
      );
    });

    test('an override replaces the default entry entirely', () {
      const strict = ShareTargetRanker(
        capabilities: NetworkShareCapabilities({
          ChatNetwork.matrix: NetworkShareCapability(
            network: ChatNetwork.matrix,
            maxAttachmentBytes: 1 * mib,
          ),
        }),
      );

      expect(
        rank(
          [chat(id: 'matrix')],
          content: fileShare('image/png', 2 * mib),
          ranker: strict,
        ),
        isEmpty,
      );
      expect(
        chatIdsOf(
          rank(
            [chat(id: 'matrix')],
            content: fileShare('image/png', 512 * kib),
            ranker: strict,
          ),
        ),
        ['matrix'],
      );
    });

    test('the filter judges the resolved mime type, not a shape', () {
      // ShareItem.kind is messageKindFor, so the table is consulted per kind.
      expect(item('video/quicktime', 1).kind, MessageKind.video);
      expect(item('application/pdf', 1).kind, MessageKind.file);

      final twitterOnly = [
        chat(id: 'twitter', networks: [ChatNetwork.twitter]),
      ];
      expect(
        chatIdsOf(rank(twitterOnly, content: fileShare('video/mp4', 2 * mib))),
        ['twitter'],
      );
      expect(
        rank(twitterOnly, content: fileShare('application/pdf', 2 * kib)),
        isEmpty,
        reason: 'X DMs take pictures and video, not documents',
      );
    });

    test(
      'an unresolvable type reads as a document, which is why bytes sniff',
      () {
        // With no bytes to hand, `application/octet-stream` is a file — so a
        // mislabelled 90 MB video would be judged against the document row.
        // ShareItem.fromSource exists to stop that happening where bytes exist;
        // the ranker itself only ever sees the resolved answer.
        expect(item('application/octet-stream', 1).kind, MessageKind.file);
        expect(
          rank([
            chat(id: 'twitter', networks: [ChatNetwork.twitter]),
          ], content: fileShare('application/octet-stream', 1 * kib)),
          isEmpty,
        );
      },
    );
  });

  group('eligibility', () {
    test('archived chats are never published', () {
      final slots = rank([
        chat(id: 'archived', archived: true, lastMessageAt: now),
        chat(id: 'live', lastMessageAt: ago(const Duration(days: 5))),
      ]);

      expect(chatIdsOf(slots), ['live']);
    });

    test('a chat request is published only once it is accepted', () {
      // A shortcut hands the name to the launcher and the voice assistant;
      // a stranger's should not get there before the user has said yes.
      final slots = rank([
        chat(
          id: 'pending',
          request: ChatRequestState.pending,
          lastMessageAt: now,
        ),
        chat(
          id: 'declined',
          request: ChatRequestState.declined,
          lastMessageAt: now,
        ),
        chat(
          id: 'accepted',
          request: ChatRequestState.accepted,
          lastMessageAt: now,
        ),
      ]);

      expect(chatIdsOf(slots), ['accepted']);
    });

    test('a chat with no sources is never published', () {
      // It exists transiently while a merge is rebuilt; its shortcut would open
      // a conversation with nowhere to send.
      final slots = rank([sourcelessChat(id: 'rebuilding'), chat(id: 'live')]);

      expect(chatIdsOf(slots), ['live']);
    });

    test('an empty inbox ranks to an empty list', () {
      expect(rank(const []), isEmpty);
    });
  });

  group('tie-breaking', () {
    test(
      'a fresh install, where every chat scores exactly zero, is ordered',
      () {
        final slots = rank([
          chat(id: '!c:example.org', title: 'Charlie'),
          chat(id: '!a:example.org', title: 'alice'),
          chat(id: '!b:example.org', title: 'Bob'),
        ]);

        expect(chatIdsOf(slots), [
          '!a:example.org',
          '!b:example.org',
          '!c:example.org',
        ]);
      },
    );

    test('titles tie-break case-insensitively', () {
      final slots = rank([
        chat(id: '!z:example.org', title: 'zoe'),
        chat(id: '!a:example.org', title: 'Aaron'),
      ]);

      expect(chatIdsOf(slots), ['!a:example.org', '!z:example.org']);
    });

    test('identical titles fall through to the id', () {
      final slots = rank([
        chat(id: '!second:example.org', title: 'Support'),
        chat(id: '!first:example.org', title: 'Support'),
      ]);

      expect(chatIdsOf(slots), ['!first:example.org', '!second:example.org']);
    });

    test('input order does not change output order', () {
      // List.sort is not stable, and an unstable tie means the published set
      // churns on every inbox tick for no reason a user could see — precisely
      // the launcher thrash the publish diff exists to avoid.
      final chats = [
        chat(id: '!a:example.org', title: 'Ann'),
        chat(id: '!b:example.org', title: 'Bo'),
        chat(id: '!c:example.org', title: 'Cy'),
        chat(id: '!d:example.org', title: 'Di', lastMessageAt: now),
        chat(id: '!e:example.org', title: 'Ed'),
      ];
      final expected = chatIdsOf(rank(chats));

      expect(chatIdsOf(rank(chats.reversed.toList())), expected);
      expect(chatIdsOf(rank([...chats.skip(2), ...chats.take(2)])), expected);
    });

    test('ranking the same inbox twice publishes identical slots', () {
      // Slot equality covers every field including rank; this is the property
      // the publish diff is built on.
      final chats = [
        chat(id: 'a', lastMessageAt: ago(const Duration(hours: 3))),
        chat(id: 'b', pinned: true),
        chat(id: 'c'),
      ];

      expect(rank(chats), rank(chats));
    });

    test('ranking does not reorder the list it was handed', () {
      // The caller's list is the inbox, which several other widgets are
      // rendering from at the same time.
      final chats = [
        chat(id: 'z', lastMessageAt: ago(const Duration(days: 9))),
        chat(id: 'a', lastMessageAt: now),
      ];

      expect(chatIdsOf(rank(chats)), ['a', 'z']);
      expect(chats.map((c) => c.id), ['z', 'a']);
    });
  });

  group('cap', () {
    test('defaults to kMaxShareTargetSlots', () {
      final slots = rank([
        for (var i = 0; i < 20; i++)
          chat(id: 'chat_$i', title: 'Chat ${i.toString().padLeft(2, '0')}'),
      ]);

      expect(kMaxShareTargetSlots, 8);
      expect(slots, hasLength(8));
      expect(chatIdsOf(slots).first, 'chat_0');
      expect(chatIdsOf(slots).last, 'chat_7');
    });

    test('the cap keeps the top of the order, not an arbitrary slice', () {
      final slots = rank([
        for (var i = 0; i < 10; i++)
          chat(
            id: 'chat_$i',
            lastMessageAt: ago(Duration(days: 10 - i)),
          ),
      ], maxSlots: 3);

      expect(chatIdsOf(slots), ['chat_9', 'chat_8', 'chat_7']);
    });

    test('a surface can ask for fewer than the default', () {
      expect(
        rank([for (var i = 0; i < 6; i++) chat(id: 'c$i')], maxSlots: 4),
        hasLength(4),
      );
    });

    test('asking for none, or fewer than none, publishes nothing', () {
      final chats = [for (var i = 0; i < 6; i++) chat(id: 'c$i')];

      expect(rank(chats, maxSlots: 0), isEmpty);
      expect(rank(chats, maxSlots: -1), isEmpty);
    });

    test('a cap larger than the inbox is not padded', () {
      expect(rank([chat(id: 'only')], maxSlots: 8), hasLength(1));
    });
  });

  group('published slot', () {
    test('rank is the position, numbered from zero and dense', () {
      final slots = rank([
        for (var i = 0; i < 5; i++)
          chat(
            id: 'chat_$i',
            lastMessageAt: ago(Duration(days: i + 1)),
          ),
      ]);

      expect(slots.map((s) => s.rank), [0, 1, 2, 3, 4]);
    });

    test('carries the id, link and networks the platforms need', () {
      final slots = rank([
        chat(
          id: '!room:example.org',
          title: 'Grace Hopper',
          networks: [ChatNetwork.signal, ChatNetwork.whatsapp],
          avatarUrl: 'mxc://example.org/abc',
          isGroup: true,
        ),
      ]);

      final slot = slots.single;
      expect(slot.chatId, '!room:example.org');
      expect(slot.id, shareTargetSlotId('!room:example.org'));
      // Sanitised: `!` and `:` both become `_`, `.` survives. This string is
      // what the notification bubble names too, so it is asserted literally.
      expect(slot.id, 'chat__room_example.org');
      expect(slot.link, chatDeepLink('!room:example.org'));
      expect(slot.link, 'weft://chat/!room%3Aexample.org');
      expect(slot.longLabel, 'Grace Hopper');
      expect(slot.avatarUrl, 'mxc://example.org/abc');
      expect(slot.isGroup, isTrue);
      // Stable enum order, not source order.
      expect(slot.networks, [ChatNetwork.whatsapp, ChatNetwork.signal]);
    });

    test('a merged chat gets one slot, from the merged id', () {
      final slots = rank([
        chat(
          id: 'merged:contact_7',
          title: 'Grace',
          networks: [ChatNetwork.whatsapp, ChatNetwork.signal],
        ),
      ]);

      expect(slots, hasLength(1));
      expect(slots.single.id, 'chat_merged_contact_7');
      expect(slots.single.chatId, 'merged:contact_7');
    });

    test('labels are cut to something a launcher will not mangle', () {
      expect(shortShareLabel('Alexandra Kalinowska'), 'Alexandra');
      expect(shortShareLabel('Bo'), 'Bo');
      expect(shortShareLabel('Unpronounceablename'), 'Unpronounce…');
      expect(shortShareLabel('   '), kUnnamedShareTarget);
      expect(longShareLabel(''), kUnnamedShareTarget);
      expect(longShareLabel('x' * 60), '${'x' * 47}…');
    });

    test('a short first word keeps the words after it', () {
      // Found on an emulator, not by reading: the launcher's Direct Share row
      // showed two conversations captioned "Dr." and "Prof.". Cutting at the
      // *first* word boundary is right for "Alexandra Kalinowska" and useless
      // for a title, which is a word that names nobody — and every doctor in
      // the inbox gets the identical face caption.
      expect(shortShareLabel('Dr. James Anderson'), 'Dr. James');
      expect(shortShareLabel('Prof. David Wilson'), 'Prof. David');
      expect(shortShareLabel('Ada B. Lovelace'), 'Ada B.');
    });

    test('a word that does not fit stops the label, and does not skip', () {
      // "Jo" fits in what is left, and appending it would read as a name the
      // conversation does not have. The cut is a prefix of the title or it is
      // not a name at all.
      expect(shortShareLabel('Kristofferson Jo'), 'Kristoffers…');
      expect(shortShareLabel('Anna Kalinowska Jo'), 'Anna');
    });

    test('the word-boundary cut never exceeds the cap', () {
      for (final title in const [
        'Dr. James Anderson',
        'Prof. David Wilson',
        'Alexandra Kalinowska',
        'Ada B. Lovelace',
        'a b c d e f g h i j k l m n',
      ]) {
        expect(
          shortShareLabel(title).runes.length,
          lessThanOrEqualTo(kMaxShortLabelLength),
          reason: title,
        );
      }
    });

    test('a title of emoji is not split into a lone surrogate', () {
      // Cut on code points, not UTF-16 units: half a surrogate pair renders as
      // a replacement glyph on some launchers and is refused outright by
      // others. Fourteen code points, so the cut lands mid-string.
      final label = shortShareLabel('🎉' * 14);

      expect(label, '${'🎉' * 11}…');
      expect(label.runes.length, kMaxShortLabelLength);
    });
  });
}
