import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/contact/contact_profile.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

import 'support/golden_harness.dart';

/// The contact profile after its cleanup: the four verbs on top, the rest in
/// named groups that start closed, and nothing that was on the screen before
/// it out of reach.
void main() {
  const chatId = 'merged:anna';

  WeftStores stores() => WeftStores.inMemory()
    // Reply reminders on, so their per-chat switch is drawn at all.
    ..settings.setJson(WeftSettings.notifyReplyReminders, {'enabled': true});

  Future<void> pump(WidgetTester tester, {VoidCallback? onSearch}) => pumpWeft(
    tester,
    ContactProfileScreen(chatId: chatId, onSearch: onSearch),
    size: const Size(412, 1400),
    stores: stores(),
  );

  Chat chat(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(ContactProfileScreen)),
  ).read(chatsProvider).value!.firstWhere((c) => c.id == chatId);

  Future<void> openGroup(WidgetTester tester, String title) async {
    final group = find.text(title);
    await tester.scrollUntilVisible(
      group,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(group);
    await tester.pumpAndSettle();
  }

  Future<void> expectReachable(WidgetTester tester, String label) async {
    final row = find.text(label);
    // A label can be on the screen twice, a heading and a row; one will do.
    await tester.scrollUntilVisible(
      row.first,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(row, findsWidgets, reason: '"$label" is no longer reachable');
  }

  testWidgets('every row the profile had before is still reachable', (
    tester,
  ) async {
    await pump(tester, onSearch: () {});

    // On the screen as it opens.
    for (final label in [
      'Message',
      'Call',
      'Mute', // was a switch further down
      'Search',
      'On these networks',
      'Manage merges',
      'Archive',
    ]) {
      await expectReachable(tester, label);
    }
    // The phone number, now under the name rather than a row of its own.
    expect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == '+4915112345678',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Open in WhatsApp'), findsOneWidget);

    await openGroup(tester, 'Chat settings');
    for (final label in [
      'Nickname and photo',
      'Send new messages via',
      'Labels',
      'Disappearing messages',
    ]) {
      await expectReachable(tester, label);
    }

    await openGroup(tester, 'Notifications');
    for (final label in ['Notification sound', 'Reply reminders']) {
      await expectReachable(tester, label);
    }

    await openGroup(tester, 'Personal memory');
    // One memory per person: in a direct chat, the person's.
    await expectReachable(tester, 'About Anna Maven');

    await openGroup(tester, 'Technical details');
    for (final label in ['Matrix user', 'Conversations in this chat']) {
      await expectReachable(tester, label);
    }
    for (final address in [
      '@whatsapp_anna_wa:example.org',
      '!anna_wa_room:example.org',
    ]) {
      expect(
        find.byWidgetPredicate((w) => w is SelectableText && w.data == address),
        findsOneWidget,
      );
    }
  });

  testWidgets('the groups start closed, so ids stay out of the way', (
    tester,
  ) async {
    await pump(tester);

    for (final title in [
      'Chat settings',
      'Notifications',
      'Personal memory',
      'Technical details',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Matrix user'), findsNothing);
    expect(find.text('Nickname and photo'), findsNothing);
    // Without a conversation to search there is no Search to offer.
    expect(find.text('Search'), findsNothing);
  });

  testWidgets('Mute mutes and then offers Unmute', (tester) async {
    await pump(tester);
    expect(chat(tester).muted, isFalse);

    await tester.tap(find.text('Mute'));
    await tester.pumpAndSettle();

    expect(chat(tester).muted, isTrue);
    expect(find.text('Unmute'), findsOneWidget);
  });

  testWidgets('Search goes back to the chat and opens its search', (
    tester,
  ) async {
    var searched = 0;
    await pumpWeft(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ContactProfileScreen(
                chatId: chatId,
                onSearch: () => searched++,
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
      stores: stores(),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    expect(searched, 1);
    expect(find.byType(ContactProfileScreen), findsNothing);
  });

  testWidgets('every quick action is one labelled button', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, onSearch: () {});

    for (final label in ['Message', 'Mute', 'Search']) {
      expect(
        find.bySemanticsLabel(label),
        findsOneWidget,
        reason: '"$label" should read as one button',
      );
    }
    handle.dispose();
  });
}
