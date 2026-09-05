import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/inbox/requests_screen.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/data/demo_repository.dart';

import 'support/golden_harness.dart';
import 'support/recording_repository.dart';

/// Chat requests through the inbox.
///
/// The state machine and the per-network mappings are asserted in
/// `weft_domain`'s `request_test`; what is under test here is the half that
/// only exists once there is an inbox — that a request is *out* of the
/// conversation list, that it is one tap away rather than gone, and that the
/// three buttons reach the repository with the action the user pressed.
void main() {
  Chat chat({
    required String id,
    required String title,
    ChatNetwork network = ChatNetwork.signal,
    ChatRequestState? request,
    String body = 'hello there',
  }) => Chat(
    id: id,
    title: title,
    sources: [ChatSource(roomId: id, network: network)],
    request: request,
    lastMessage: WeftMessage(
      eventId: '\$last_$id',
      roomId: id,
      network: network,
      senderId: '@them:example.org',
      senderName: title,
      timestamp: DateTime(2026, 8, 15, 14),
      kind: MessageKind.text,
      isOwn: false,
      body: body,
    ),
  );

  List<Chat> inbox() => [
    chat(id: '!known:example.org', title: 'Anna', body: 'see you at six'),
    chat(
      id: '!stranger:example.org',
      title: 'Unknown Number',
      request: ChatRequestState.pending,
      body: 'hi, is this the right number for Sam?',
    ),
    chat(
      id: '!spam:example.org',
      title: 'Delivery Bot',
      request: ChatRequestState.pending,
      body: 'YOUR PARCEL IS WAITING',
    ),
  ];

  group('the inbox', () {
    testWidgets('holds requests out of the conversation list', (tester) async {
      final repository = _RequestInbox(inbox());
      addTearDown(repository.dispose);

      await pumpWeft(tester, const InboxShell(), repository: repository);

      expect(find.text('Anna'), findsOneWidget);
      // Out of the list, but not gone: the entry row says how many are waiting.
      expect(find.text('Unknown Number'), findsNothing);
      expect(find.text('Delivery Bot'), findsNothing);
      expect(find.byType(RequestsEntry), findsOneWidget);
      expect(find.text('2 people want to talk'), findsOneWidget);
    });

    testWidgets('shows no entry row when nothing is waiting', (tester) async {
      final repository = _RequestInbox([
        chat(id: '!known:example.org', title: 'Anna'),
      ]);
      addTearDown(repository.dispose);

      await pumpWeft(tester, const InboxShell(), repository: repository);

      expect(find.text('Anna'), findsOneWidget);
      expect(find.text('Message requests'), findsNothing);
    });
  });

  group('the requests screen', () {
    Future<RecordingChatRepository> open(WidgetTester tester) async {
      final inner = _RequestInbox(inbox());
      addTearDown(inner.dispose);
      final repository = RecordingChatRepository(inner);

      await pumpWeft(tester, const InboxShell(), repository: repository);
      await tester.tap(find.text('Message requests'));
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('lists every request, and says what reading one does not do', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('Unknown Number'), findsOneWidget);
      expect(find.text('Delivery Bot'), findsOneWidget);
      // The preview is what lets a person be told from a spammer without
      // opening anything, which is the point of a request.
      expect(
        find.text('hi, is this the right number for Sam?'),
        findsOneWidget,
      );
      // Stated on the screen, because it is the promise the feature makes.
      expect(
        find.textContaining('cannot see that you have read this'),
        findsOneWidget,
      );
      // The conversations the user *has* accepted are not here.
      expect(find.text('Anna'), findsNothing);
    });

    testWidgets('accept, decline and block each reach the repository', (
      tester,
    ) async {
      for (final (label, action) in const [
        ('Accept', ChatRequestAction.accept),
        ('Decline', ChatRequestAction.decline),
        ('Block', ChatRequestAction.block),
      ]) {
        final repository = await open(tester);
        await tester.tap(find.text(label).first);
        await tester.pumpAndSettle();

        final call = repository.calls.last;
        expect(call.method, 'answerChatRequest');
        expect(call.key, action.name, reason: 'pressing $label');
      }
    });

    testWidgets('accepting moves the conversation into the inbox', (
      tester,
    ) async {
      final repository = await open(tester);
      await tester.tap(find.text('Accept').first);
      await tester.pumpAndSettle();

      // One request answered, one left.
      expect(find.text('Unknown Number'), findsNothing);
      expect(find.text('Delivery Bot'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Unknown Number'), findsOneWidget);
      expect(find.text('1 person wants to talk'), findsOneWidget);
      expect(repository.calls.last.key, ChatRequestAction.accept.name);
    });

    // Two tests rather than one, because the thing being compared is a
    // *message on screen* and a second run in the same tree would be asserting
    // against the first one's bar as well as its own.
    testWidgets('declining says the sender can write again', (tester) async {
      await open(tester);
      await tester.tap(find.text('Decline').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('They can write again'), findsOneWidget);
      expect(find.textContaining('cannot write again'), findsNothing);
    });

    testWidgets('blocking says they cannot', (tester) async {
      // From the outside the two are identical — the row goes — and the
      // difference is whether the sender can reach the user again, which is
      // exactly the thing they need to know they chose.
      await open(tester);
      await tester.tap(find.text('Block').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('They cannot write again'), findsOneWidget);
    });

    testWidgets('reading a request opens it without accepting it', (
      tester,
    ) async {
      final repository = await open(tester);
      await tester.tap(find.text('Read').first);
      await tester.pumpAndSettle();

      // Nothing was answered by looking.
      expect(
        repository.calls.where((c) => c.method == 'answerChatRequest'),
        isEmpty,
      );
      // …and nothing was marked read, which is the promise the screen makes.
      expect(repository.calls.where((c) => c.method == 'markRead'), isEmpty);
    });
  });
}

/// An inbox of exactly the chats a test states, answering requests for real.
///
/// [DemoChatRepository]'s own fixtures have no requests in them and adding one
/// would change every golden that draws the demo inbox. This holds a stated
/// list instead and reimplements only the two members that matter — the stream
/// the inbox watches, and the verb the buttons press — so what the screen does
/// with an accepted request is the production code path.
class _RequestInbox extends DemoChatRepository {
  _RequestInbox(List<Chat> chats) : _chats = [...chats];

  List<Chat> _chats;
  final _controller = StreamController<List<Chat>>.broadcast();

  @override
  Stream<List<Chat>> watchChats() async* {
    yield _chats;
    yield* _controller.stream;
  }

  @override
  Future<ChatRequestState?> answerChatRequest(
    String chatId,
    ChatRequestAction action,
  ) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index < 0) return null;
    final current = _chats[index].request;
    if (!isPendingRequest(current)) return current;

    final next = applyChatRequestAction(current!, action);
    _chats = [..._chats];
    if (next == ChatRequestState.accepted) {
      // Accepting clears the flag; the conversation is an ordinary one now.
      _chats[index] = _chats[index].copyWith(request: null);
    } else {
      // Declining and blocking both leave the room, so the conversation goes.
      _chats.removeAt(index);
    }
    _controller.add(_chats);
    return next;
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
    await super.dispose();
  }
}
