import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/thread_indicator.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import 'support/attachment_fixtures.dart';
import 'support/golden_harness.dart';
import 'support/recording_repository.dart';

/// Threads end to end through [ChatView].
///
/// The grouping itself is asserted in `weft_richtext`'s `relations_test`; what
/// is under test here is the half that only exists once there is a screen —
/// that a thread's replies are *out* of the room's timeline and behind an
/// indicator, that opening one shows exactly that thread with the root at the
/// top, that a message typed in it goes into it rather than into the room, and
/// that a network with no thread concept loses nothing.
void main() {
  /// A Matrix room from the demo inbox, so the bar and the composer are real.
  /// Matrix supports threads, which is what makes this the room to test in.
  const chatId = '!design_room:example.org';

  /// A WhatsApp room from the same inbox. WhatsApp has no thread concept, so
  /// this is where the degradation is asserted.
  const flatChatId = '!konrad_wa_room:example.org';

  final sentAt = DateTime(2026, 8, 15, 14, 20);

  WeftMessage message({
    required String eventId,
    required String body,
    required int minutesAgo,
    String roomId = chatId,
    ChatNetwork network = ChatNetwork.matrix,
    bool isOwn = false,
    String senderName = 'Priya',
    String? threadRootId,
    String? threadName,
  }) => WeftMessage(
    eventId: eventId,
    roomId: roomId,
    network: network,
    // Derived from the name, not fixed: bubble grouping runs on the
    // sender *id*, and two people sharing one id would render as one
    // person speaking twice — which is exactly the failure the group
    // check exists to prevent.
    senderId: isOwn
        ? '@me:example.org'
        : '@${senderName.toLowerCase()}:example.org',
    senderName: isOwn ? 'You' : senderName,
    timestamp: sentAt.subtract(Duration(minutes: minutesAgo)),
    kind: MessageKind.text,
    isOwn: isOwn,
    body: body,
    threadRootId: threadRootId,
    threadName: threadName,
  );

  /// A room holding one named topic with two replies, plus a message that is
  /// not in it.
  List<WeftMessage> forum({String roomId = chatId, ChatNetwork? network}) => [
    message(
      eventId: r'$root',
      body: 'anyone else seeing the flaky test?',
      threadName: 'Bugs',
      minutesAgo: 30,
      roomId: roomId,
      network: network ?? ChatNetwork.matrix,
    ),
    message(
      eventId: r'$loose',
      body: 'unrelated room message',
      minutesAgo: 20,
      roomId: roomId,
      network: network ?? ChatNetwork.matrix,
    ),
    message(
      eventId: r'$reply1',
      body: 'yes, since Tuesday',
      minutesAgo: 15,
      threadRootId: r'$root',
      threadName: 'Bugs',
      roomId: roomId,
      network: network ?? ChatNetwork.matrix,
    ),
    message(
      eventId: r'$reply2',
      body: 'looking at it now',
      minutesAgo: 10,
      senderName: 'Sam',
      threadRootId: r'$root',
      threadName: 'Bugs',
      roomId: roomId,
      network: network ?? ChatNetwork.matrix,
    ),
  ];

  group('the flat timeline', () {
    testWidgets('thread replies are behind an indicator, not in the room', (
      tester,
    ) async {
      final repository = StubChatRepository(history: forum());
      addTearDown(repository.dispose);

      await pumpWeft(
        tester,
        const ChatView(chatId: chatId),
        repository: repository,
      );

      // The root and the loose message are in the room; the replies are not.
      expect(find.text('anyone else seeing the flaky test?'), findsOneWidget);
      expect(find.text('unrelated room message'), findsOneWidget);
      expect(find.text('yes, since Tuesday'), findsNothing);
      expect(find.text('looking at it now'), findsNothing);

      // …and the indicator says both how many and what the newest one was, so
      // the replies being absent is legible rather than a hole.
      expect(find.byType(ThreadIndicator), findsOneWidget);
      expect(find.text('Bugs · 2 replies'), findsOneWidget);
      expect(find.text('Sam: looking at it now'), findsOneWidget);
    });

    testWidgets('a message with no thread has no indicator', (tester) async {
      final repository = StubChatRepository(
        history: [
          message(eventId: r'$only', body: 'just a message', minutesAgo: 5),
        ],
      );
      addTearDown(repository.dispose);

      await pumpWeft(
        tester,
        const ChatView(chatId: chatId),
        repository: repository,
      );

      expect(find.text('just a message'), findsOneWidget);
      expect(find.byType(ThreadIndicator), findsNothing);
    });

    testWidgets('an unnamed thread is labelled with its root', (tester) async {
      // A Matrix thread has no name — only the message it hangs off, which is
      // what a Matrix client shows in its place.
      final repository = StubChatRepository(
        history: [
          message(
            eventId: r'$root',
            body: 'shipping Thursday?',
            minutesAgo: 30,
          ),
          message(
            eventId: r'$reply1',
            body: 'if CI is green',
            minutesAgo: 10,
            threadRootId: r'$root',
          ),
        ],
      );
      addTearDown(repository.dispose);

      await pumpWeft(
        tester,
        const ChatView(chatId: chatId),
        repository: repository,
      );

      expect(find.text('shipping Thursday? · 1 reply'), findsOneWidget);
    });
  });

  group('a network with no threads', () {
    testWidgets('renders every message flat, losing none', (tester) async {
      // The failure this exists to prevent: a WhatsApp conversation whose
      // events happen to carry `m.thread` relations — a Matrix user in the room
      // threaded a reply — with the replies hidden behind an indicator nobody
      // on WhatsApp can open.
      final repository = _FlatStub(
        history: forum(roomId: flatChatId, network: ChatNetwork.whatsapp),
      );
      addTearDown(repository.dispose);

      await pumpWeft(
        tester,
        const ChatView(chatId: flatChatId),
        repository: repository,
      );

      expect(find.text('anyone else seeing the flaky test?'), findsOneWidget);
      expect(find.text('unrelated room message'), findsOneWidget);
      expect(find.text('yes, since Tuesday'), findsOneWidget);
      expect(find.text('looking at it now'), findsOneWidget);
      expect(find.byType(ThreadIndicator), findsNothing);
    });
  });

  group('the thread view', () {
    testWidgets('opens on the thread, with the root at the top', (
      tester,
    ) async {
      final repository = StubChatRepository(history: forum());
      addTearDown(repository.dispose);

      await pumpWeft(
        tester,
        const ChatView(chatId: chatId),
        repository: repository,
      );
      // Tapped by its label rather than by type: the indicator is wrapped in
      // an [Align] that spans the column, so the widget's own centre is empty
      // space beside the row.
      await tester.tap(find.text('Bugs · 2 replies'));
      await tester.pumpAndSettle();

      // The thread and nothing else: the root plus its replies, and the room's
      // other message left behind.
      expect(find.text('anyone else seeing the flaky test?'), findsOneWidget);
      expect(find.text('yes, since Tuesday'), findsOneWidget);
      expect(find.text('looking at it now'), findsOneWidget);
      expect(find.text('unrelated room message'), findsNothing);

      // The bar names the topic and where it lives, and the composer says
      // where the next message goes.
      expect(find.text('Bugs'), findsOneWidget);
      expect(find.text('in Design Team'), findsOneWidget);
      expect(find.text('Reply in thread'), findsWidgets);
      // No indicator inside the thread: it would be a way back to where the
      // reader already is.
      expect(find.byType(ThreadIndicator), findsNothing);
    });

    testWidgets('backing out returns to the whole conversation', (
      tester,
    ) async {
      final repository = StubChatRepository(history: forum());
      addTearDown(repository.dispose);

      await pumpWeft(
        tester,
        const ChatView(chatId: chatId),
        repository: repository,
      );
      // Tapped by its label rather than by type: the indicator is wrapped in
      // an [Align] that spans the column, so the widget's own centre is empty
      // space beside the row.
      await tester.tap(find.text('Bugs · 2 replies'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('unrelated room message'), findsOneWidget);
      expect(find.text('yes, since Tuesday'), findsNothing);
      expect(find.byType(ThreadIndicator), findsOneWidget);
    });

    testWidgets('a message typed in a thread goes into the thread', (
      tester,
    ) async {
      final inner = StubChatRepository(history: forum());
      addTearDown(inner.dispose);
      final repository = RecordingChatRepository(inner);

      await pumpWeft(
        tester,
        const ChatView(chatId: chatId),
        repository: repository,
      );
      // Tapped by its label rather than by type: the indicator is wrapped in
      // an [Align] that spans the column, so the widget's own centre is empty
      // space beside the row.
      await tester.tap(find.text('Bugs · 2 replies'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'on it');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send — hold to schedule'));
      await tester.pumpAndSettle();

      final call = repository.calls.last;
      // `sendThreadReply`, not `send`. A plain send here lands in the room —
      // visible to everyone, out of the thread the user was looking at, and
      // unrecoverable except by deleting it.
      expect(call.method, 'sendThreadReply');
      expect(call.eventId, r'$root');
      expect(call.body, 'on it');
    });

    testWidgets('a thread whose root is gone says so', (tester) async {
      // Redacted, or older than the history the server still holds. A view that
      // paged for it forever would spin on a thread nobody can open.
      final repository = StubChatRepository(
        history: [
          message(
            eventId: r'$reply1',
            body: 'answering nothing',
            minutesAgo: 10,
            threadRootId: r'$vanished',
          ),
        ],
      );
      addTearDown(repository.dispose);

      await pumpWeft(
        tester,
        const ChatView(chatId: chatId, threadRootId: r'$vanished'),
        repository: repository,
      );

      expect(find.text('This thread is no longer available.'), findsOneWidget);
    });
  });
}

/// A stub whose one source is on WhatsApp rather than Matrix.
///
/// [StubChatRepository] builds its replacement timeline on
/// [ChatNetwork.matrix], which supports threads — so a degradation test needs
/// the source to say what the chat actually is.
class _FlatStub extends StubChatRepository {
  _FlatStub({required List<WeftMessage> history}) : super(history: history);

  @override
  Future<MergedTimeline> timelineFor(String chatId) async {
    return MergedTimeline(
      sources: [
        InMemoryTimelineSource(
          roomId: chatId,
          network: ChatNetwork.whatsapp,
          pageSize: history!.length,
          history: history!,
        ),
      ],
    );
  }
}
