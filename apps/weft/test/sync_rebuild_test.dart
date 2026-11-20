import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft_design/weft_design.dart';

import 'support/golden_harness.dart';
import 'support/load_repository.dart';

/// What a sync is allowed to rebuild.
///
/// The repository re-emits the inbox after every sync, and the screens used to
/// answer each one by rebuilding everything visible. They no longer do — which
/// makes two promises worth pinning: a sync that changed nothing on screen
/// rebuilds nothing, and the things a sync changes *without* changing a
/// conversation (who is typing, who has read what) still arrive.
void main() {
  LoadChatRepository repository() =>
      LoadChatRepository(chatCount: 40, groupMessages: 60, groupMembers: 4);

  group('the inbox', () {
    for (final surface in WeftSurface.values) {
      testWidgets('a sync that changed nothing rebuilds no row '
          '(${surface.name})', (tester) async {
        final repo = repository();
        await pumpWeft(
          tester,
          const InboxShell(),
          repository: repo,
          surface: surface,
        );
        final before = tester.widgetList<ChatTile>(find.byType(ChatTile));
        expect(before, isNotEmpty);

        repo.tick(changeOne: false);
        await tester.pumpAndSettle();

        final after = tester.widgetList<ChatTile>(find.byType(ChatTile));
        expect(after.length, before.length);
        for (var i = 0; i < before.length; i++) {
          expect(
            identical(after.elementAt(i), before.elementAt(i)),
            isTrue,
            reason: 'row $i was rebuilt by a sync that touched nothing',
          );
        }
      });

      testWidgets('a sync that changed one conversation rebuilds that row '
          'and no other (${surface.name})', (tester) async {
        final repo = repository();
        await pumpWeft(
          tester,
          const InboxShell(),
          repository: repo,
          surface: surface,
        );
        Map<String, ChatTile> rows() => {
          for (final tile in tester.widgetList<ChatTile>(find.byType(ChatTile)))
            tile.chat.id: tile,
        };
        final before = rows();

        repo.tick();
        await tester.pumpAndSettle();

        final after = rows();
        final rebuilt = [
          for (final id in after.keys)
            if (before.containsKey(id) && !identical(after[id], before[id])) id,
        ];
        expect(rebuilt, hasLength(1));
        expect(after[rebuilt.single]!.chat.unreadCount, greaterThan(0));
      });

      testWidgets('someone starting to type reaches their row '
          '(${surface.name})', (tester) async {
        final repo = repository();
        await pumpWeft(
          tester,
          const InboxShell(),
          repository: repo,
          surface: surface,
        );
        bool typing() => tester
            .widgetList<ChatTile>(find.byType(ChatTile))
            .any((tile) => tile.typing);
        expect(typing(), isFalse);

        repo.typingChats.add(LoadChatRepository.groupChatId);
        repo.tick(changeOne: false);
        await tester.pumpAndSettle();
        expect(typing(), isTrue);

        repo.typingChats.clear();
        repo.tick(changeOne: false);
        await tester.pumpAndSettle();
        expect(typing(), isFalse);
      });
    }
  });

  group('an open conversation', () {
    testWidgets('a read receipt turns the ticks without a new message', (
      tester,
    ) async {
      final repo = repository();
      await pumpWeft(
        tester,
        const ChatView(chatId: LoadChatRepository.groupChatId),
        repository: repo,
        size: const Size(412, 915),
      );
      expect(find.byTooltip('Read'), findsNothing);

      repo.everyoneHasRead = true;
      repo.tick(changeOne: false);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Read'), findsWidgets);
    });

    testWidgets('a sync elsewhere in the account rebuilds no bubble', (
      tester,
    ) async {
      final repo = repository();
      await pumpWeft(
        tester,
        const ChatView(chatId: LoadChatRepository.groupChatId),
        repository: repo,
        size: const Size(412, 915),
      );
      final before = tester
          .widgetList<RichText>(find.byType(RichText))
          .toList();
      expect(before, isNotEmpty);

      // Another conversation gets a message; this one is untouched.
      repo.tick();
      await tester.pumpAndSettle();

      final after = tester.widgetList<RichText>(find.byType(RichText)).toList();
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(identical(after[i], before[i]), isTrue);
      }
    });

    // Every message row on screen, by event id.
    Map<String, WeftSelectionLine> rows(WidgetTester tester) => {
      for (final line in tester.widgetList<WeftSelectionLine>(
        find.byType(WeftSelectionLine),
      ))
        if (line.key case ValueKey<String>(:final value)) value: line,
    };

    // Whether `$g_i` is the user's own message, as the load repository
    // assigns them: runs of three, member 0 is the user.
    bool isOwn(String eventId, int members) =>
        (int.parse(eventId.substring(3)) ~/ 3) % members == 0;

    testWidgets('someone starting and stopping typing rebuilds no bubble', (
      tester,
    ) async {
      // The composer's keystrokes compete with every rebuild a sync causes,
      // and in a live group someone starts or stops typing every few
      // seconds. Each of those used to redraw the whole conversation.
      final semantics = tester.ensureSemantics();
      final repo = repository();
      await pumpWeft(
        tester,
        const ChatView(chatId: LoadChatRepository.groupChatId),
        repository: repo,
        size: const Size(412, 915),
      );
      final before = rows(tester);
      expect(before, isNotEmpty);

      repo.typingChats.add(LoadChatRepository.groupChatId);
      repo.tick(changeOne: false);
      // Not settled: the dots repeat for as long as somebody types.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Member 1 is typing…'), findsOneWidget);
      expect(find.bySemanticsLabel('Member 1 is typing'), findsOneWidget);
      var after = rows(tester);
      for (final id in before.keys) {
        if (!after.containsKey(id)) continue;
        expect(identical(after[id], before[id]), isTrue, reason: id);
      }

      repo.typingChats.clear();
      repo.tick(changeOne: false);
      await tester.pumpAndSettle();

      expect(find.text('Member 1 is typing…'), findsNothing);
      expect(find.bySemanticsLabel('Member 1 is typing'), findsNothing);
      after = rows(tester);
      for (final id in before.keys) {
        if (!after.containsKey(id)) continue;
        expect(identical(after[id], before[id]), isTrue, reason: id);
      }
      semantics.dispose();
    });

    testWidgets('a peer read receipt rebuilds only the user\'s own bubbles', (
      tester,
    ) async {
      final repo = repository();
      await pumpWeft(
        tester,
        const ChatView(chatId: LoadChatRepository.groupChatId),
        repository: repo,
        size: const Size(412, 915),
      );
      final before = rows(tester);
      expect(before.keys.where((id) => isOwn(id, 4)), isNotEmpty);
      expect(before.keys.where((id) => !isOwn(id, 4)), isNotEmpty);

      repo.everyoneHasRead = true;
      repo.tick(changeOne: false);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Read'), findsWidgets);
      final after = rows(tester);
      for (final id in before.keys) {
        if (!after.containsKey(id)) continue;
        expect(
          identical(after[id], before[id]),
          !isOwn(id, 4),
          reason: isOwn(id, 4)
              ? '$id is the user\'s own and has ticks to turn'
              : '$id is someone else\'s and has nothing a receipt changes',
        );
      }
    });
  });
}
