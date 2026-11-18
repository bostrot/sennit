// What a screen reader says in a language other than English.
//
// These labels are built with `semanticsSentence`, whose parts were English
// literals the l10n audit could not see: the `label:` rule found a call, not a
// string. A German reader heard "Replying to Anna, on WhatsApp" and a reply to
// a photo drew "Photo" on the quote, whatever the app's language.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/chat/message_actions_sheet.dart';
import 'package:weft/features/chat/reply_chip.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('de'),
  double textScale = 1,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: weftLocalizationsDelegates,
      theme: WeftTheme.build(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

const _photoReply = ReplyPreview(
  eventId: r'$photo',
  roomId: '!r:example.org',
  senderId: '@anna:example.org',
  senderName: 'Anna',
  kind: MessageKind.image,
  network: ChatNetwork.whatsapp,
);

WeftMessage _message({bool isOwn = false, bool redacted = false}) =>
    WeftMessage(
      eventId: r'$m1',
      roomId: '!r:example.org',
      network: ChatNetwork.whatsapp,
      senderId: '@anna:example.org',
      senderName: 'Anna',
      body: 'Bis morgen',
      timestamp: DateTime.utc(2026, 11, 18, 9),
      isOwn: isOwn,
      kind: MessageKind.text,
      redacted: redacted,
    );

void main() {
  group('reply chip', () {
    testWidgets('names a quoted photo and its network in German', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, const ReplyChip(preview: _photoReply, own: false));

      expect(find.text('Foto'), findsOneWidget);
      expect(find.text('Photo'), findsNothing);
      expect(
        find.bySemanticsLabel('Antwort an Anna, auf WhatsApp, Foto'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('a quote not loaded yet is drawn and read in Chinese', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        const ReplyChip(preview: ReplyPreview.stub(r'$gone'), own: false),
        locale: const Locale('zh'),
      );

      expect(find.text('回复一条消息'), findsOneWidget);
      expect(find.text('尚未加载，点按查找'), findsOneWidget);
      expect(find.bySemanticsLabel('回复一条消息, 尚未加载，点按查找'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the longer German stub fits a phone at 2× text', (
      tester,
    ) async {
      await _pump(
        tester,
        const SizedBox(
          width: 300,
          child: ReplyChip(preview: ReplyPreview.stub(r'$gone'), own: true),
        ),
        textScale: 2,
        size: const Size(320, 640),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Antwort auf eine Nachricht'), findsOneWidget);
    });
  });

  group('message actions sheet', () {
    Future<void> open(WidgetTester tester, WeftMessage message) async {
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showMessageActionsSheet(context, message: message),
            child: const Text('open'),
          ),
        ),
        size: const Size(1280, 900),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('says whose message it acts on in German', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester, _message());

      expect(
        find.bySemanticsLabel(
          'Aktionen für die Nachricht von Anna, Bis morgen',
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('an own, deleted message', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester, _message(isOwn: true, redacted: true));

      expect(
        find.bySemanticsLabel(
          'Aktionen für deine Nachricht, Nachricht gelöscht',
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });
}
