import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/chat/bridge_buttons_bar.dart';
import 'package:weft/features/chat/link_actions_sheet.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_richtext/weft_richtext.dart';

/// A bridged business message, end to end on the app side: the buttons the
/// bridge could only write as text, a link held down, a number tapped.
void main() {
  setUp(clearMessageDocumentCache);

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: weftLocalizationsDelegates,
      theme: WeftTheme.build(),
      home: Scaffold(body: Center(child: child)),
    ),
  );

  group('BridgeButtonsBar', () {
    testWidgets('quick replies are greyed out, with the way to answer them', (
      tester,
    ) async {
      String? tapped;
      await pump(
        tester,
        BridgeButtonsBar(
          buttons: const [
            BridgeButton(label: 'UPS Access Point Abholung'),
            BridgeButton(label: 'Abmelden'),
            BridgeButton(label: 'Track', url: 'https://ups.com/t'),
          ],
          senderId: '@whatsapp_4922112345:example.org',
          accent: Colors.indigo,
          onTapLink: (url, _) => tapped = url,
        ),
      );

      final quick = tester.widget<ActionChip>(
        find.widgetWithText(ActionChip, 'Abmelden'),
      );
      expect(quick.onPressed, isNull);
      expect(find.text('Open WhatsApp to answer'), findsOneWidget);
      expect(find.text('Open in WhatsApp'), findsOneWidget);
      // The stand-in's angle brackets are gone.
      expect(find.textContaining('<'), findsNothing);

      await tester.tap(find.widgetWithText(ActionChip, 'Track'));
      expect(tapped, 'https://ups.com/t');
    });

    testWidgets('a message with only link buttons has nothing to answer', (
      tester,
    ) async {
      await pump(
        tester,
        const BridgeButtonsBar(
          buttons: [BridgeButton(label: 'Track', url: 'https://ups.com/t')],
          senderId: '@whatsapp_4922112345:example.org',
          accent: Colors.indigo,
        ),
      );
      expect(find.text('Open in WhatsApp'), findsNothing);
    });

    test('opens the business conversation when the ghost names a number', () {
      expect(
        whatsAppChatUri('@whatsapp_4922112345:example.org'),
        Uri.parse('https://wa.me/4922112345'),
      );
      expect(
        whatsAppChatUri('@whatsapp_lid-1234:example.org'),
        Uri.parse('whatsapp://'),
      );
    });
  });

  group('link actions', () {
    Future<void> pumpText(
      WidgetTester tester,
      String body, {
      void Function(String url, String label)? onTapLink,
    }) => pump(
      tester,
      Builder(
        builder: (context) => RichTextView(
          document: parseMessageBody(body: body),
          baseStyle: const TextStyle(fontSize: 14, color: Colors.black),
          accent: context.colors.primary,
          onTapLink: onTapLink,
        ),
      ),
    );

    testWidgets('holding a link offers to open, copy and share it', (
      tester,
    ) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      String? opened;
      await pumpText(
        tester,
        'https://www.ups.com/track?tracknum=1Z01',
        onTapLink: (url, _) => opened = url,
      );

      await tester.longPress(find.byType(RichText).first);
      await tester.pumpAndSettle();
      expect(opened, isNull, reason: 'a long-press is not a tap');
      expect(find.text('Open link'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);

      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(copied, ['https://www.ups.com/track?tracknum=1Z01']);
    });

    testWidgets('a link on a preview surface stays inert when held', (
      tester,
    ) async {
      await pumpText(tester, 'https://example.org');
      await tester.longPress(find.byType(RichText).first);
      await tester.pumpAndSettle();
      expect(find.text('Open link'), findsNothing);
    });

    testWidgets('a phone number offers call, text and copy', (tester) async {
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showLinkActions(
              context,
              url: 'tel:+492211234567',
              label: '+49 221 1234567',
              onOpen: () {},
            ),
            child: const Text('go'),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Call'), findsOneWidget);
      expect(find.text('Send a text'), findsOneWidget);
      expect(find.text('Copy number'), findsOneWidget);
    });
  });

  test('an address written out is not a disguised link', () {
    expect(
      linkLabelMisleads('service@ups.com', Uri.parse('mailto:service@ups.com')),
      isFalse,
    );
  });
}
