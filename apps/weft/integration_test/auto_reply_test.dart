import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:path/path.dart' as p;
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'package:weft/data/matrix_chat_repository.dart';
import 'package:weft/services/ai/auto_reply_service.dart';
import 'package:weft/services/ai/auto_reply_writer.dart';

/// The auto-reply end-to-end pass, against the local Synapse from
/// `tooling/docker`.
///
///   docker compose -f tooling/docker/compose.yaml up -d --wait
///   ./tooling/docker/seed.sh
///   cd apps/weft && flutter test integration_test/*_test.dart -d macos
///
/// Written as a test rather than as a checklist, for the reason the Phase 08
/// backup pass was: a checklist is run once and a test is run every time.
///
/// What only a homeserver can answer is the whole point of the file. Every unit
/// test of this feature asserts against a fake whose unread bookkeeping is
/// modelled; this one sends a real event through a real room and reads the badge
/// back out of `MatrixChatRepository` after a real sync. The clause it is
/// checking — `isReadLocally` treating the account's own newest event as proof
/// the room was read — is reachable *only* that way, which is exactly how it
/// survived being written in the first place.
///
/// The model is a local HTTP server rather than an Ollama, because what is under
/// test is the send and the badge, not somebody's llama3. It speaks the same
/// OpenAI-compatible chat-completions shape `composeAutoReply` posts to and
/// answers instantly.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const homeserver = String.fromEnvironment(
    'WEFT_HOMESERVER',
    defaultValue: 'localhost:8008',
  );
  const password = String.fromEnvironment(
    'WEFT_TEST_PASSWORD',
    defaultValue: 'weft-test-password',
  );

  // Its own database file per session; see `matrix_session_test.dart` for why
  // `:memory:` cannot be used for two clients in one process.
  final tempRoot = Directory.systemTemp.createTempSync('weft-autoreply-it-');
  tearDownAll(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  var counter = 0;
  WeftMatrixSession newSession(String label) {
    final path = p.join(tempRoot.path, '$label-${counter++}.sqlite');
    return WeftMatrixSession(
      clientName: 'weft-autoreply-$label',
      deviceDisplayName: 'Weft auto-reply integration test',
      databaseOverride: () async => sdk.MatrixSdkDatabase.init(
        'weft-autoreply-$label',
        database: await openWeftSqfliteDatabase(path),
      ),
    );
  }

  test(
    'a rule answers Bob, and Alice still has an unread conversation',
    () async {
      final model = await _FakeModel.start('I am away until Monday.');
      addTearDown(model.close);

      final alice = newSession('alice');
      final bob = newSession('bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);

      await alice.initialize();
      await alice.checkHomeserver(homeserver);
      await alice.loginWithPassword(username: 'alice', password: password);

      await bob.initialize();
      await bob.checkHomeserver(homeserver);
      await bob.loginWithPassword(username: 'bob', password: password);

      // Bob opens the conversation, so it is his message that arrives rather
      // than Alice's invitation — a room Alice created has her own membership
      // event as its newest, which would make the "was it unread" question
      // vacuous.
      final roomId = await bob.client.createRoom(
        invite: ['@alice:localhost'],
        isDirect: true,
        preset: sdk.CreateRoomPreset.trustedPrivateChat,
      );
      final bobRoom = await _awaitRoom(bob.client, roomId);
      await alice.client.joinRoomById(roomId);
      await _awaitRoom(alice.client, roomId);

      final repository = MatrixChatRepository(alice);
      addTearDown(repository.dispose);
      final aliceRoomEarly = await _awaitRoom(alice.client, roomId);
      await _awaitChat(repository, roomId);

      // Alice writes and then opens the conversation, and neither is
      // scene-setting. Braid holds a first message from someone the user has
      // never answered as a *chat request*, and `shouldReply` refuses one
      // outright — correctly, and this test would then assert nothing. A
      // conversation Alice has spoken in and read is an ordinary one.
      await aliceRoomEarly.sendTextEvent('hello Bob');
      await _awaitMessage(await bobRoom.getTimeline(), 'hello Bob');
      await repository.markRead(roomId);
      await _settle(repository);

      // Where Alice's read marker stood before any of this. The auto-reply must
      // not move it — that is the receipt half of the guarantee, and with a
      // conversation she has genuinely read it is a sharper assertion than
      // "there is no receipt at all".
      final receiptBefore = alice.client
          .getRoomById(roomId)
          ?.receiptState
          .global
          .latestOwnReceipt
          ?.eventId;
      expect(
        receiptBefore,
        isNotNull,
        reason: 'opening the chat should have written one',
      );

      // Bob writes. Alice never opens the conversation again.
      await bobRoom.sendTextEvent('are you around this afternoon?');
      final incoming = await _awaitIncoming(
        alice,
        roomId,
        'are you around this afternoon?',
      );
      expect(incoming, isNotNull, reason: 'the message never reached Alice');

      final beforeReply = await _awaitUnread(repository, roomId);
      expect(
        beforeReply,
        greaterThan(0),
        reason: 'an unread message is the precondition for the whole test',
      );

      // The service, wired to the real repository and a model that answers.
      final chat = repository.chatForRoom(roomId)!;
      expect(
        chat.isPendingRequest,
        isFalse,
        reason: 'a request is refused outright, so this would assert nothing',
      );
      final attempts = <AutoReplyAttempt>[];
      final service = AutoReplyService(
        incoming: const Stream<WeftMessage>.empty(),
        transport: repository,
        chatForRoom: repository.chatForRoom,
        rules: () => const [
          AutoReplyRule(
            id: 'away',
            name: 'Away',
            prompt: 'Say I am away until Monday.',
            enabled: true,
          ),
        ],
        labelsOf: (_) => const {},
        isServiceChat: repository.serviceChatIds.contains,
        isBroadcast: (_) => false,
        ownUserIds: () => {alice.client.userID!},
        endpoint: () =>
            AutoReplyEndpoint(baseUrl: model.baseUrl, model: 'test-model'),
        onAttempt: attempts.add,
      );
      addTearDown(service.dispose);

      await service.handleMessage(incoming!);

      expect(
        attempts.single.outcome,
        AutoReplyOutcome.sent,
        reason: 'the attempt log says why, when it is not "sent"',
      );

      // Bob receives it, and it is marked as machine-written on the wire.
      final onBobsSide = await _awaitMessage(
        await bobRoom.getTimeline(),
        'I am away until Monday.',
      );
      expect(onBobsSide, isNotNull, reason: 'the reply never arrived');
      expect(
        onBobsSide!.content[kAutoReplyKey],
        isTrue,
        reason: 'the marker is what stops two Braids answering each other',
      );

      final mapped = mapEvent(
        onBobsSide,
        network: networkForRoom(bobRoom),
        ownUserId: bob.client.userID,
      );
      expect(mapped!.isAutoReply, isTrue);

      // And the point of the whole feature: Alice's conversation is still
      // waiting for her. Re-read after a sync, so this is the badge the inbox
      // would draw rather than a cached one.
      await alice.client.oneShotSync();
      await _settle(repository);

      final aliceRoom = alice.client.getRoomById(roomId)!;
      expect(
        aliceRoom.markedUnread,
        isTrue,
        reason: 'MSC2867 is what survives the send, and what syncs',
      );
      expect(
        repository.chatForRoom(roomId)!.unreadCount,
        greaterThan(0),
        reason: 'the badge the inbox row draws',
      );
      expect(
        aliceRoom.receiptState.global.latestOwnReceipt?.eventId,
        receiptBefore,
        reason:
            'the read marker did not move — Bob is not told his message was '
            'read, and Alice\'s own devices are not told either',
      );
      expect(
        repository.ownReadUpTo(chat.id).single.eventId,
        receiptBefore,
        reason: 'the repository agrees with the room state',
      );

      // The multi-device half: a second Alice session, which has only what the
      // homeserver told it, reaches the same answer.
      final laptop = newSession('alice-laptop');
      addTearDown(laptop.dispose);
      await laptop.initialize();
      await laptop.checkHomeserver(homeserver);
      await laptop.loginWithPassword(username: 'alice', password: password);
      final laptopRoom = await _awaitRoom(laptop.client, roomId);

      expect(
        laptopRoom.markedUnread,
        isTrue,
        reason: 'a local-only flag could not have reached this device',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

/// An OpenAI-compatible chat-completions endpoint that always answers [reply].
class _FakeModel {
  _FakeModel(this._server);

  final HttpServer _server;

  static Future<_FakeModel> start(String reply) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': reply},
                },
              ],
            }),
          );
        await request.response.close();
      }),
    );
    return _FakeModel(server);
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> close() => _server.close(force: true);
}

Future<sdk.Room> _awaitRoom(sdk.Client client, String roomId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final room = client.getRoomById(roomId);
    if (room != null) return room;
    await client.oneShotSync();
  }
  throw StateError('Room $roomId never arrived');
}

/// Waits for the repository's inbox fold to produce a chat for [roomId].
Future<Chat> _awaitChat(MatrixChatRepository repository, String roomId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final chat = repository.chatForRoom(roomId);
    if (chat != null) return chat;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('The inbox never folded $roomId into a chat');
}

/// The unread count once the repository has rebuilt, or zero if it never rises.
Future<int> _awaitUnread(MatrixChatRepository repository, String roomId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final count = repository.chatForRoom(roomId)?.unreadCount ?? 0;
    if (count > 0) return count;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return 0;
}

/// The `WeftMessage` for [body] as Alice's session sees it.
Future<WeftMessage?> _awaitIncoming(
  WeftMatrixSession session,
  String roomId,
  String body,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    final room = session.client.getRoomById(roomId);
    if (room != null) {
      final timeline = await room.getTimeline();
      for (final event in timeline.events) {
        if (event.type != sdk.EventTypes.Message || event.body != body) {
          continue;
        }
        final mapped = mapEvent(
          event,
          network: networkForRoom(room),
          ownUserId: session.client.userID,
          timeline: timeline,
        );
        if (mapped != null) return mapped;
      }
    }
    await session.client.oneShotSync();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return null;
}

Future<sdk.Event?> _awaitMessage(sdk.Timeline timeline, String body) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    for (final event in timeline.events) {
      if (event.type == sdk.EventTypes.Message && event.body == body) {
        return event;
      }
    }
    await timeline.room.client.oneShotSync();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return null;
}

/// Gives the repository's coalesced rebuild a chance to run.
///
/// It debounces at 300 ms, so reading a count in the frame after a send is
/// reading the one from before it.
Future<void> _settle(MatrixChatRepository repository) =>
    Future<void>.delayed(const Duration(milliseconds: 800));
