import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// What an inbox row shows for a conversation whose newest message is a reply.
///
/// A Matrix rich reply carries the message it answers inside its own body: the
/// quoted text as `>` lines, prefixed by the sender's user id, then a blank
/// line, then the actual reply. The bubble has always stripped that — the
/// renderer runs the body through `stripReplyFallback` — but the inbox row read
/// `WeftMessage.body` straight, so a conversation whose last message was a
/// reply showed `> <@signal_1234:beeper.local> see you at six` and never showed
/// the answer at all. One line, spent on somebody else's words and a bridge's
/// internal user id.
///
/// The bodies below are real shapes, not sketches: single-line and multi-line
/// quotes, an emote fallback with its `*`, a reply to a reply arriving as
/// nested `>` runs, and the mxid-only body a bridge produces when the reply
/// itself was empty.
void main() {
  Chat chatWith(WeftMessage? last) => Chat(
    id: 'chat:anna',
    title: 'Anna Maven',
    sources: const [
      ChatSource(roomId: '!signal:example.org', network: ChatNetwork.signal),
    ],
    lastMessage: last,
  );

  WeftMessage reply({
    required String body,
    String? replyTo = r'$quoted',
    MessageKind kind = MessageKind.text,
    bool redacted = false,
  }) => WeftMessage(
    eventId: r'$last',
    roomId: '!signal:example.org',
    network: ChatNetwork.signal,
    senderId: '@anna:example.org',
    senderName: 'Anna Maven',
    timestamp: DateTime(2026, 8, 18, 14, 32),
    kind: kind,
    isOwn: false,
    body: body,
    replyToEventId: replyTo,
    redacted: redacted,
  );

  Future<void> pump(
    WidgetTester tester,
    WeftMessage? last, {
    TextDirection direction = TextDirection.ltr,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(),
        home: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: ChatTile(chat: chatWith(last), onTap: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every string the row draws, so a test can assert what is *not* there.
  List<String> textsIn(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .toList();

  group('the fallback never reaches the row', () {
    final bodies = <String, String>{
      'a single-line quote':
          '> <@signal_1234:beeper.local> are we still on for six?\n'
          '\n'
          'yes, see you then',
      'a multi-line quote':
          '> <@signal_1234:beeper.local> are we still on\n'
          '> for six, or was it seven?\n'
          '\n'
          'yes, see you then',
      'an emote fallback, with its asterisk':
          '> * <@signal_1234:beeper.local> waves\n\nyes, see you then',
      'a reply to a reply, nested':
          '> <@signal_1234:beeper.local> > <@bob:example.org> six?\n'
          '> yes\n'
          '\n'
          'yes, see you then',
      'an mx-reply block spliced in':
          '<mx-reply><blockquote>are we still on?</blockquote></mx-reply>'
          'yes, see you then',
    };

    bodies.forEach((description, body) {
      testWidgets(description, (tester) async {
        await pump(tester, reply(body: body));

        final texts = textsIn(tester);
        expect(texts, contains('yes, see you then'));
        // The two shapes that must never be rendered: a bridge's internal user
        // id, and the quote marker that introduces it.
        for (final drawn in texts) {
          expect(drawn, isNot(contains('<@')), reason: description);
          expect(drawn.startsWith('>'), isFalse, reason: description);
        }
      });
    });

    testWidgets('a body that is nothing but fallback still says something', (
      tester,
    ) async {
      // Bridges produce this: a quote and no answer under it. The stripped body
      // is empty, and an empty preview line is indistinguishable from a
      // conversation nobody has said anything in.
      await pump(
        tester,
        reply(body: '> <@signal_1234:beeper.local> are we still on for six?\n'),
      );

      final texts = textsIn(tester);
      expect(texts, contains(WeftDesignStrings.english.reply));
      expect(texts, isNot(contains(WeftDesignStrings.english.noMessagesYet)));
      for (final drawn in texts) {
        expect(drawn, isNot(contains('<@')));
      }
    });

    testWidgets('a message that merely opens with a quotation is untouched', (
      tester,
    ) async {
      // Not a reply, and not a fallback: no user id on the first line. Eating
      // it would be the opposite bug — a message deleted from its own preview.
      await pump(
        tester,
        reply(body: '> to be or not to be\n\nis the question', replyTo: null),
      );

      expect(
        textsIn(tester),
        contains('> to be or not to be\n\nis the question'),
      );
    });
  });

  group('the reply marker', () {
    testWidgets('is drawn for a reply and not for an ordinary message', (
      tester,
    ) async {
      await pump(tester, reply(body: '> <@a:b.c> q\n\nan answer'));
      expect(find.byIcon(Icons.reply_rounded), findsOneWidget);

      await pump(tester, reply(body: 'an ordinary message', replyTo: null));
      expect(find.byIcon(Icons.reply_rounded), findsNothing);
    });

    testWidgets('survives a reply to an attachment, which has no text', (
      tester,
    ) async {
      // The relation decides, not the body. A reply to a photo has nothing to
      // strip and is still a reply.
      await pump(tester, reply(body: '', kind: MessageKind.image));

      expect(find.byIcon(Icons.reply_rounded), findsOneWidget);
      expect(
        textsIn(tester).any((t) => t.contains('📷')),
        isTrue,
        reason: 'the attachment preview is what a reply to one shows',
      );
    });

    testWidgets('is not drawn for a redacted reply', (tester) async {
      // The relation survives redaction; the message does not. A reply arrow
      // over "Message deleted" points at a quote nobody can read either.
      await pump(tester, reply(body: '', redacted: true));

      expect(find.byIcon(Icons.reply_rounded), findsNothing);
      expect(
        textsIn(tester),
        contains(WeftDesignStrings.english.messageDeleted),
      );
    });

    testWidgets('is named in the row sentence, not announced on its own', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, reply(body: '> <@a:b.c> q\n\nyes, see you then'));

      final labels = <String>[];
      void walk(SemanticsNode node) {
        if (node.label.isNotEmpty) labels.add(node.label);
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(tester.getSemantics(find.byType(MaterialApp)));

      // One node, carrying the word and the answer — never the mxid.
      expect(labels.where((l) => l.contains('Reply')), hasLength(1));
      expect(labels.single, contains('yes, see you then'));
      expect(labels.single, isNot(contains('<@')));
      handle.dispose();
    });

    testWidgets('renders in RTL as well as LTR', (tester) async {
      // The glyph rides the preview line, which is laid out with `Row` — so it
      // leads in both directions or it leads in neither.
      for (final direction in TextDirection.values) {
        await pump(
          tester,
          reply(body: '> <@a:b.c> q\n\nنعم، أراك حينها'),
          direction: direction,
        );

        expect(find.byIcon(Icons.reply_rounded), findsOneWidget);
        expect(textsIn(tester), contains('نعم، أراك حينها'));

        final icon = tester.getRect(find.byIcon(Icons.reply_rounded));
        final preview = tester.getRect(find.text('نعم، أراك حينها'));
        // Leading, in the reader's direction: to the left of the words in LTR
        // and to their right in RTL.
        expect(
          direction == TextDirection.ltr
              ? icon.right <= preview.left
              : icon.left >= preview.right,
          isTrue,
          reason: 'the marker must lead the preview in $direction',
        );
      }
    });
  });
}
