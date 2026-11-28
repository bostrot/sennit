// The long-press sheet: one row of quick reactions, then the actions.
//
// What the owner's phone drew instead: the four fixed emoji spread across the
// sheet, an `mxc://` URI as large text under them, and the last emoji and the
// picker button on a third line. The URI was a custom emoji the reader had
// once reacted with, kept in the recents and drawn by the row as text.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/chat/emoji_picker_sheet.dart';
import 'package:weft/features/chat/message_actions_sheet.dart';
import 'package:weft/features/chat/reaction_bar.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

const _custom = 'mxc://sosnowkadub.de/oqtPprznzrRiQzEJntyYIzUw';

WeftMessage _message({
  MessageKind kind = MessageKind.text,
  String body = 'Bis morgen',
  String? attachmentUrl,
  String? attachmentName,
  List<ReactionTally> reactions = const [],
}) => WeftMessage(
  eventId: r'$m1',
  roomId: '!r:example.org',
  network: ChatNetwork.whatsapp,
  senderId: '@anna:example.org',
  senderName: 'Anna',
  body: body,
  timestamp: DateTime.utc(2026, 11, 28, 9),
  isOwn: false,
  kind: kind,
  attachmentUrl: attachmentUrl,
  attachmentName: attachmentName,
  reactions: reactions,
);

Future<void> _open(
  WidgetTester tester,
  WeftMessage message, {
  Size size = const Size(390, 844),
  Locale locale = const Locale('de'),
  double textScale = 1,
  List<String> quickReactions = kQuickReactions,
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
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMessageActionsSheet(
              context,
              message: message,
              quickReactions: quickReactions,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The vertical centre of every control in the quick row.
Set<double> _rowCentres(WidgetTester tester) => {
  for (final key in kQuickReactions)
    tester.getCenter(find.text(key)).dy.roundToDouble(),
  tester.getCenter(find.byIcon(Icons.add_reaction_outlined)).dy.roundToDouble(),
};

void main() {
  group('quick row', () {
    for (final (name, size) in const [
      // 360dp is the narrowest common Android phone, and exactly as wide as
      // seven 48dp targets and the sheet's padding.
      ('a small phone', Size(360, 640)),
      ('a phone', Size(390, 844)),
      ('a tablet', Size(800, 1280)),
    ]) {
      testWidgets('is one line on $name', (tester) async {
        await _open(tester, _message(), size: size);
        expect(tester.takeException(), isNull);
        expect(_rowCentres(tester), hasLength(1));
        // Above the actions, not among them.
        expect(
          tester.getCenter(find.text('😢')).dy,
          lessThan(tester.getTopLeft(find.text('Antworten')).dy),
        );
      });
    }

    testWidgets('is one line right to left', (tester) async {
      await _open(tester, _message(), locale: const Locale('ar'));
      expect(tester.takeException(), isNull);
      expect(_rowCentres(tester), hasLength(1));
      // The picker button ends the row on the reader's side.
      expect(
        tester.getCenter(find.byIcon(Icons.add_reaction_outlined)).dx,
        lessThan(tester.getCenter(find.text('👍')).dx),
      );
    });

    for (final (name, size, scale) in const [
      ('at 2× text', Size(360, 640), 2.0),
      ('on a 320dp screen', Size(320, 568), 1.0),
    ]) {
      testWidgets('wraps rather than clipping $name', (tester) async {
        await _open(tester, _message(), size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        // Every control is still on screen, the picker button included, and
        // the row is still above the actions.
        for (final key in kQuickReactions) {
          expect(find.text(key).hitTestable(), findsOneWidget);
        }
        expect(
          find.byIcon(Icons.add_reaction_outlined).hitTestable(),
          findsOneWidget,
        );
        expect(
          tester.getBottomLeft(find.byIcon(Icons.add_reaction_outlined)).dy,
          lessThan(tester.getTopLeft(find.text('Antworten')).dy),
        );
      });
    }

    testWidgets('never draws a custom emoji URI', (tester) async {
      await _open(
        tester,
        _message(),
        quickReactions: const ['👍', '❤️', '😂', '😮', _custom, '😢'],
      );
      expect(find.textContaining('mxc://'), findsNothing);
      expect(find.text('😢'), findsOneWidget);
    });

    test('the recents never keep a custom emoji', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(reactionRecentsProvider.notifier)
        ..note(_custom)
        ..note('🎉');
      expect(container.read(reactionRecentsProvider), ['🎉']);
    });
  });

  group('copy and select', () {
    testWidgets('are offered for a text message', (tester) async {
      await _open(tester, _message());
      expect(find.text('Text kopieren'), findsOneWidget);
      expect(find.text('Text auswählen'), findsOneWidget);
    });

    testWidgets('are not offered for a photo named by its file', (
      tester,
    ) async {
      await _open(
        tester,
        _message(
          kind: MessageKind.image,
          body: 'IMG_4021.jpg',
          attachmentUrl: 'mxc://example.org/photo',
        ),
      );
      expect(find.text('Text kopieren'), findsNothing);
      expect(find.text('Text auswählen'), findsNothing);
    });

    testWidgets('are offered for a captioned photo', (tester) async {
      await _open(
        tester,
        _message(
          kind: MessageKind.image,
          body: 'Am Strand',
          attachmentName: 'IMG_4021.jpg',
          attachmentUrl: 'mxc://example.org/photo',
        ),
      );
      expect(find.text('Text kopieren'), findsOneWidget);
    });

    test('a sticker and a bare mxc body have no words', () {
      expect(
        hasWords(
          _message(
            kind: MessageKind.sticker,
            body: 'a cat waving',
            attachmentUrl: 'mxc://example.org/cat',
          ),
        ),
        isFalse,
      );
      expect(hasWords(_message(body: _custom)), isFalse);
      expect(hasWords(_message(body: '  ')), isFalse);
      expect(hasWords(_message()), isTrue);
    });
  });

  group('reaction chip', () {
    testWidgets('draws a custom emoji as a glyph and names it', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(390, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('de'),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: Scaffold(
            body: Center(
              child: ReactionChip(
                tally: ReactionTally(
                  key: _custom,
                  senderIds: const ['@anna:example.org', '@ben:example.org'],
                  firstReactedAt: DateTime.utc(2026, 11, 28),
                ),
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('mxc://'), findsNothing);
      expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Eigenes Emoji')), findsOneWidget);
      semantics.dispose();
    });
  });
}
