import 'package:characters/characters.dart';
import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_snapshot/weft_snapshot.dart';

import 'support/fixtures.dart';

void main() {
  group('the gate', () {
    test('a disabled policy produces an empty snapshot, not a partial one', () {
      // The distinction the test name draws is the whole point: "off" must not
      // mean "off for the fields somebody remembered to check". A snapshot that
      // dropped previews but kept sixteen titles and unread counts would be a
      // privacy setting that discloses the shape of someone's inbox to anyone
      // holding their phone.
      final snapshot = build([
        chat(unreadCount: 4, lastMessage: msg(body: 'secret')),
        mergedChat(unreadCount: 9, lastMessage: msg(body: 'also secret')),
      ], policy: SnapshotPolicy.off);

      expect(snapshot.rows, isEmpty);
      expect(snapshot.totalUnread, 0);
      expect(snapshot.enabled, isFalse);
    });

    test('the switched-off payload is dated, so it can go stale like any '
        'other', () {
      final snapshot = build(const [], policy: SnapshotPolicy.off);

      expect(snapshot.generatedAt, now);
      expect(snapshot.generatedAt.isUtc, isTrue);
      expect(snapshot.isStaleAt(now), isFalse);
    });

    test('an enabled policy with no content flags carries counts and nothing '
        'else', () {
      // `SnapshotPolicy(enabled: true)` is what the surfaces screen produces
      // from the master switch alone, and it must be safe: a policy assembled
      // by naming one field discloses only what that field named.
      final snapshot = build([
        chat(
          title: 'Grace',
          unreadCount: 3,
          avatarUrl: 'mxc://example.org/grace',
          lastMessage: msg(body: 'are you coming'),
        ),
      ], policy: const SnapshotPolicy(enabled: true));

      final row = snapshot.rows.single;
      expect(row.unreadCount, 3);
      expect(row.title, kRedactedRowTitle);
      expect(row.preview, isNull);
      expect(row.senderName, isNull);
      expect(row.avatarUrl, isNull);
    });

    test('enabled with no chats is a different state from disabled', () {
      // "Nothing to show" and "switched off" are two things a surface says
      // differently, and `enabled` is the only field that tells them apart.
      final empty = build(const []);
      final off = build(const [], policy: SnapshotPolicy.off);

      expect(empty.rows, isEmpty);
      expect(off.rows, isEmpty);
      expect(empty.enabled, isTrue);
      expect(off.enabled, isFalse);
      expect(empty, isNot(off));
    });
  });

  group('preview redaction', () {
    test('previews off drops the message text and keeps the count', () {
      final snapshot = build([
        chat(unreadCount: 2, lastMessage: msg(body: 'the safe word is otter')),
      ], policy: fullPolicy.copyWith(includePreviews: false));

      final row = snapshot.rows.single;
      expect(row.preview, isNull);
      expect(row.unreadCount, 2);
      expect(row.title, 'Grace');
    });

    test('previews off leaves no trace of the body anywhere in the row', () {
      // A redaction that only clears the field it was named after is not one.
      // The row is stringified whole because the failure this guards against is
      // a body reaching a surface through some *other* field — a title built
      // from the last message, a sender name carrying the text.
      final snapshot = build([
        chat(lastMessage: msg(body: 'the safe word is otter')),
      ], policy: fullPolicy.copyWith(includePreviews: false));

      expect(
        snapshot.rows.single.toJson().toString(),
        isNot(contains('otter')),
      );
    });

    test('a redacted message previews as deleted rather than as its body', () {
      expect(previewOf(msg(body: 'oops', redacted: true)), kDeletedPreview);
    });

    test('a chat with no messages has no preview even with previews on', () {
      expect(previewOf(null), isNull);
    });

    test('previews render per kind, the way a notification body does', () {
      // Delegated to `renderNotificationBody`, so this asserts the delegation
      // rather than re-testing weft_notify's table. The `·` is the join it
      // uses, and the absence of an emoji is the rule this package inherits and
      // `ChatTile` does not.
      expect(
        previewOf(msg(kind: MessageKind.image, body: 'IMG_4021.jpg')),
        'Photo · IMG_4021.jpg',
      );
      expect(previewOf(msg(kind: MessageKind.location, body: '')), 'Location');
      expect(
        previewOf(msg(kind: MessageKind.voice, body: '')),
        'Voice message',
      );
      expect(
        previewOf(msg(kind: MessageKind.voice, transcript: 'running 10 late')),
        'running 10 late',
      );
    });

    test('a formatted body previews as its text, never as its tags', () {
      // The security half of reusing `renderNotificationBody`: a widget is
      // rendered by the system from a string this package produced, and markup
      // from a bridged network must not survive the trip.
      final preview = previewOf(
        msg(body: 'fire', formattedBody: '<b>fire</b><script>x()</script>'),
      );

      expect(preview, isNot(contains('<')));
      expect(preview, contains('fire'));
    });

    test('a multi-line paste collapses to one line', () {
      // A Glance `Text` handed three lines renders three lines into a box sized
      // for two. This is the package's own rule, not weft_notify's.
      expect(previewOf(msg(body: 'one\ntwo\n\n  three')), 'one two three');
    });
  });

  group('name redaction', () {
    test('names off redacts the title, the sender and the avatar together', () {
      // One flag covers all three because for a DM the avatar *is* the other
      // person's face: a row showing it beside "Conversation" has redacted
      // nothing at all.
      final snapshot = build([
        chat(
          title: 'Grace Hopper',
          avatarUrl: 'mxc://example.org/grace',
          lastMessage: msg(senderName: 'Grace Hopper', body: 'on my way'),
        ),
      ], policy: fullPolicy.copyWith(includeSenderNames: false));

      final row = snapshot.rows.single;
      expect(row.title, kRedactedRowTitle);
      expect(row.senderName, isNull);
      expect(row.avatarUrl, isNull);
      expect(row.toJson().toString(), isNot(contains('Grace')));
    });

    test('names off keeps the preview, which is the other switch', () {
      // "Don't show who they are" and "don't show what they said" are two
      // decisions, and clearing one must not quietly clear the other.
      final snapshot = build([
        chat(lastMessage: msg(body: 'on my way')),
      ], policy: fullPolicy.copyWith(includeSenderNames: false));

      expect(snapshot.rows.single.preview, 'on my way');
    });

    test('names on carries the title, the sender and the avatar', () {
      final snapshot = build([
        chat(
          title: 'Grace Hopper',
          avatarUrl: 'mxc://example.org/grace',
          lastMessage: msg(senderName: 'Grace Hopper'),
        ),
      ]);

      final row = snapshot.rows.single;
      expect(row.title, 'Grace Hopper');
      expect(row.senderName, 'Grace Hopper');
      expect(row.avatarUrl, 'mxc://example.org/grace');
    });

    test('a merged chat disambiguates the sender by network', () {
      // Two "Grace"s in one conversation are two things a watch user might
      // reply to, and replying to the wrong one sends over the wrong network.
      final snapshot = build([
        mergedChat(
          lastMessage: msg(senderName: 'Grace', network: ChatNetwork.signal),
        ),
      ]);

      expect(snapshot.rows.single.senderName, 'Grace (Signal)');
    });

    test('a plain chat does not append the network to the sender', () {
      final snapshot = build([chat(lastMessage: msg(senderName: 'Grace'))]);

      expect(snapshot.rows.single.senderName, 'Grace');
    });

    test('an unnamed sender falls back to the network label, not an empty '
        'string', () {
      // A bridge ghost that has not backfilled its profile. The row still needs
      // something where a name goes.
      final snapshot = build([chat(lastMessage: msg(senderName: '   '))]);

      expect(snapshot.rows.single.senderName, 'WhatsApp');
    });
  });

  group('per-network exclusion', () {
    test('an excluded network keeps its chats out entirely', () {
      final snapshot = build([
        chat(id: '!wa:example.org', networks: const [ChatNetwork.whatsapp]),
        chat(id: '!sg:example.org', networks: const [ChatNetwork.signal]),
      ], policy: fullPolicy.copyWith(excludedNetworks: const {'signal'}));

      expect(snapshot.rows.map((row) => row.chatId), ['!wa:example.org']);
    });

    test('a merged chat is dropped whole when any one leg is excluded', () {
      // Not filtered down to its allowed legs: a merged row shows one title and
      // one preview for several networks, and there is no way to render "the
      // Signal half" of it. Excluding a network has to mean its messages do not
      // leave the encrypted store, and half a merged row does not clear that.
      final snapshot = build([
        mergedChat(
          networks: const [ChatNetwork.whatsapp, ChatNetwork.signal],
          lastMessage: msg(body: 'excluded either way'),
        ),
      ], policy: fullPolicy.copyWith(excludedNetworks: const {'signal'}));

      expect(snapshot.rows, isEmpty);
    });

    test('an excluded chat is not counted in the total either', () {
      // The complication would otherwise show a badge for messages the user
      // asked never to be told about.
      final snapshot = build([
        chat(id: '!wa:example.org', unreadCount: 3),
        chat(
          id: '!sg:example.org',
          networks: const [ChatNetwork.signal],
          unreadCount: 40,
        ),
      ], policy: fullPolicy.copyWith(excludedNetworks: const {'signal'}));

      expect(snapshot.totalUnread, 3);
    });

    test('excluding every network is not the same as being switched off', () {
      // Both are empty; only one says the gate is open. The surface shows a
      // different sentence for each.
      final snapshot = build([
        chat(networks: const [ChatNetwork.whatsapp]),
      ], policy: fullPolicy.copyWith(excludedNetworks: const {'whatsapp'}));

      expect(snapshot.rows, isEmpty);
      expect(snapshot.enabled, isTrue);
    });

    test('exclusion keys on ChatNetwork.id, not on the label', () {
      // `ChatNetwork.messenger.id` is 'facebook'. A settings screen that stored
      // the label would silently stop excluding anything, and this is the test
      // that notices.
      final policy = fullPolicy.copyWith(excludedNetworks: const {'facebook'});

      expect(policy.allows(ChatNetwork.messenger), isFalse);
      expect(policy.allows(ChatNetwork.whatsapp), isTrue);
    });

    test('allows() is false for every network while the gate is shut', () {
      for (final network in ChatNetwork.values) {
        expect(SnapshotPolicy.off.allows(network), isFalse);
      }
    });
  });

  group('row cap', () {
    test('rows stop at the cap', () {
      final snapshot = build([
        for (var i = 0; i < 40; i++) chat(id: '!room$i:example.org'),
      ]);

      expect(snapshot.rows, hasLength(kDefaultSnapshotRowCap));
    });

    test('the cap takes from the front, keeping the inbox order', () {
      final snapshot = build([
        for (var i = 0; i < 10; i++) chat(id: '!room$i:example.org'),
      ], policy: fullPolicy.copyWith(maxRows: 3));

      expect(snapshot.rows.map((row) => row.chatId), [
        '!room0:example.org',
        '!room1:example.org',
        '!room2:example.org',
      ]);
    });

    test('rows are not re-sorted', () {
      // The inbox has already decided what "recent" means — pinned first, then
      // activity — and a companion surface with a different top three reads as
      // the app being wrong about the user's messages. So an out-of-order
      // timestamp is preserved, not corrected.
      final snapshot = build([
        chat(
          id: '!pinned:example.org',
          lastMessage: msg(timestamp: ago(const Duration(days: 2))),
        ),
        chat(
          id: '!recent:example.org',
          lastMessage: msg(timestamp: now),
        ),
      ]);

      expect(snapshot.rows.map((row) => row.chatId), [
        '!pinned:example.org',
        '!recent:example.org',
      ]);
    });

    test('totalUnread counts past the cap', () {
      // The seventeenth conversation's unread messages are still unread, and
      // the Lock Screen accessory shows exactly this number.
      final snapshot = build([
        for (var i = 0; i < 20; i++)
          chat(id: '!room$i:example.org', unreadCount: 2),
      ], policy: fullPolicy.copyWith(maxRows: 3));

      expect(snapshot.rows, hasLength(3));
      expect(snapshot.totalUnread, 40);
    });

    test('a cap of zero yields no rows and still a total', () {
      final snapshot = build([
        chat(unreadCount: 5),
      ], policy: fullPolicy.copyWith(maxRows: 0));

      expect(snapshot.rows, isEmpty);
      expect(snapshot.totalUnread, 5);
    });

    test('a negative cap is read as zero rather than as taking from the end', () {
      // It reaches here through a key/value store with no schema to stop it, so
      // `rowCap` clamps rather than letting `sublist` throw a RangeError inside
      // the writer.
      final snapshot = build([
        chat(unreadCount: 5),
      ], policy: fullPolicy.copyWith(maxRows: -3));

      expect(snapshot.rows, isEmpty);
      expect(snapshot.totalUnread, 5);
    });

    test('fewer chats than the cap are all kept', () {
      final snapshot = build([
        chat(id: '!a:example.org'),
        chat(id: '!b:example.org'),
      ]);

      expect(snapshot.rows, hasLength(2));
    });
  });

  group('preview truncation', () {
    test('a short preview is left exactly alone', () {
      expect(truncatePreview('short enough'), 'short enough');
    });

    test('a preview at the limit is not cut', () {
      final exact = 'a' * kMaxSnapshotPreviewLength;

      expect(truncatePreview(exact), exact);
    });

    test('a long preview is cut and marked', () {
      final preview = truncatePreview('a' * 200);

      expect(preview.characters.length, kMaxSnapshotPreviewLength + 1);
      expect(preview, endsWith('…'));
    });

    test('the cut prefers a nearby word boundary', () {
      final preview = truncatePreview('${'word ' * 30}tail');

      expect(preview, endsWith('word…'));
      expect(preview, isNot(contains('wor…')));
    });

    test('a word too long to break is cut hard rather than gutted', () {
      // The 24-cluster window: a space further back than that would leave a
      // preview visibly shorter than the box it is drawn in.
      final preview = truncatePreview('go ${'x' * 200}');

      expect(preview, startsWith('go xxx'));
      expect(preview.characters.length, kMaxSnapshotPreviewLength + 1);
    });

    test('the cut lands on a grapheme boundary, not mid-emoji', () {
      // 79 letters then a skin-tone emoji: the 80th grapheme cluster is four
      // UTF-16 code units, so a `substring(0, 80)` — which is what
      // `weft_notify._truncate` does — lands between the base emoji and its
      // modifier. In a notification shade that is a momentary broken glyph in a
      // row that scrolls away; in a widget it is a fixed box rendering `�` for
      // as long as that message is the newest one.
      final text = '${'a' * 79}👍🏽 and more text after the cut';
      final naive = text.substring(0, kMaxSnapshotPreviewLength);
      final preview = truncatePreview(text);

      expect(hasUnpairedSurrogate(naive), isTrue, reason: 'fixture must bite');
      expect(hasUnpairedSurrogate(preview), isFalse);
      expect(preview, endsWith('👍🏽…'));
    });

    test('a ZWJ sequence survives the cut whole', () {
      // A family emoji is seven code points and eleven UTF-16 units joined by
      // zero-width joiners. Cutting inside it renders as several unrelated
      // people rather than as a broken glyph, which is worse: it looks
      // deliberate.
      const family = '👩‍👩‍👧‍👦';
      final text = '${'b' * 79}$family trailing words';
      final preview = truncatePreview(text);

      expect(hasUnpairedSurrogate(preview), isFalse);
      expect(preview, endsWith('$family…'));
      expect(preview.characters.length, kMaxSnapshotPreviewLength + 1);
    });

    test('the word-boundary window is measured in graphemes', () {
      // An emoji-heavy tail costs four code units per cluster. Measured in
      // UTF-16 the window would be exhausted after six of them and the word cut
      // would silently stop happening.
      final text = 'sunset ${'🌅' * 40}';
      final preview = truncatePreview(text);

      expect(hasUnpairedSurrogate(preview), isFalse);
      expect(
        preview.characters.length,
        lessThanOrEqualTo(kMaxSnapshotPreviewLength + 1),
      );
    });

    test('a maxLength of zero or less disables the cut', () {
      // The same contract `renderNotificationBody` gained, so the two can be
      // composed without one of them truncating twice.
      final long = 'a' * 500;

      expect(truncatePreview(long, 0), long);
      expect(truncatePreview(long, -1), long);
    });

    test('a built row truncates through the real path', () {
      // Asserting through `buildSnapshot` rather than only against
      // `truncatePreview` is what proves the row builder calls it, and that
      // `renderNotificationBody`'s own 240-unit cut is not applied first.
      final preview = previewOf(msg(body: 'z' * 300))!;

      expect(preview.characters.length, kMaxSnapshotPreviewLength + 1);
      expect(preview, endsWith('…'));
    });
  });

  group('identity and the link', () {
    test('the row keys on Chat.id, including a merged one', () {
      final snapshot = build([mergedChat(contactId: 'contact_17')]);

      expect(snapshot.rows.single.chatId, 'merged:contact_17');
    });

    test("a merged chat's colon survives the deep link as one segment", () {
      // One escape apart and the link opens nothing. Glance sets this on an
      // intent and WidgetKit on a `widgetURL`, neither of which can rebuild it.
      final snapshot = build([mergedChat(contactId: 'contact_17')]);
      final uri = Uri.parse(snapshot.rows.single.link);

      expect(uri.scheme, 'weft');
      expect(uri.host, 'chat');
      expect(uri.pathSegments, ['merged:contact_17']);
    });

    test('the link is the one weft_domain produces, not a second spelling', () {
      final snapshot = build([chat(id: '!room:example.org')]);

      expect(snapshot.rows.single.link, chatDeepLink('!room:example.org'));
    });

    test('merged-ness is carried explicitly', () {
      // Carried rather than inferred from `networks.length`, because a surface
      // has to signal it at least two ways and one of them is an accessibility
      // label on a row with space for a single glyph.
      expect(build([mergedChat()]).rows.single.isMerged, isTrue);
      expect(build([chat()]).rows.single.isMerged, isFalse);
    });

    test(
      'networks come out in stable enum order whatever order they went in',
      () {
        // Two refreshes that render the glyph strip the other way round read as
        // the widget flickering.
        final snapshot = build([
          mergedChat(
            networks: const [ChatNetwork.signal, ChatNetwork.whatsapp],
          ),
        ]);

        expect(snapshot.rows.single.networks.toList(), const [
          ChatNetwork.whatsapp,
          ChatNetwork.signal,
        ]);
      },
    );

    test('the timestamp is the last message, and null without one', () {
      final at = ago(const Duration(hours: 3));

      expect(
        build([chat(lastMessage: msg(timestamp: at))]).rows.single.timestamp,
        at,
      );
      expect(build([chat()]).rows.single.timestamp, isNull);
    });
  });

  group('unread counts', () {
    test('a count above the badge cap renders as 99+', () {
      final snapshot = build([chat(unreadCount: 120)]);

      expect(snapshot.rows.single.unreadCount, 120);
      expect(snapshot.rows.single.unreadLabel, '99+');
    });

    test('the cap boundary is inclusive', () {
      // One conversation reading 99 on the phone and 99+ on the watch is two
      // surfaces disagreeing about a number neither of them computed.
      expect(build([chat(unreadCount: 99)]).rows.single.unreadLabel, '99');
      expect(build([chat(unreadCount: 100)]).rows.single.unreadLabel, '99+');
    });

    test('a negative count is floored at zero rather than rendered', () {
      final snapshot = build([chat(unreadCount: -2)]);

      expect(snapshot.rows.single.unreadCount, 0);
      expect(snapshot.totalUnread, 0);
    });
  });

  group('staleness', () {
    test('a fresh snapshot is not stale', () {
      final snapshot = build(const []);

      expect(snapshot.isStaleAt(now.add(const Duration(hours: 11))), isFalse);
    });

    test('a snapshot older than the window is stale', () {
      final snapshot = build(const []);

      expect(
        snapshot.isStaleAt(
          now.add(kSnapshotStaleAfter + const Duration(minutes: 1)),
        ),
        isTrue,
      );
    });

    test('the boundary itself is not yet stale', () {
      final snapshot = build(const []);

      expect(snapshot.isStaleAt(now.add(kSnapshotStaleAfter)), isFalse);
    });

    test('a local-time now is judged as the same instant', () {
      // The writer runs on the device's clock and the reader compares against
      // its own; a comparison that shifted by the timezone offset would call a
      // fresh snapshot stale in half the world.
      final local = DateTime(2026, 4, 1, 9);
      final snapshot = build(const [], at: local);

      expect(snapshot.generatedAt.isUtc, isTrue);
      expect(snapshot.generatedAt.isAtSameMomentAs(local), isTrue);
    });
  });

  group('palette', () {
    test('only the networks actually present travel', () {
      // The table is dead weight for the fourteen networks a given inbox does
      // not use, and it crosses the process boundary on every refresh.
      final snapshot = build([
        chat(networks: const [ChatNetwork.whatsapp]),
      ]);

      expect(snapshot.palette, {'whatsapp': ChatNetwork.whatsapp.brandColor});
    });

    test('a merged row contributes every one of its legs', () {
      final snapshot = build([
        mergedChat(networks: const [ChatNetwork.whatsapp, ChatNetwork.signal]),
      ]);

      expect(snapshot.palette.keys, containsAll(['whatsapp', 'signal']));
    });

    test('an empty snapshot carries an empty palette', () {
      expect(build(const []).palette, isEmpty);
    });
  });

  group('policy value semantics', () {
    test('two policies with the same exclusions compare equal', () {
      // The writer only writes when the snapshot differs from the last one, and
      // an exclusion set that compared by identity would make every rebuild a
      // change — a widget refresh per sync, on battery.
      const a = SnapshotPolicy(enabled: true, excludedNetworks: {'signal'});
      const b = SnapshotPolicy(enabled: true, excludedNetworks: {'signal'});

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('exclusion set order does not affect equality', () {
      final a = fullPolicy.copyWith(excludedNetworks: {'signal', 'sms'});
      final b = fullPolicy.copyWith(excludedNetworks: {'sms', 'signal'});

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith changes one field and leaves the rest', () {
      final tightened = fullPolicy.copyWith(includePreviews: false);

      expect(tightened.includePreviews, isFalse);
      expect(tightened.includeSenderNames, isTrue);
      expect(tightened.enabled, isTrue);
      expect(tightened.maxRows, kDefaultSnapshotRowCap);
    });

    test('the off constant discloses nothing', () {
      expect(SnapshotPolicy.off.enabled, isFalse);
      expect(SnapshotPolicy.off.includePreviews, isFalse);
      expect(SnapshotPolicy.off.includeSenderNames, isFalse);
    });

    test('two snapshots built from the same inbox compare equal', () {
      final chats = [chat(unreadCount: 1, lastMessage: msg())];

      expect(build(chats), build(chats));
      expect(build(chats).hashCode, build(chats).hashCode);
    });

    test('a snapshot differing only in a preview is not equal', () {
      expect(
        build([chat(lastMessage: msg(body: 'one'))]),
        isNot(build([chat(lastMessage: msg(body: 'two'))])),
      );
    });
  });
}
