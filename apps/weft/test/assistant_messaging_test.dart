import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:weft/app/intents.dart';
import 'package:weft/app/shortcuts.dart';
import 'package:weft/features/chat/chat_view.dart';

import 'support/golden_harness.dart';

/// "Hey Google, send a message to Anna on Sennit": what Sennit declares so
/// the assistant can find it, and what it does when the assistant arrives.
///
/// The assistant itself cannot run here. What is pinned is Sennit's side of
/// the seam: the App Actions capability and the shortcut bindings the system
/// reads, the link the capability opens, and the composer that link fills.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android declarations', () {
    test('shortcuts.xml offers CREATE_MESSAGE through the compose link', () {
      final xml = File(
        'android/app/src/main/res/xml/shortcuts.xml',
      ).readAsStringSync();

      expect(
        xml,
        contains('<capability android:name="actions.intent.CREATE_MESSAGE">'),
      );
      expect(xml, contains('weft://compose{?recipient,text}'));
      expect(
        xml,
        matches(
          RegExp(
            r'android:name="message.recipient.name"\s+android:key="recipient"',
          ),
        ),
      );
      expect(
        xml,
        matches(RegExp(r'android:name="message.text"\s+android:key="text"')),
      );
      // The share target is still there: one file, two jobs.
      expect(xml, contains('<share-target'));
    });

    test('conversation shortcuts are bound for the assistant', () {
      final kotlin = File(
        'android/app/src/main/kotlin/com/bostrot/weft/ShareShortcuts.kt',
      ).readAsStringSync();

      expect(kotlin, contains('"actions.intent.SEND_MESSAGE"'));
      expect(kotlin, contains('"actions.intent.RECEIVE_MESSAGE"'));
      expect(kotlin, contains('addCapabilityBinding('));
      expect(kotlin, contains('"message.recipient.@type"'));
      expect(kotlin, contains('listOf("Audience")'));
      expect(kotlin, contains('.setLongLived(true)'));
      expect(kotlin, contains('.setIsConversation()'));
      expect(kotlin, contains('.setPerson(person)'));
      expect(kotlin, contains('.setLocusId(LocusIdCompat(id))'));
      expect(kotlin, contains('ShortcutManagerCompat.pushDynamicShortcut'));
    });

    test('the shortcuts reach Google surfaces, not only the launcher', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('androidx.core:core-google-shortcuts:'));
    });

    test('the notification shortcut says whether it is a group', () {
      final kotlin = File(
        'android/app/src/main/kotlin/com/bostrot/weft/MainActivity.kt',
      ).readAsStringSync();
      expect(kotlin, contains('call.argument<Boolean>("isGroup")'));
    });
  });

  group('compose link', () {
    test('reads the name and the text the capability fills in', () {
      final link = WeftLink.parse(
        'weft://compose?recipient=Anna%20Maria&text=I%27m%20late%2C%20sorry',
      );

      expect(link, isA<ComposeMessageLink>());
      link as ComposeMessageLink;
      expect(link.recipient, 'Anna Maria');
      expect(link.text, "I'm late, sorry");
    });

    test('a name without a message, and neither, are both links', () {
      final named = WeftLink.parse('weft://compose?recipient=Alex')!;
      expect((named as ComposeMessageLink).recipient, 'Alex');
      expect(named.text, isEmpty);

      final bare = WeftLink.parse('weft://compose')!;
      expect((bare as ComposeMessageLink).recipient, isEmpty);
      expect(bare.text, isEmpty);
    });

    test('the web link spells it the same way', () {
      final link = WeftLink.parse(
        'https://weft.bostrot.com/compose?recipient=Alex&text=hi',
      );
      expect((link! as ComposeMessageLink).text, 'hi');
    });
  });

  group('ComposerPrefill', () {
    test('hands text over once, under any of the ids', () {
      final prefill = ComposerPrefill()..offer('merged:anna', '  on my way ');

      expect(prefill.take(['!room:x']), isNull);
      expect(prefill.take(['!room:x', 'merged:anna']), 'on my way');
      expect(prefill.take(['merged:anna']), isNull);
    });

    test('ignores an empty message and tells listeners about a real one', () {
      final prefill = ComposerPrefill();
      var heard = 0;
      prefill.addListener(() => heard++);

      prefill.offer('a', '   ');
      expect(heard, 0);
      expect(prefill.take(['a']), isNull);

      prefill.offer('a', 'hi');
      expect(heard, 1);
    });
  });

  group('the conversation takes dictated text', () {
    setUpAll(loadGoldenFonts);

    String composerText(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField).first).controller!.text;

    testWidgets('into an open conversation, unsent and after the draft', (
      tester,
    ) async {
      await pumpWeft(tester, const ChatView(chatId: 'merged:anna'));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatView)),
      );

      await tester.enterText(find.byType(TextField).first, 'Hey');
      container.read(composerPrefillProvider).offer('merged:anna', "I'm late");
      await tester.pump();

      expect(composerText(tester), "Hey I'm late");
    });

    testWidgets('not into a different conversation', (tester) async {
      await pumpWeft(tester, const ChatView(chatId: 'merged:anna'));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatView)),
      );

      final prefill = container.read(composerPrefillProvider)
        ..offer('someone-else', 'not for Anna');
      await tester.pump();

      expect(composerText(tester), isEmpty);
      expect(prefill.take(['someone-else']), 'not for Anna');
    });
  });
}
