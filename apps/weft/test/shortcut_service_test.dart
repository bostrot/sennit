import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/intents.dart';
import 'package:weft/app/share_providers.dart';
import 'package:weft/services/notifications/notification_presentation.dart';
import 'package:weft/services/share/shortcut_service.dart';
import 'package:weft/services/share/staged_share_reader.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_share/weft_share.dart';

import 'support/share_fixtures.dart';

/// The whole of what this file is about is *calls that do not happen*.
///
/// `ShareTargetRanker` is exhaustively covered in `packages/weft_share`, and
/// nothing here re-tests an ordering rule. What is only testable at this layer
/// is the traffic: which inbox ticks reach the launcher, which are suppressed,
/// what a device cap does to the next tick, and whether signing out actually
/// removes the names.
void main() {
  ShareShortcutService service(
    RecordingShareTargetPublisher publisher, {
    Future<String?> Function(String)? avatarLoader,
    int maxSlots = kMaxShareTargetSlots,
  }) => ShareShortcutService(
    publisher: publisher,
    avatarLoader: avatarLoader,
    maxSlots: maxSlots,
  );

  /// [count] chats, most recent first: `chat_0` a minute ago, `chat_1` two, and
  /// so on, so the ranked order is the construction order.
  List<Chat> inbox(int count) => [
    for (var i = 0; i < count; i++)
      shareChat(
        id: 'chat_$i',
        title: 'Chat $i',
        lastMessageAt: shareAgo(Duration(minutes: i + 1)),
      ),
  ];

  group('publishing', () {
    test('publishes the ranked slots on the first refresh', () async {
      final publisher = RecordingShareTargetPublisher();
      await service(publisher).refresh(inbox(3), now: shareNow);

      expect(publisher.publishes, hasLength(1));
      expect(publisher.lastChatIds, ['chat_0', 'chat_1', 'chat_2']);
      expect(publisher.last.first['id'], shareTargetSlotId('chat_0'));
      expect(publisher.last.first['link'], 'weft://chat/chat_0');
      expect(publisher.last.first['rank'], 0);
      expect(publisher.last.last['rank'], 2);
    });

    test('the slot maps are ShareTargetSlot.toJson plus iconPath', () async {
      // The Kotlin side reads these key names off a `Map<String, Any?>` with no
      // compiler between the two. A key renamed on this side is a shortcut that
      // silently fails to build on that one.
      final publisher = RecordingShareTargetPublisher();
      await service(publisher).refresh([
        shareChat(id: 'chat_0', lastMessageAt: shareAgo(const Duration(hours: 1))),
      ], now: shareNow);

      expect(publisher.last.single.keys, {
        ...ShareTargetSlot.forChat(
          shareChat(id: 'chat_0'),
        ).toJson().keys,
        'iconPath',
      });
    });

    test('a second refresh with the same inbox does not call the launcher',
        () async {
      // The reason this class exists. `watchChats` emits on read receipts,
      // typing and presence; the published set changes on almost none of them.
      final publisher = RecordingShareTargetPublisher();
      final shortcuts = service(publisher);
      final chats = inbox(3);

      await shortcuts.refresh(chats, now: shareNow);
      await shortcuts.refresh(chats, now: shareNow);
      await shortcuts.refresh([...chats], now: shareNow);

      expect(publisher.publishes, hasLength(1));
    });

    test('an unread count changing is not a republish', () async {
      // The most common tick of all, and the one that would thrash the launcher
      // hardest: nothing a shortcut renders has changed.
      final publisher = RecordingShareTargetPublisher();
      final shortcuts = service(publisher);
      final chat = shareChat(
        id: 'chat_0',
        lastMessageAt: shareAgo(const Duration(minutes: 1)),
      );

      await shortcuts.refresh([chat], now: shareNow);
      await shortcuts.refresh([
        Chat(
          id: chat.id,
          title: chat.title,
          sources: chat.sources,
          lastMessage: chat.lastMessage,
          unreadCount: 7,
        ),
      ], now: shareNow);

      expect(publisher.publishes, hasLength(1));
    });

    test('a reordering is a republish', () async {
      final publisher = RecordingShareTargetPublisher();
      final shortcuts = service(publisher);

      await shortcuts.refresh(inbox(3), now: shareNow);
      await shortcuts.refresh([
        // chat_2 has just spoken, so it goes to the top — a rank change, which
        // slot equality counts as a change precisely so this publishes.
        shareChat(
          id: 'chat_2',
          title: 'Chat 2',
          lastMessageAt: shareAgo(const Duration(seconds: 1)),
        ),
        ...inbox(2),
      ], now: shareNow);

      expect(publisher.publishes, hasLength(2));
      expect(publisher.lastChatIds, ['chat_2', 'chat_0', 'chat_1']);
    });

    test('a renamed chat republishes', () async {
      final publisher = RecordingShareTargetPublisher();
      final shortcuts = service(publisher);

      await shortcuts.refresh([
        shareChat(id: 'chat_0', title: 'Ada', lastMessageAt: shareAgo(
          const Duration(minutes: 1),
        )),
      ], now: shareNow);
      await shortcuts.refresh([
        shareChat(id: 'chat_0', title: 'Ada Lovelace', lastMessageAt: shareAgo(
          const Duration(minutes: 1),
        )),
      ], now: shareNow);

      expect(publisher.publishes, hasLength(2));
      expect(publisher.last.single['longLabel'], 'Ada Lovelace');
    });

    test('overlapping refreshes coalesce onto the newest inbox', () async {
      // Publishing awaits an avatar per slot, and the chat stream does not stop
      // ticking while it does. Every intermediate list reaching the launcher
      // would be the thrash this class exists to prevent, in slow motion.
      final publisher = RecordingShareTargetPublisher();
      final gate = Completer<String?>();
      final shortcuts = service(
        publisher,
        avatarLoader: (_) => gate.future,
      );

      final first = shortcuts.refresh([
        shareChat(
          id: 'chat_0',
          avatarUrl: 'https://example.org/a.png',
          lastMessageAt: shareAgo(const Duration(minutes: 1)),
        ),
      ], now: shareNow);
      // Both arrive while the first publish is still waiting on the avatar.
      unawaited(shortcuts.refresh(inbox(2), now: shareNow));
      final last = shortcuts.refresh(inbox(3), now: shareNow);

      gate.complete(null);
      await Future.wait([first, last]);

      expect(publisher.publishes, hasLength(2));
      expect(publisher.lastChatIds, ['chat_0', 'chat_1', 'chat_2']);
    });
  });

  group('the cap', () {
    test('never asks for more than maxSlots', () async {
      final publisher = RecordingShareTargetPublisher();
      await service(publisher, maxSlots: 4).refresh(inbox(20), now: shareNow);

      expect(publisher.last, hasLength(4));
      expect(publisher.lastChatIds.first, 'chat_0');
    });

    test('defaults to kMaxShareTargetSlots', () async {
      final publisher = RecordingShareTargetPublisher();
      await service(publisher).refresh(inbox(20), now: shareNow);

      expect(publisher.last, hasLength(kMaxShareTargetSlots));
    });

    test('a device that published fewer does not cause a republish', () async {
      // The per-activity limit is a device property: asking for eight on a
      // phone that allows five is normal, and the answer is five. Remembering
      // the five instead of the eight that were asked for would make the next
      // identical rank look like a change, forever.
      final publisher = RecordingShareTargetPublisher()..capacity = 5;
      final shortcuts = service(publisher);
      final chats = inbox(8);

      await shortcuts.refresh(chats, now: shareNow);
      await shortcuts.refresh(chats, now: shareNow);

      expect(publisher.publishes, hasLength(1));
      expect(shortcuts.published, hasLength(8));
    });

    test('a launcher that refuses everything is retried', () async {
      // Zero published is not a cap, it is a refusal — a launcher that will not
      // take shortcuts, or a platform with no channel behind the call at all.
      // Treating it as the published state would mean never trying again.
      final publisher = RecordingShareTargetPublisher()..refuse = true;
      final shortcuts = service(publisher);
      final chats = inbox(3);

      await shortcuts.refresh(chats, now: shareNow);
      await shortcuts.refresh(chats, now: shareNow);

      expect(publisher.publishes, hasLength(2));
      expect(shortcuts.published, isEmpty);
    });
  });

  group('avatars', () {
    test('resolves each slot avatar to a path', () async {
      final publisher = RecordingShareTargetPublisher();
      final asked = <String>[];
      await service(
        publisher,
        avatarLoader: (url) async {
          asked.add(url);
          return '/cache/${url.split('/').last}';
        },
      ).refresh([
        shareChat(
          id: 'chat_0',
          avatarUrl: 'https://example.org/ada.png',
          lastMessageAt: shareAgo(const Duration(minutes: 1)),
        ),
      ], now: shareNow);

      expect(asked, ['https://example.org/ada.png']);
      expect(publisher.last.single['iconPath'], '/cache/ada.png');
    });

    test('a chat with no avatar publishes a null path', () async {
      // Not an omission: `ShareShortcuts` draws initials for a null path, and a
      // share target with no icon at all is drawn by most launchers as the app
      // icon — eight conversations rendered as eight identical Weft logos.
      final publisher = RecordingShareTargetPublisher();
      await service(
        publisher,
        avatarLoader: (_) async => fail('nothing to resolve'),
      ).refresh(inbox(1), now: shareNow);

      expect(publisher.last.single['iconPath'], isNull);
    });

    test('a loader that fails falls back rather than losing the slot',
        () async {
      final publisher = RecordingShareTargetPublisher();
      await service(
        publisher,
        avatarLoader: (_) async => throw StateError('no cache directory'),
      ).refresh([
        shareChat(
          id: 'chat_0',
          avatarUrl: 'https://example.org/ada.png',
          lastMessageAt: shareAgo(const Duration(minutes: 1)),
        ),
      ], now: shareNow);

      expect(publisher.last, hasLength(1));
      expect(publisher.last.single['iconPath'], isNull);
    });

    test('a loader that returns null falls back too', () async {
      final publisher = RecordingShareTargetPublisher();
      await service(publisher, avatarLoader: (_) async => null).refresh([
        shareChat(
          id: 'chat_0',
          avatarUrl: 'mxc://example.org/never-resolved',
          lastMessageAt: shareAgo(const Duration(minutes: 1)),
        ),
      ], now: shareNow);

      expect(publisher.last.single['iconPath'], isNull);
    });

    test('avatars are resolved only when something is being published',
        () async {
      // The diff runs first on purpose. Resolving eight faces on every read
      // receipt would be eight cache lookups — and, the first time, eight
      // authenticated downloads — for a publish that is then suppressed.
      final publisher = RecordingShareTargetPublisher();
      var loads = 0;
      final shortcuts = service(
        publisher,
        avatarLoader: (_) async {
          loads++;
          return '/cache/face.png';
        },
      );
      final chats = [
        shareChat(
          id: 'chat_0',
          avatarUrl: 'https://example.org/ada.png',
          lastMessageAt: shareAgo(const Duration(minutes: 1)),
        ),
      ];

      await shortcuts.refresh(chats, now: shareNow);
      await shortcuts.refresh(chats, now: shareNow);

      expect(loads, 1);
    });
  });

  group('noteSend', () {
    test('records a send and republishes on the frequency it adds', () async {
      final publisher = RecordingShareTargetPublisher();
      final shortcuts = service(publisher);
      // Two chats of equal recency, ordered by title as the tie-break.
      final chats = [
        shareChat(
          id: 'chat_a',
          title: 'Alpha',
          lastMessageAt: shareAgo(const Duration(days: 1)),
        ),
        shareChat(
          id: 'chat_b',
          title: 'Beta',
          lastMessageAt: shareAgo(const Duration(days: 1)),
        ),
      ];

      await shortcuts.refresh(chats, now: shareNow);
      expect(publisher.lastChatIds, ['chat_a', 'chat_b']);

      await shortcuts.noteSend('chat_b', at: shareNow);

      expect(publisher.publishes, hasLength(2));
      expect(publisher.lastChatIds, ['chat_b', 'chat_a']);
    });

    test('a send before anything was published publishes nothing', () async {
      // Republishing here would hand the platform an empty list, and an empty
      // list is how the launcher is told to remove everything.
      final publisher = RecordingShareTargetPublisher();
      await service(publisher).noteSend('chat_0', at: shareNow);

      expect(publisher.publishes, isEmpty);
      expect(publisher.clears, 0);
    });
  });

  group('clear', () {
    test('clears the launcher and forgets what was published', () async {
      final publisher = RecordingShareTargetPublisher();
      final shortcuts = service(publisher);

      await shortcuts.refresh(inbox(3), now: shareNow);
      await shortcuts.clear();

      expect(publisher.clears, 1);
      expect(shortcuts.published, isEmpty);
    });

    test('a send after signing out does not republish the old inbox',
        () async {
      // The leak this guards: a signed-out phone still offering contact names
      // in every app's share sheet.
      final publisher = RecordingShareTargetPublisher();
      final shortcuts = service(publisher);

      await shortcuts.refresh(inbox(3), now: shareNow);
      await shortcuts.clear();
      await shortcuts.noteSend('chat_0', at: shareNow);

      expect(publisher.publishes, hasLength(1));
    });

    test('signing back in publishes again', () async {
      final publisher = RecordingShareTargetPublisher();
      final shortcuts = service(publisher);
      final chats = inbox(3);

      await shortcuts.refresh(chats, now: shareNow);
      await shortcuts.clear();
      await shortcuts.refresh(chats, now: shareNow);

      expect(publisher.publishes, hasLength(2));
      expect(publisher.lastChatIds, ['chat_0', 'chat_1', 'chat_2']);
    });
  });

  group('the ranker is not bypassed', () {
    test('archived and sourceless chats are never published', () async {
      // Both would produce a launcher entry whose tap opens a conversation that
      // cannot be written to.
      final publisher = RecordingShareTargetPublisher();
      await service(publisher).refresh([
        shareChat(
          id: 'chat_0',
          lastMessageAt: shareAgo(const Duration(minutes: 1)),
        ),
        shareChat(
          id: 'chat_archived',
          archived: true,
          lastMessageAt: shareAgo(const Duration(seconds: 1)),
        ),
        const Chat(id: 'chat_sourceless', title: 'Rebuilding', sources: []),
      ], now: shareNow);

      expect(publisher.lastChatIds, ['chat_0']);
    });

    test('an empty inbox on a fresh account calls nothing', () async {
      // Nothing was published, so there is nothing to remove and no set to
      // replace. The first launcher call a new install makes should be its
      // first real set of conversations.
      final publisher = RecordingShareTargetPublisher();
      await service(publisher).refresh(const [], now: shareNow);

      expect(publisher.publishes, isEmpty);
      expect(publisher.clears, 0);
    });

    test('an inbox that empties publishes an empty set', () async {
      // Which is how `ShareShortcuts.publish` is told to remove them: it treats
      // the list it is given as complete. Every conversation archived at once
      // is unusual; one at a time down to none is not.
      final publisher = RecordingShareTargetPublisher();
      final shortcuts = service(publisher);

      await shortcuts.refresh(inbox(2), now: shareNow);
      await shortcuts.refresh(const [], now: shareNow);

      expect(publisher.publishes, hasLength(2));
      expect(publisher.last, isEmpty);
    });

    test('pinned chats lead', () async {
      final publisher = RecordingShareTargetPublisher();
      await service(publisher).refresh([
        ...inbox(2),
        shareChat(
          id: 'chat_pinned',
          title: 'Pinned',
          pinned: true,
          lastMessageAt: shareAgo(const Duration(days: 30)),
        ),
      ], now: shareNow);

      expect(publisher.lastChatIds.first, 'chat_pinned');
      expect(publisher.last.first['pinned'], true);
    });
  });

  group('one shortcut id, three surfaces', () {
    test('the published id is the one a notification bubbles off', () async {
      // `chatShortcutId` is now one line over `shareTargetSlotId`. This pins
      // the consequence rather than the delegation: Android drops a
      // `shortcutId` naming a shortcut that does not exist, and a conversation
      // that quietly stops bubbling is not a failure a test on a device catches
      // either.
      final publisher = RecordingShareTargetPublisher();
      await service(publisher).refresh([
        shareChat(
          id: 'merged:contact_1',
          lastMessageAt: shareAgo(const Duration(minutes: 1)),
        ),
      ], now: shareNow);

      expect(publisher.last.single['id'], 'chat_merged_contact_1');
      expect(publisher.last.single['id'], chatShortcutId('merged:contact_1'));
      expect(publisher.last.single['chatId'], 'merged:contact_1');
    });
  });

  group('where the ranked list actually goes', () {
    /// [shareTargetSurfaceProvider] resolved as [platform].
    ///
    /// Both ends are overridden with recorders, so the assertion is purely
    /// about which of them the ranked list is handed to — everything above the
    /// seam is one implementation and is covered by the groups above.
    ShareTargetPublisher surfaceOn(TargetPlatform platform) {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final container = ProviderContainer(
        overrides: [
          shareTargetPublisherProvider.overrideWithValue(_LauncherSurface()),
          stagedSharesProvider.overrideWithValue(_ContainerSurface()),
        ],
      );
      addTearDown(container.dispose);
      return container.read(shareTargetSurfaceProvider);
    }

    test('iOS writes the App Group container, not the launcher', () {
      // There is no launcher to publish conversation shortcuts to, and the
      // surface that reads this list is the Share Extension's own picker in
      // another process. Getting the branch backwards is silent on both
      // platforms: one publishes over a channel with no handler, the other
      // writes a file nothing reads.
      expect(surfaceOn(TargetPlatform.iOS), isA<_ContainerSurface>());
    });

    test('Android publishes to the launcher', () {
      expect(surfaceOn(TargetPlatform.android), isA<_LauncherSurface>());
    });

    test('a desktop build takes the launcher branch and no-ops there', () {
      // macOS, Linux and Windows have neither surface. They resolve to the
      // `/intents` channel, which has no handler off Android — a
      // `MissingPluginException` `WeftIntents` swallows — rather than to a
      // container that does not exist.
      expect(surfaceOn(TargetPlatform.macOS), isA<_LauncherSurface>());
    });
  });
}

/// Android's end of [shareTargetSurfaceProvider].
class _LauncherSurface extends RecordingShareTargetPublisher {}

/// iOS's end of it. Stands in for [WeftStagedShares], whose own behaviour is
/// covered over a fake method channel in `staged_share_reader_test.dart`.
class _ContainerSurface extends RecordingShareTargetPublisher
    implements WeftStagedShares {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
