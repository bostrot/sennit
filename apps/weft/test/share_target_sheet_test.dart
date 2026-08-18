import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/intents.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/share_providers.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/features/chat/attachment_preview_sheet.dart';
import 'package:weft/features/chat/send_network_chip.dart';
import 'package:weft/features/share/share_target_sheet.dart';
import 'package:weft/services/share/shortcut_service.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/share_fixtures.dart';

/// The share sheet as a *picker*, which is what Phase 04 task 7 turned it into.
///
/// `share_files_test.dart` already covers the path a shared file takes through
/// this sheet — resolve, summarise, send — and nothing here re-tests that.
/// What is new, and only testable here, is everything between arriving and
/// sending: which conversations are offered and in what order, which are
/// offered as refusals, choosing several at once, and which network each
/// chosen chat's copy rides.
///
/// Ordering is asserted against [shareNow] through [withClock] rather than the
/// wall clock. `ShareTargetRanker` decays recency on a seven-day half-life, so
/// a suite run months after these fixtures were written would score every chat
/// at effectively zero and leave the order to the tie-break — green today, and
/// green for the wrong reason forever after.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A file the sheet will treat as a JPEG of [size] bytes.
  ///
  /// The bytes are a header and nothing else: the sheet sniffs the type from
  /// these four and takes the size from the field, and no code under test opens
  /// the path. Sizes above a real network's cap are therefore free to write.
  AttachmentSource photo({String name = 'holiday.jpg', int size = 96000}) =>
      AttachmentSource(
        filename: '/tmp/weft-share/$name',
        sizeBytes: size,
        header: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]),
      );

  /// Opens the sheet over [chats] and returns the repository that recorded the
  /// send.
  ///
  /// [chatsProvider] is overridden rather than a repository's `watchChats`
  /// because the ordering under test is the *sheet's*, and a fixed list is the
  /// only way to know what the ranker was handed. The shortcut service is real
  /// but publishes to a recorder: the sheet reads this run's send counts off it
  /// to rank, and a stub would leave that wiring untested.
  Future<_RecordingRepository> pumpSheet(
    WidgetTester tester, {
    required List<Chat> chats,
    required SharedPayload payload,
    ResolvedShare resolved = const ResolvedShare(),
    ShareShortcutService? shortcuts,
  }) async {
    final repository = _RecordingRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatsProvider.overrideWith((ref) => Stream.value(chats)),
          chatRepositoryProvider.overrideWithValue(repository),
          sharedFileResolverProvider.overrideWithValue(
            _FakeResolver(resolved),
          ),
          if (shortcuts != null)
            shareShortcutServiceProvider.overrideWithValue(shortcuts),
          // The thumbnails decode each shared file; these sources describe
          // files a widget test has no disk for.
          attachmentFileReaderProvider.overrideWithValue(
            (source) async => source.header,
          ),
        ],
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showShareTargetSheet(context, payload),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return repository;
  }

  /// The conversation titles on screen, top to bottom.
  ///
  /// Read off the tiles rather than off every `Text`, so the header's summary
  /// line and the "cannot carry" caption do not land in the middle of an
  /// ordering assertion.
  List<String> listedTitles(WidgetTester tester) => [
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
      ((tile.title! as Text).data)!,
  ];

  /// Scroll a row into view before tapping it.
  ///
  /// A test viewport is 800x600 and the sheet opens at 70% of it, so a list of
  /// more than three conversations reaches past the bottom — as it does on a
  /// phone, which is why the list scrolls.
  Future<void> tapRow(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('the ranked list', () {
    /// Deliberately out of ranked order, and out of inbox order too: the sheet
    /// is handed whatever `chatsProvider` emits, and asserting on a list that
    /// arrives already sorted would pass with no ranker at all.
    List<Chat> jumbled() => [
      shareChat(
        id: 'stale',
        title: 'Stale Group',
        lastMessageAt: shareAgo(const Duration(days: 40)),
      ),
      shareChat(
        id: 'recent',
        title: 'Recent Contact',
        lastMessageAt: shareAgo(const Duration(minutes: 5)),
      ),
      shareChat(
        id: 'pinned',
        title: 'Pinned Colleague',
        pinned: true,
        lastMessageAt: shareAgo(const Duration(days: 9)),
      ),
      shareChat(
        id: 'yesterday',
        title: 'Yesterday Friend',
        lastMessageAt: shareAgo(const Duration(days: 1)),
      ),
    ];

    testWidgets('is the ranker\'s order, not the inbox\'s', (tester) async {
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: jumbled(),
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
        );

        expect(listedTitles(tester), [
          // Pinned is a tier and not a bonus: nine days of silence still
          // outranks a message five minutes ago.
          'Pinned Colleague',
          'Recent Contact',
          'Yesterday Friend',
          'Stale Group',
        ]);
      });
    });

    testWidgets('an archived chat is not a share target', (tester) async {
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: [
            ...jumbled(),
            shareChat(
              id: 'archived',
              title: 'Archived Thread',
              archived: true,
              lastMessageAt: shareAgo(const Duration(minutes: 1)),
            ),
          ],
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
        );

        expect(
          listedTitles(tester),
          isNot(contains('Archived Thread')),
          reason: 'archiving a conversation is a statement about wanting it '
              'out of the way, and a share sheet is somewhere it is in the way',
        );
      });
    });

    testWidgets('this run\'s sends move a conversation up', (tester) async {
      // The share sheet and the launcher faces above it are the same ranker
      // twice, and the send counts only exist in `ShareShortcutService`. A
      // sheet that could not read them would order its first rows differently
      // from the faces the user just tapped past.
      //
      // Three weeks against two is the gap frequency is sized to close.
      // Frequency is weighted below recency and saturates, so it is a thumb on
      // the scale rather than an override — a chat silent for forty days does
      // not come back to the top of the list because of six sends, and a case
      // asserting that it did would be asserting the ranker is something else.
      await withClock(Clock.fixed(shareNow), () async {
        final chats = [
          shareChat(
            id: 'colleague',
            title: 'Old Colleague',
            lastMessageAt: shareAgo(const Duration(days: 21)),
          ),
          shareChat(
            id: 'acquaintance',
            title: 'Newer Acquaintance',
            lastMessageAt: shareAgo(const Duration(days: 14)),
          ),
        ];

        final shortcuts = ShareShortcutService(
          publisher: RecordingShareTargetPublisher(),
        );
        await shortcuts.refresh(chats, now: shareNow);
        for (var i = 0; i < 6; i++) {
          await shortcuts.noteSend(
            'colleague',
            at: shareAgo(Duration(hours: i)),
          );
        }

        await pumpSheet(
          tester,
          chats: chats,
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
          shortcuts: shortcuts,
        );

        expect(
          listedTitles(tester),
          ['Old Colleague', 'Newer Acquaintance'],
          reason: 'recency alone puts the acquaintance first; the sends this '
              'run are what reverse it',
        );
      });
    });

    testWidgets('a chat that cannot carry the file is shown with the reason', (
      tester,
    ) async {
      // Not hidden. A conversation missing from a share sheet with no
      // explanation is the failure the capability table exists to avoid — the
      // user searches for a name, does not find it, and has nothing to act on.
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'matrix',
              title: 'Matrix Friend',
              lastMessageAt: shareAgo(const Duration(minutes: 5)),
            ),
            shareChat(
              id: 'bluesky',
              title: 'Bluesky Mutual',
              networks: const [ChatNetwork.bluesky],
              lastMessageAt: shareAgo(const Duration(minutes: 1)),
            ),
          ],
          payload: const SharedPayload(
            mimeType: 'image/jpeg',
            uris: ['content://media/1'],
          ),
          // Bluesky's chat takes images, but only up to a megabyte.
          resolved: ResolvedShare(sources: [photo(size: 8 * 1024 * 1024)]),
        );

        expect(find.text('Cannot carry this share'), findsOneWidget);
        expect(find.text('No network here takes this file'), findsOneWidget);
        expect(
          listedTitles(tester),
          ['Matrix Friend', 'Bluesky Mutual'],
          reason: 'the refusals sit below the targets, most recent first '
              'though the blocked chat is',
        );

        final blocked = tester.widget<ListTile>(
          find.widgetWithText(ListTile, 'Bluesky Mutual'),
        );
        expect(blocked.enabled, isFalse);
        expect(
          blocked.onTap,
          isNull,
          reason: 'a row that explains why it cannot be chosen must not then '
              'be choosable',
        );
      });
    });

    testWidgets('text alone is offered to every network', (tester) async {
      // The capability filter is about files. A chat filtered away for a photo
      // is still a place to send a sentence, and every bridge carries text.
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'bluesky',
              title: 'Bluesky Mutual',
              networks: const [ChatNetwork.bluesky],
              lastMessageAt: shareAgo(const Duration(minutes: 1)),
            ),
          ],
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
        );

        expect(find.text('Cannot carry this share'), findsNothing);
        expect(listedTitles(tester), ['Bluesky Mutual']);
      });
    });

    testWidgets('the search field narrows the list', (tester) async {
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: jumbled(),
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
        );

        await tester.enterText(find.byType(TextField), 'ye');
        await tester.pumpAndSettle();
        expect(listedTitles(tester), ['Yesterday Friend']);

        // Case is not a thing the user is thinking about while typing a name.
        await tester.enterText(find.byType(TextField), 'GROUP');
        await tester.pumpAndSettle();
        expect(listedTitles(tester), ['Stale Group']);

        await tester.enterText(find.byType(TextField), 'nobody');
        await tester.pumpAndSettle();
        expect(listedTitles(tester), isEmpty);
        expect(find.text('No conversations match that search.'), findsOneWidget);

        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        expect(listedTitles(tester), hasLength(4));
      });
    });
  });

  group('the caption step', () {
    testWidgets('a pre-selected target opens on it, with the text editable', (
      tester,
    ) async {
      // Android's Direct Share and the iOS extension's picker both answer
      // "who" before the app is running. What they cannot answer is "what to
      // say about it", which is the whole reason this step exists rather than
      // the shortcut sending on its own.
      await withClock(Clock.fixed(shareNow), () async {
        final repository = await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'recent',
              title: 'Recent Contact',
              lastMessageAt: shareAgo(const Duration(minutes: 5)),
            ),
          ],
          payload: const SharedPayload(
            text: 'look at this',
            mimeType: 'image/jpeg',
            uris: ['content://media/1'],
            targetChatId: 'recent',
          ),
          resolved: ResolvedShare(sources: [photo()]),
        );

        expect(find.text('Send to Recent Contact'), findsWidgets);
        expect(find.widgetWithText(TextField, 'look at this'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'look at this instead');
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Send to Recent Contact'),
        );
        await tester.pumpAndSettle();

        expect(repository.sent, [
          'recent/matrix: look at this instead',
          'recent/matrix: file holiday.jpg',
        ]);
      });
    });

    testWidgets('the caption is a Message when there is no file under it', (
      tester,
    ) async {
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'recent',
              title: 'Recent Contact',
              lastMessageAt: shareAgo(const Duration(minutes: 5)),
            ),
          ],
          payload: const SharedPayload(
            text: 'hello',
            mimeType: 'text/plain',
            targetChatId: 'recent',
          ),
        );

        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.decoration!.labelText, 'Message');
      });
    });
  });

  group('multi-select', () {
    List<Chat> three() => [
      shareChat(
        id: 'a',
        title: 'Ada Lovelace',
        lastMessageAt: shareAgo(const Duration(minutes: 1)),
      ),
      shareChat(
        id: 'b',
        title: 'Grace Hopper',
        lastMessageAt: shareAgo(const Duration(minutes: 2)),
      ),
      shareChat(
        id: 'c',
        title: 'Katherine Johnson',
        lastMessageAt: shareAgo(const Duration(minutes: 3)),
      ),
    ];

    testWidgets('two ticked conversations both get the share', (tester) async {
      await withClock(Clock.fixed(shareNow), () async {
        final repository = await pumpSheet(
          tester,
          chats: three(),
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
        );

        await tapRow(
          tester,
          find.descendant(
            of: find.widgetWithText(ListTile, 'Ada Lovelace'),
            matching: find.byType(Checkbox),
          ),
        );
        await tapRow(
          tester,
          find.descendant(
            of: find.widgetWithText(ListTile, 'Katherine Johnson'),
            matching: find.byType(Checkbox),
          ),
        );

        expect(find.text('2 chats selected'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
        await tester.pumpAndSettle();

        // Ranked order, not tick order: the confirmation is a list of who,
        // and the user reads it the way they read the one they just left.
        expect(listedTitles(tester), ['Ada Lovelace', 'Katherine Johnson']);

        await tester.tap(
          find.widgetWithText(FilledButton, 'Send to 2 chats'),
        );
        await tester.pumpAndSettle();

        expect(repository.sent, [
          'a/matrix: hello',
          'c/matrix: hello',
        ]);
        expect(find.text('Sent to 2 chats'), findsOneWidget);
      });
    });

    testWidgets('a tap toggles once a selection has started', (tester) async {
      // With nothing ticked a tap is the ordinary share and goes straight to
      // the confirmation. With something ticked the same tap has to mean "and
      // this one too", or ticking a second name would throw away the first.
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: three(),
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
        );

        await tapRow(tester, find.widgetWithText(ListTile, 'Grace Hopper'));
        expect(find.text('Send to Grace Hopper'), findsWidgets);

        await tester.tap(find.text('Choose another chat'));
        await tester.pumpAndSettle();

        await tapRow(
          tester,
          find.descendant(
            of: find.widgetWithText(ListTile, 'Ada Lovelace'),
            matching: find.byType(Checkbox),
          ),
        );
        await tapRow(tester, find.widgetWithText(ListTile, 'Grace Hopper'));

        expect(find.text('2 chats selected'), findsOneWidget);
      });
    });

    testWidgets('clearing the selection returns the list to single taps', (
      tester,
    ) async {
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: three(),
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
        );

        await tapRow(
          tester,
          find.descendant(
            of: find.widgetWithText(ListTile, 'Ada Lovelace'),
            matching: find.byType(Checkbox),
          ),
        );
        expect(find.text('1 chat selected'), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, 'Clear'));
        await tester.pumpAndSettle();
        expect(find.text('1 chat selected'), findsNothing);

        await tapRow(tester, find.widgetWithText(ListTile, 'Grace Hopper'));
        expect(find.text('Send to Grace Hopper'), findsWidgets);
      });
    });
  });

  group('per-target network', () {
    Chat merged({
      required List<ChatNetwork> networks,
      ChatNetwork? preferred,
    }) => shareChat(
      id: 'merged:grace',
      title: 'Grace Hopper',
      networks: networks,
      preferredSendNetwork: preferred,
      lastMessageAt: shareAgo(const Duration(minutes: 5)),
    );

    testWidgets('defaults to the chat\'s stored send network', (tester) async {
      // The standing answer to "which app does this person actually read". A
      // share is one gesture aimed at a conversation the user may not have
      // opened in weeks, so it follows that answer rather than replacing it.
      await withClock(Clock.fixed(shareNow), () async {
        final repository = await pumpSheet(
          tester,
          chats: [
            merged(
              networks: const [ChatNetwork.whatsapp, ChatNetwork.signal],
              preferred: ChatNetwork.signal,
            ),
          ],
          payload: const SharedPayload(
            mimeType: 'image/jpeg',
            uris: ['content://media/1'],
          ),
          resolved: ResolvedShare(sources: [photo()]),
        );

        await tapRow(tester, find.widgetWithText(ListTile, 'Grace Hopper'));
        expect(find.text('via Signal'), findsOneWidget);

        await tester.tap(
          find.widgetWithText(FilledButton, 'Send to Grace Hopper'),
        );
        await tester.pumpAndSettle();

        expect(repository.sent, ['merged:grace/signal: file holiday.jpg']);
      });
    });

    testWidgets('a stored network that cannot carry the file is passed over', (
      tester,
    ) async {
      // Signal stops at 100 MB and WhatsApp does not. Both legs reach the same
      // person, so honouring the stored preference here would be honouring it
      // into a send that fails.
      await withClock(Clock.fixed(shareNow), () async {
        final repository = await pumpSheet(
          tester,
          chats: [
            merged(
              networks: const [ChatNetwork.whatsapp, ChatNetwork.signal],
              preferred: ChatNetwork.signal,
            ),
          ],
          payload: const SharedPayload(
            mimeType: 'image/jpeg',
            uris: ['content://media/1'],
          ),
          resolved: ResolvedShare(
            sources: [photo(size: 150 * 1024 * 1024)],
          ),
        );

        await tapRow(tester, find.widgetWithText(ListTile, 'Grace Hopper'));
        expect(find.text('via WhatsApp'), findsOneWidget);
        expect(
          find.byType(SendNetworkChip),
          findsNothing,
          reason: 'one capable leg is not a choice, and a menu with one entry '
              'is a menu that reads as though there were others',
        );

        await tester.tap(
          find.widgetWithText(FilledButton, 'Send to Grace Hopper'),
        );
        await tester.pumpAndSettle();

        expect(repository.sent, ['merged:grace/whatsapp: file holiday.jpg']);
      });
    });

    testWidgets('the chip offers only the legs that can carry it', (
      tester,
    ) async {
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: [
            merged(
              networks: const [
                ChatNetwork.whatsapp,
                ChatNetwork.signal,
                ChatNetwork.sms,
              ],
              preferred: ChatNetwork.whatsapp,
            ),
          ],
          payload: const SharedPayload(
            mimeType: 'image/jpeg',
            uris: ['content://media/1'],
          ),
          // Over MMS's megabyte, under Signal's hundred.
          resolved: ResolvedShare(sources: [photo(size: 4 * 1024 * 1024)]),
        );

        await tapRow(tester, find.widgetWithText(ListTile, 'Grace Hopper'));
        await tapRow(tester, find.byType(SendNetworkChip));

        expect(find.text('WhatsApp'), findsOneWidget);
        expect(find.text('Signal'), findsOneWidget);
        expect(
          find.text('SMS'),
          findsNothing,
          reason: 'offering a leg that will refuse the file is offering a '
              'send that fails',
        );
      });
    });

    testWidgets('picking a network routes that target\'s copy', (tester) async {
      await withClock(Clock.fixed(shareNow), () async {
        final repository = await pumpSheet(
          tester,
          chats: [
            merged(
              networks: const [ChatNetwork.whatsapp, ChatNetwork.signal],
              preferred: ChatNetwork.whatsapp,
            ),
          ],
          payload: const SharedPayload(
            mimeType: 'image/jpeg',
            uris: ['content://media/1'],
          ),
          resolved: ResolvedShare(sources: [photo()]),
        );

        await tapRow(tester, find.widgetWithText(ListTile, 'Grace Hopper'));
        await tapRow(tester, find.byType(SendNetworkChip));
        await tester.tap(find.text('Signal').last);
        await tester.pumpAndSettle();

        expect(find.text('via Signal'), findsOneWidget);
        await tester.tap(
          find.widgetWithText(FilledButton, 'Send to Grace Hopper'),
        );
        await tester.pumpAndSettle();

        expect(repository.sent, ['merged:grace/signal: file holiday.jpg']);
      });
    });

    testWidgets('each target in a forward keeps its own network', (
      tester,
    ) async {
      // The reason the choice is per target rather than one chip above the
      // list: two conversations in the same forward have no reason to agree
      // about which app reaches the person on the other end.
      await withClock(Clock.fixed(shareNow), () async {
        final repository = await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'merged:ada',
              title: 'Ada Lovelace',
              networks: const [ChatNetwork.whatsapp, ChatNetwork.signal],
              preferredSendNetwork: ChatNetwork.signal,
              lastMessageAt: shareAgo(const Duration(minutes: 1)),
            ),
            shareChat(
              id: 'merged:grace',
              title: 'Grace Hopper',
              networks: const [ChatNetwork.whatsapp, ChatNetwork.telegram],
              preferredSendNetwork: ChatNetwork.telegram,
              lastMessageAt: shareAgo(const Duration(minutes: 2)),
            ),
          ],
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
        );

        await tapRow(
          tester,
          find.descendant(
            of: find.widgetWithText(ListTile, 'Ada Lovelace'),
            matching: find.byType(Checkbox),
          ),
        );
        await tapRow(
          tester,
          find.descendant(
            of: find.widgetWithText(ListTile, 'Grace Hopper'),
            matching: find.byType(Checkbox),
          ),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
        await tester.pumpAndSettle();

        expect(find.text('via Signal'), findsOneWidget);
        expect(find.text('via Telegram'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Send to 2 chats'));
        await tester.pumpAndSettle();

        expect(repository.sent, [
          'merged:ada/signal: hello',
          'merged:grace/telegram: hello',
        ]);
      });
    });

    testWidgets('a stale shortcut onto an incapable chat says so', (
      tester,
    ) async {
      // A launcher holds a long-lived shortcut for weeks, so the chat behind
      // one can be reached with a file no leg of it will take — the list would
      // have shown that chat under "Cannot carry this share", but the shortcut
      // went straight past the list. The confirmation is the only place left to
      // say it, and it says it instead of naming a network it does not have.
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'bluesky',
              title: 'Bluesky Mutual',
              networks: const [ChatNetwork.bluesky],
              lastMessageAt: shareAgo(const Duration(minutes: 1)),
            ),
          ],
          payload: const SharedPayload(
            mimeType: 'image/jpeg',
            uris: ['content://media/1'],
            targetChatId: 'bluesky',
          ),
          resolved: ResolvedShare(sources: [photo(size: 8 * 1024 * 1024)]),
        );

        expect(find.text('Send to Bluesky Mutual'), findsWidgets);
        expect(find.text('No network here takes this file'), findsOneWidget);
        expect(
          find.byType(SendNetworkChip),
          findsNothing,
          reason: 'there is no leg to offer, and a chip with nothing in it '
              'reads as a choice that has not been made yet',
        );
      });
    });
  });

  group('what the share is, above the list', () {
    testWidgets('several files summarise as a count, not a name', (
      tester,
    ) async {
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'recent',
              title: 'Recent Contact',
              lastMessageAt: shareAgo(const Duration(minutes: 5)),
            ),
          ],
          payload: const SharedPayload(
            mimeType: 'image/jpeg',
            uris: ['content://media/1', 'content://media/2'],
          ),
          resolved: ResolvedShare(
            sources: [
              photo(name: 'one.jpg', size: 100000),
              photo(name: 'two.jpg', size: 100000),
            ],
          ),
        );

        expect(find.textContaining('2 files · '), findsOneWidget);
        expect(
          find.text('one.jpg · 98 KB'),
          findsNothing,
          reason: 'the first of several files is not what is being shared',
        );
        // Both thumbnails, so the strip is the preview for a batch and not
        // just for the file that happened to be first.
        expect(find.byType(AttachmentSourceThumbnail), findsNWidgets(2));
      });
    });

    testWidgets('a file rejected before the tap is named with its reason', (
      tester,
    ) async {
      // `ResolvedShare.problems` is written during resolution — a file over
      // `kMaxSharedFileBytes`, or one the platform would not hand over. It
      // belongs above the list rather than in a snackbar after the send: it is
      // a fact about the share, and knowing it before choosing a conversation
      // is what lets the user back out and send the other one instead.
      await withClock(Clock.fixed(shareNow), () async {
        await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'recent',
              title: 'Recent Contact',
              lastMessageAt: shareAgo(const Duration(minutes: 5)),
            ),
          ],
          payload: const SharedPayload(
            mimeType: 'image/jpeg',
            uris: ['content://media/1', 'content://media/2'],
          ),
          resolved: ResolvedShare(
            sources: [photo()],
            problems: const ['huge.mov is larger than 100 MB.'],
          ),
        );

        expect(find.text('huge.mov is larger than 100 MB.'), findsOneWidget);
        expect(
          listedTitles(tester),
          ['Recent Contact'],
          reason: 'one file refused is not the whole share refused',
        );
      });
    });
  });

  group('a send that does not entirely arrive', () {
    testWidgets('a forward counts who it reached', (tester) async {
      await withClock(Clock.fixed(shareNow), () async {
        final shortcuts = ShareShortcutService(
          publisher: RecordingShareTargetPublisher(),
        );
        final repository = await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'a',
              title: 'Ada Lovelace',
              lastMessageAt: shareAgo(const Duration(minutes: 1)),
            ),
            shareChat(
              id: 'b',
              title: 'Grace Hopper',
              lastMessageAt: shareAgo(const Duration(minutes: 2)),
            ),
          ],
          payload: const SharedPayload(text: 'hello', mimeType: 'text/plain'),
          shortcuts: shortcuts,
        );
        repository.failing.add('b');

        for (final title in ['Ada Lovelace', 'Grace Hopper']) {
          await tapRow(
            tester,
            find.descendant(
              of: find.widgetWithText(ListTile, title),
              matching: find.byType(Checkbox),
            ),
          );
        }
        await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Send to 2 chats'));
        await tester.pumpAndSettle();

        expect(repository.sent, ['a/matrix: hello']);
        // The count and the name, because with two targets "the message could
        // not be sent" alone does not say which of them is missing it.
        expect(
          find.text(
            'Sent to 1 of 2 chats.\nGrace Hopper: The message could not be '
            'sent.',
          ),
          findsOneWidget,
        );
        expect(
          shortcuts.activity.keys,
          ['a'],
          reason: 'a share is the strongest signal the ranker gets, and a '
              'conversation the share never reached did not send that signal',
        );
      });
    });

    testWidgets('a single target reports the failure without a headline', (
      tester,
    ) async {
      // Nothing arrived, so there is no "sent to" to put in front of it —
      // and with one target the name is already the title of the sheet.
      await withClock(Clock.fixed(shareNow), () async {
        final repository = await pumpSheet(
          tester,
          chats: [
            shareChat(
              id: 'recent',
              title: 'Recent Contact',
              lastMessageAt: shareAgo(const Duration(minutes: 5)),
            ),
          ],
          payload: const SharedPayload(
            text: 'look at this',
            mimeType: 'image/jpeg',
            uris: ['content://media/1'],
            targetChatId: 'recent',
          ),
          resolved: ResolvedShare(sources: [photo()]),
        );
        repository.failing.add('recent');

        await tester.tap(
          find.widgetWithText(FilledButton, 'Send to Recent Contact'),
        );
        await tester.pumpAndSettle();

        expect(repository.sent, isEmpty);
        expect(
          find.text(
            'The message could not be sent.\nholiday.jpg could not be sent.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Sent to'), findsNothing);
      });
    });
  });
}

/// Records where each send went and on which network.
///
/// The network is the point: `via` is the sheet's answer to the per-target
/// question, and it is invisible in anything the demo repository stores.
class _RecordingRepository implements ChatRepository {
  final List<String> sent = [];

  /// Chat ids whose sends throw, as a homeserver that has gone away does.
  final Set<String> failing = {};

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) async {
    if (failing.contains(chatId)) throw StateError('no route to $chatId');
    sent.add('$chatId/${via?.id ?? 'default'}: $body');
  }

  @override
  Future<void> sendAttachment(
    String chatId,
    AttachmentSource source, {
    ChatNetwork? via,
    bool isVoiceNote = false,
  }) async {
    if (failing.contains(chatId)) throw StateError('no route to $chatId');
    sent.add('$chatId/${via?.id ?? 'default'}: file ${source.basename}');
  }

  /// Everything else throws: a picker that starts loading timelines or watching
  /// uploads should fail loudly rather than quietly do half a send.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A resolution that has already happened.
///
/// The resolution itself is asserted against real files and a real channel in
/// `share_files_test.dart`; what happens *after* it is this file's subject.
class _FakeResolver implements SharedFileResolver {
  const _FakeResolver(this.resolved);

  final ResolvedShare resolved;

  @override
  Future<ResolvedShare> resolveSharedFiles(SharedPayload payload) async =>
      resolved;
}
