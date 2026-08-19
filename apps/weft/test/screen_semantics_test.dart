import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/search_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/components/qr_card.dart';
import 'package:weft/features/merge/merge_screen.dart';
import 'package:weft/features/search/search_screen.dart';
import 'package:weft/features/settings/settings_section.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';

import 'support/semantics_probe.dart';

/// What the screens outside the conversation say to a screen reader.
///
/// Task 3 gave the inbox, the chat and the composer a voice; the audit's other
/// eighty findings live here — the settings screens, merge, search, bridges and
/// the surfaces a call puts on top of everything. The failures they share are
/// not the timeline's. Here the recurring one is a **button that does not say
/// what it acts on**: four cards, four buttons reading "Merge", and no way to
/// tell which two people the third one joins. The other is a **result nobody is
/// told about** — a merge, a probe, a stage change and a share all report
/// themselves by redrawing a list, which is a complete report for someone
/// watching and none at all for someone listening.
void main() {
  group('merge screen', () {
    Future<DemoChatRepository> pumpMerge(WidgetTester tester) async {
      final repository = DemoChatRepository();
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: const MergeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('a suggestion is one sentence, not seven nodes', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpMerge(tester);

      // Two handles, a percentage and a row of evidence chips, announced in
      // layout order, are the parts of a sentence with the sentence taken out.
      final proposal = labelsIn(
        tester,
      ).firstWhere((label) => label.contains('may be the same person'));
      expect(proposal, contains('Michael Johnson on WhatsApp'));
      expect(proposal, contains('% confident'));
      expect(proposal, contains('Very similar name'));
      handle.dispose();
    });

    testWidgets('both decisions name the two people they act on', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpMerge(tester);

      final labels = labelsIn(tester);
      expect(
        labels.where((l) => l.startsWith('Merge ') && l.contains(' with ')),
        isNotEmpty,
        reason: 'a bare "Merge" is four identical buttons on a busy screen',
      );
      expect(
        labels.where(
          (l) => l.startsWith('Not the same person:') && l.contains('separate'),
        ),
        isNotEmpty,
      );
      // Anna's three legs would otherwise be three buttons saying "Unmerge".
      final unmerges = labels.where((l) => l.startsWith('Unmerge '));
      expect(unmerges, hasLength(3));
      expect(unmerges.toSet(), hasLength(3), reason: 'one per leg, named');
      handle.dispose();
    });

    testWidgets('the two section titles are headings', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpMerge(tester);

      expect(
        tester.getSemantics(find.text('Suggestions')),
        matchesSemantics(label: 'Suggestions', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('merging says what it merged', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpMerge(tester);
      final announced = watchAnnouncements(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
      await tester.pumpAndSettle();

      // The card vanishing is the whole report a sighted user gets. A reader
      // is left on whatever moved up into the gap.
      expect(announced, hasLength(1));
      expect(announced.single, contains('Merged Michael Johnson on WhatsApp'));
      expect(announced.single, contains('now one conversation'));
      handle.dispose();
    });

    testWidgets('rejecting says the two are being kept apart', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpMerge(tester);
      final announced = watchAnnouncements(tester);

      await tester.tap(find.text('Not the same person'));
      await tester.pumpAndSettle();

      expect(announced.single, contains('kept separate'));
      expect(announced.single, contains('will not come back'));
      handle.dispose();
    });
  });

  group('search', () {
    late WeftStores stores;

    setUp(() => stores = WeftStores.inMemory());
    tearDown(() => stores.dispose());

    /// Indexes [messages] and opens the search screen over that index.
    Future<void> pumpSearch(
      WidgetTester tester,
      List<WeftMessage> messages, {
      String? query,
    }) async {
      for (final message in messages) {
        stores.search.indexMessage(
          message,
          chatId: message.roomId,
          chatTitle: 'The Thursday plan',
        );
      }
      final repository = DemoChatRepository();
      addTearDown(repository.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesProvider.overrideWithValue(stores),
            chatRepositoryProvider.overrideWithValue(repository),
            searchEngineProvider.overrideWithValue(
              SearchEngine(backend: stores.search),
            ),
          ],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: SearchScreen(initialQuery: query),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    WeftMessage indexed({
      String eventId = r'$one',
      String body = 'the roof is on fire',
      String sender = 'Grace',
    }) => WeftMessage(
      eventId: eventId,
      roomId: '!room:example.org',
      network: ChatNetwork.telegram,
      senderId: '@grace:example.org',
      senderName: sender,
      timestamp: DateTime(2026, 8, 18, 14, 32),
      kind: MessageKind.text,
      isOwn: false,
      body: body,
    );

    testWidgets('the field keeps its name after the first keystroke', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSearch(tester, [indexed()], query: 'roof');

      // The hint was the field's only name, and a hint is gone the moment
      // anything is typed.
      expect(labelsIn(tester), contains('Search all conversations'));
      handle.dispose();
    });

    testWidgets('the result count is a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSearch(tester, [
        indexed(),
        indexed(eventId: r'$two', body: 'the roof leaks'),
      ], query: 'roof');

      expect(liveRegionsIn(tester), contains('2 results'));
      handle.dispose();
    });

    testWidgets('an empty search says so, once', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSearch(tester, [indexed()], query: 'submarine');

      expect(liveRegionsIn(tester), contains('Nothing matched.'));
      // Said in one place rather than two: a summary line *and* a centred
      // "Nothing matched" is one sentence for a sighted user and two
      // announcements for a reader.
      expect(find.text('Nothing matched.'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a result names the chat, the sender and the network', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSearch(tester, [indexed()], query: 'roof');

      final result = labelsIn(
        tester,
      ).firstWhere((label) => label.contains('the roof is on fire'));
      // Both were on the index row all along and read back by nobody: the row
      // showed a message with no statement of who said it or where.
      expect(result, contains('In The Thursday plan'));
      expect(result, contains('Grace'));
      expect(result, contains('Telegram'));
      handle.dispose();
    });
  });

  group('settings pieces', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: WeftTheme.build(),
          home: Scaffold(body: child),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a privacy notice is named as a warning, in one node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        const PrivacyNotice(message: 'This undoes end-to-end encryption.'),
      );

      // The red box and the shield glyph are the whole signal that this is not
      // more explanatory copy, and a reader gets neither.
      expect(
        labelsIn(tester),
        contains('Privacy warning. This undoes end-to-end encryption.'),
      );
      handle.dispose();
    });

    testWidgets('a gated switch carries the cost of turning it on', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var value = false;
      await pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SwitchListTile(
            title: const PrivacyGatedTitle(
              title: 'Enable embeddings',
              warning: 'Turning this on sends your messages to the endpoint.',
            ),
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      );

      // A reader who lands on the switch — by heading jump, by touch, by
      // returning to a screen they have used before — never passes the notice
      // at the top of the list.
      final node = tester.getSemantics(find.byType(SwitchListTile));
      expect(node.hint, 'Turning this on sends your messages to the endpoint.');
      expect(node.label, contains('Enable embeddings'));

      // And the switch still works: a hint that cost the toggle its action
      // would be a worse bug than the one it fixes.
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(value, isTrue);
      handle.dispose();
    });

    testWidgets('a section header is a heading a reader can jump to', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        const SettingsSectionHeader(
          title: 'Voice transcription',
          subtitle: 'Only needed if you are not using an on-device model.',
        ),
      );

      expect(
        tester.getSemantics(find.byType(SettingsSectionHeader)),
        matchesSemantics(
          label:
              'Voice transcription. Only needed if you are not using an '
              'on-device model.',
          isHeader: true,
        ),
      );
      handle.dispose();
    });
  });

  group('QR card', () {
    testWidgets('says what it is and where the alternative is', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: WeftTheme.build(),
          home: const Scaffold(
            body: Center(child: QrCard.data('https://example.org/pair')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 220dp of nothing, before this. There is no label that makes a rendered
      // code *usable* by ear, so the label's job is to name the way round it.
      final label = labelsIn(tester).single;
      expect(label, contains('QR code'));
      expect(label, contains('text version'));
      handle.dispose();
    });

    testWidgets('a caller can steer a reader somewhere better', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: WeftTheme.build(),
          home: const Scaffold(
            body: Center(
              child: QrCard.data(
                'https://example.org/pair',
                semanticsLabel: 'QR code. Or compare emoji instead.',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(labelsIn(tester).single, 'QR code. Or compare emoji instead.');
      handle.dispose();
    });
  });
}
