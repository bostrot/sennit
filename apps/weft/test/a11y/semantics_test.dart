import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/bridges/bridges_screen.dart';
import 'package:weft/features/call/call_overlay.dart';
import 'package:weft/features/call/incoming_call_sheet.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/merge/merge_screen.dart';
import 'package:weft/features/search/search_screen.dart';
import 'package:weft/features/settings/endpoints_screen.dart';
import 'package:weft/features/settings/notifications_screen.dart';

import '../support/a11y_harness.dart';
import '../support/attachment_fixtures.dart';
import '../support/call_fixtures.dart';
import '../support/golden_harness.dart' show loadGoldenFonts;
import '../support/seeded_repository.dart';
import '../support/semantics_probe.dart';

/// The four guidelines Flutter ships, swept over the screens Weft is actually
/// used on.
///
/// The rest of the a11y suite asserts particular sentences — that a bubble says
/// who spoke, that a merge says what it merged. Those tests are precise and
/// blind: they only see what someone thought to write an expectation for. This
/// file is the opposite, and the two are complementary. `meetsGuideline` walks
/// the *whole* semantics tree and reports every node that breaks a rule, so a
/// control added next month is checked without anybody remembering to check it.
///
/// Four rules, and what each one catches that the others do not:
///
///  * **labelled** — a node with a tap or long-press action and no label. The
///    audit's most common finding by a wide margin, and the one a sighted
///    review will never notice.
///  * **Android tap target** (48×48) and **iOS** (44×44) — the touch-target
///    register, TAP-01…15. Both, because the 44dp entries pass one and fail the
///    other, and Weft ships on both platforms.
///  * **text contrast** — the token work in task 2 proved every *token* pair;
///    this proves the pixels that were actually painted, which is a different
///    claim. A widget that dims ink by hand fails here and nowhere else.
///
/// Both themes, because half the palette is per-brightness and a sweep that ran
/// only on dark would have missed the light theme's presence green entirely.
void main() {
  late DemoChatRepository demo;
  late WeftStores stores;

  setUpAll(loadGoldenFonts);

  setUp(() {
    demo = DemoChatRepository(uploadTick: Duration.zero);
    stores = WeftStores.inMemory();
  });
  tearDown(() {
    demo.dispose();
    stores.dispose();
  });

  /// The seeded conversation the chat scene runs on.
  ///
  /// Deliberately not the demo history: the controls the touch-target register
  /// names — reaction chips, the add-reaction "+", the edited marker, a reply
  /// chip — only exist on a message that carries a reaction, an edit or a
  /// reply, and the demo fixtures carry none of them at once.
  SeededChatRepository seededChat() => SeededChatRepository(
    demo,
    messages: [
      seededMessage(
        eventId: r'$one',
        body: 'Where are we meeting?',
        minutesAgo: 10,
        reactions: [
          ReactionTally(
            key: '👍',
            senderIds: const ['@a:example.org', '@b:example.org'],
            firstReactedAt: DateTime(2026, 8, 18, 13, 55),
          ),
        ],
      ),
      seededMessage(
        eventId: r'$two',
        body: 'the usual place, quarter past',
        isOwn: true,
        minutesAgo: 5,
        replyToEventId: r'$one',
        editedAt: DateTime(2026, 8, 18, 13, 58),
        editHistory: [
          EditRecord(
            eventId: r'$two',
            body: 'the usual place, half past',
            timestamp: DateTime(2026, 8, 18, 13, 56),
          ),
          EditRecord(
            eventId: r'$edit',
            body: 'the usual place, quarter past',
            timestamp: DateTime(2026, 8, 18, 13, 58),
          ),
        ],
      ),
    ],
  );

  /// A search index with enough in it to draw the result list and its filters.
  void indexSomething() {
    for (final entry in [
      (r'$one', 'the roof is on fire', ChatNetwork.telegram),
      (r'$two', 'the roof leaks again', ChatNetwork.whatsapp),
    ]) {
      stores.search.indexMessage(
        WeftMessage(
          eventId: entry.$1,
          roomId: '!room:example.org',
          network: entry.$3,
          senderId: '@grace:example.org',
          senderName: 'Grace',
          timestamp: DateTime(2026, 8, 18, 14, 32),
          kind: MessageKind.text,
          isOwn: false,
          body: entry.$2,
        ),
        chatId: 'merged:anna',
        chatTitle: 'The Thursday plan',
      );
    }
  }

  /// The six screens the phase names, each pumped the way the app builds it.
  final scenes = <String, Future<void> Function(WidgetTester, Brightness)>{
    'inbox': (tester, brightness) async {
      await pumpScreen(
        tester,
        const InboxShell(),
        repository: demo,
        stores: stores,
        brightness: brightness,
      );
    },
    'chat': (tester, brightness) async {
      final repository = seededChat();
      await pumpScreen(
        tester,
        ChatView(chatId: repository.chatId),
        repository: repository,
        stores: stores,
        brightness: brightness,
      );
    },
    'search': (tester, brightness) async {
      indexSomething();
      await pumpScreen(
        tester,
        const SearchScreen(initialQuery: 'roof'),
        repository: demo,
        stores: stores,
        brightness: brightness,
      );
    },
    'settings': (tester, brightness) async {
      await pumpScreen(
        tester,
        const EndpointsScreen(),
        repository: demo,
        stores: stores,
        brightness: brightness,
      );
    },
    'bridges': (tester, brightness) async {
      await pumpScreen(
        tester,
        const BridgesScreen(),
        repository: demo,
        stores: stores,
        brightness: brightness,
      );
    },
    'merge': (tester, brightness) async {
      await pumpScreen(
        tester,
        const MergeScreen(),
        repository: demo,
        stores: stores,
        brightness: brightness,
      );
    },
  };

  final guidelines = <String, AccessibilityGuideline>{
    'every tappable node is labelled': labeledTapTargetGuideline,
    'every tap target is 48dp square': androidTapTargetGuideline,
    'every tap target is 44dp square': iOSTapTargetGuideline,
    'every painted label meets WCAG AA': textContrastGuideline,
  };

  for (final scene in scenes.entries) {
    group(scene.key, () {
      for (final brightness in Brightness.values) {
        for (final guideline in guidelines.entries) {
          testWidgets('${guideline.key} (${brightness.name})', (tester) async {
            final handle = tester.ensureSemantics();
            await scene.value(tester, brightness);
            await expectLater(tester, meetsGuideline(guideline.value));
            handle.dispose();
          });
        }
      }
    });
  }

  /// Nothing on a screen may *be* the screen.
  ///
  /// The four guidelines above are Flutter's and they do not ask this. It is
  /// here because TalkBack asked it on a device and the answer was no: the chat
  /// view exported the whole conversation as one edit box called "Message via
  /// Signal", and the send-network chip — whose only visible content is two
  /// silent glyphs — put its tap and its name on the same node. Both are the
  /// same mistake, an annotation with no node of its own merging into the
  /// nearest one that has, and the fix for both is `container: true`.
  ///
  /// Swept at one brightness: a rect is the same in both themes.
  ///
  /// See [oversizedControlsIn] for why no test that starts from a `find` can
  /// catch this.
  group('no control is the size of its screen', () {
    for (final scene in scenes.entries) {
      testWidgets(scene.key, (tester) async {
        final handle = tester.ensureSemantics();
        await scene.value(tester, Brightness.dark);
        // A third of the pumped 900, which is far above anything real — the
        // composer grows to five lines and the leaked node was 836.
        expect(oversizedControlsIn(tester, maxHeight: 300), isEmpty);
        handle.dispose();
      });
    }

    /// The merged chat, which the scene above is not.
    ///
    /// It has to be its own case because the send-network chip only exists on a
    /// conversation with more than one leg, and the chip is half the finding:
    /// its visible content is a silenced glyph and a chevron, so it paints no
    /// semantics of its own for its tooltip and its tap to attach to, and both
    /// went to the screen instead.
    testWidgets('chat, merged across two networks', (tester) async {
      final handle = tester.ensureSemantics();
      final repository = SeededChatRepository(
        demo,
        messages: [
          seededMessage(
            eventId: r'$tg',
            body: 'Where are we meeting?',
            network: ChatNetwork.telegram,
            roomId: '!tg:example.org',
            minutesAgo: 10,
          ),
          seededMessage(
            eventId: r'$sig',
            body: 'the usual place',
            isOwn: true,
            network: ChatNetwork.signal,
            roomId: '!sig:example.org',
            minutesAgo: 5,
          ),
        ],
      );
      await pumpScreen(
        tester,
        ChatView(chatId: repository.chatId),
        repository: repository,
        stores: stores,
      );

      expect(oversizedControlsIn(tester, maxHeight: 300), isEmpty);
      // And the chip still says which leg the next send goes out on, which is
      // the one fact it exists to state.
      expect(controlNamesIn(tester), contains('Send via Telegram'));
      handle.dispose();
    });

    testWidgets('and the composer is still named', (tester) async {
      final handle = tester.ensureSemantics();
      await scenes['chat']!(tester, Brightness.dark);
      // The leak was one half of the finding. A fix that dropped the label to
      // close it would trade this defect for the one the annotation was added
      // for: a field whose name vanishes at the first keystroke.
      expect(labelsIn(tester), contains(startsWith('Message via')));
      handle.dispose();
    });
  });

  /// The surfaces the audit's touch-target register names that are not screens.
  ///
  /// The register has fifteen entries and the six screens above hold four of
  /// them; the rest are sheets, overlays and one composer state. Swept here at
  /// one brightness rather than two, because a tap target is the same size in
  /// both themes — this group is about geometry, and the colour half of the
  /// question is already answered above.
  ///
  /// Every one of these is reached by *driving* the app rather than by pumping
  /// the private widget behind it. A sheet built by hand is a sheet with the
  /// test's own padding and the test's own theme, which is exactly the thing
  /// the measurement is supposed to be of.
  group('sheets and overlays', () {
    final sizes = <String, AccessibilityGuideline>{
      'every tappable node is labelled': labeledTapTargetGuideline,
      'every tap target is 48dp square': androidTapTargetGuideline,
      'every tap target is 44dp square': iOSTapTargetGuideline,
    };

    /// Runs [pump], then asserts all three geometry guidelines over it.
    void sweep(String name, Future<void> Function(WidgetTester) pump) {
      for (final guideline in sizes.entries) {
        testWidgets('$name — ${guideline.key}', (tester) async {
          final handle = tester.ensureSemantics();
          await pump(tester);
          await expectLater(tester, meetsGuideline(guideline.value));
          handle.dispose();
        });
      }
    }

    /// The chat with the actions sheet open over the peer's message.
    Future<void> openActions(WidgetTester tester) async {
      final repository = seededChat();
      await pumpScreen(
        tester,
        ChatView(chatId: repository.chatId),
        repository: repository,
        stores: stores,
      );
      await tester.longPress(
        find.text('Where are we meeting?', findRichText: true).first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
    }

    sweep('the message actions sheet', openActions);

    sweep('the emoji picker', (tester) async {
      await openActions(tester);
      // By tooltip, not by label: an `IconButton`'s tooltip *is* its accessible
      // name — it reaches the node as `SemanticsData.tooltip` rather than as a
      // label, which is why the labelled-target guideline accepts either.
      await tester.tap(find.byTooltip('More reactions'));
      await tester.pumpAndSettle();
    });

    sweep('the appearance sheet', (tester) async {
      await pumpScreen(
        tester,
        const InboxShell(),
        repository: demo,
        stores: stores,
      );
      await tester.tap(find.byTooltip('Appearance'));
      await tester.pumpAndSettle();
    });

    sweep('an incoming call', (tester) async {
      await pumpCallSurface(
        tester,
        IncomingCallSheet(
          session: ringingSession(video: true),
          controls: RecordingControls(),
        ),
      );
      await tester.pumpAndSettle();
    });

    /// The composer of a merged chat, which is where the send-network chip is.
    ///
    /// A chat with one leg has nothing to pick between, so the chip is not
    /// drawn at all — which is why the seeded single-network fixture the chat
    /// scene runs on cannot answer for it.
    sweep('the composer on a merged chat', (tester) async {
      await pumpScreen(
        tester,
        const ChatView(chatId: 'merged:anna'),
        repository: demo,
        stores: stores,
      );
    });

    /// The notification policy screen, whose per-network segments are the last
    /// entry in the register that lives on a screen of its own.
    sweep('notification settings', (tester) async {
      await pumpScreen(
        tester,
        const NotificationsScreen(),
        repository: demo,
        stores: stores,
        size: const Size(900, 4000),
      );
    });

    /// The chat holding a voice message and three uploads.
    ///
    /// Three of the register's entries — Transcribe, Retry and the upload's
    /// cancel — only exist while something is mid-flight or unplayed, which no
    /// state of the demo fixtures produces.
    sweep('an attachment in flight', (tester) async {
      const roomId = '!design_room:example.org';
      UploadTask task(String id, String filename, UploadState state) =>
          UploadTask(
            id: id,
            roomId: roomId,
            plan:
                planUpload(
                      AttachmentSource(
                        filename: filename,
                        sizeBytes: 96000,
                        header: Uint8List.fromList(const [
                          0xFF,
                          0xD8,
                          0xFF,
                          0xE0,
                        ]),
                      ),
                      encrypted: false,
                      maxUploadBytes: 0,
                    )
                    as UploadPlan,
            state: state,
            progress: state == UploadState.failed ? 0.6 : 0.42,
            attempts: state == UploadState.failed ? 3 : 1,
            failure: state == UploadState.failed ? 'Too large.' : null,
          );

      final repository = StubChatRepository(
        history: [
          WeftMessage(
            eventId: r'$voice',
            roomId: roomId,
            network: ChatNetwork.matrix,
            senderId: '@priya:example.org',
            senderName: 'Priya',
            timestamp: DateTime(2026, 8, 18, 14),
            kind: MessageKind.voice,
            isOwn: false,
            body: 'voice message',
            attachmentUrl: 'mxc://example.org/voice',
            durationMs: 9000,
          ),
        ],
        uploads: [
          task('upload-1', 'holiday.jpg', UploadState.uploading),
          task('upload-2', 'album.zip', UploadState.failed),
        ],
      );
      addTearDown(repository.dispose);

      await pumpScreen(
        tester,
        const ChatView(chatId: roomId),
        repository: repository,
        stores: stores,
      );
    });

    sweep('the minimised call bar', (tester) async {
      await withCallClock(() async {
        await pumpCallSurface(
          tester,
          Column(
            children: [
              MinimisedCallBar(
                state: serviceState(
                  callSession(
                    state: CallState.connected,
                    connectedAt: t0.subtract(const Duration(seconds: 5)),
                  ),
                ),
                controls: RecordingControls(),
                onOpen: () {},
              ),
              const Spacer(),
            ],
          ),
        );
        await tester.pump();
      });
    });
  });
}
