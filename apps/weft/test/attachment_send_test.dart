import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

/// The send half of [ChatRepository], now that it moves bytes.
///
/// These replace the shape-only contract tests: the four members are exercised
/// through the demo repository, which runs the *real* [UploadQueue] over a fake
/// transport. What is asserted here — progress reaching the timeline, the
/// message appearing when the upload finishes, retry reviving a cancelled task,
/// a rejection never becoming a bubble — is therefore the same machinery the
/// Matrix path uses, with only the bytes pretended.
void main() {
  /// A JPEG header over a plausible size, which is what makes the plan an
  /// `m.image` with a thumbnail rather than an `m.file`.
  AttachmentSource photo({String name = 'holiday.jpg', int sizeBytes = 96000}) =>
      AttachmentSource(
        filename: name,
        sizeBytes: sizeBytes,
        header: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]),
      );

  /// Instant uploads: the tick exists so a human can see the progress bubble,
  /// and a test that waited it out would spend a real second per send.
  DemoChatRepository demo() => DemoChatRepository(uploadTick: Duration.zero);

  group('DemoChatRepository.sendAttachment', () {
    test('an upload is watchable from the moment it is accepted', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      final seen = <List<UploadTask>>[];
      final sub = repository
          .watchUploads('!design_room:example.org')
          .listen(seen.add);
      addTearDown(sub.cancel);

      await repository.sendAttachment('!design_room:example.org', photo());
      await pumpEventQueue();

      final states = [
        for (final snapshot in seen)
          if (snapshot.isNotEmpty) snapshot.single.state,
      ];
      // Queued through to sent, in that order, without ever going backwards.
      expect(states.first, UploadState.queued);
      expect(states, contains(UploadState.uploading));
      expect(states.last, UploadState.sent);
    });

    test('progress is reported before the upload finishes', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      final progress = <double>[];
      final sub = repository.watchUploads('!design_room:example.org').listen((
        tasks,
      ) {
        for (final task in tasks) {
          if (task.state == UploadState.uploading) progress.add(task.progress);
        }
      });
      addTearDown(sub.cancel);

      await repository.sendAttachment('!design_room:example.org', photo());
      await pumpEventQueue();

      // A bar that only ever shows 0% and then vanishes is the failure this
      // guards: the fake transport reports in steps for exactly that reason.
      expect(progress.where((p) => p > 0 && p < 1), isNotEmpty);
      expect(progress, isNot(contains(greaterThan(1.0))));
    });

    test('the finished upload becomes a message in the chat', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      await repository.sendAttachment('!design_room:example.org', photo());
      await pumpEventQueue();

      final chats = await repository.watchChats().first;
      final chat = chats.firstWhere((c) => c.id == '!design_room:example.org');
      final message = chat.lastMessage!;

      expect(message.kind, MessageKind.image);
      expect(message.body, 'holiday.jpg');
      expect(message.isOwn, isTrue);
      expect(message.deliveryState, DeliveryState.sent);
      // The flag the timeline reads to decide there is a file to load at all.
      expect(message.attachmentUrl, isNotNull);
    });

    test('the sent attachment is still in the thread on reopening', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      await repository.sendAttachment('!design_room:example.org', photo());
      await pumpEventQueue();

      final timeline = await repository.timelineFor('!design_room:example.org');
      await timeline.loadMore();

      expect(
        timeline.view().messages.map((m) => m.body),
        contains('holiday.jpg'),
        reason: 'a demo send that only updated the inbox preview would '
            'disappear the moment the user reopened the chat',
      );
    });

    test('the task is dropped once its message exists', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      await repository.sendAttachment('!design_room:example.org', photo());
      await pumpEventQueue();

      // Otherwise the timeline draws the settled bubble and the progress bubble
      // for the same photo, one above the other.
      expect(await repository.watchUploads('!design_room:example.org').first,
          isEmpty);
    });

    test('uploads are only watched by the chat they belong to', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      final other = <List<UploadTask>>[];
      final sub = repository
          .watchUploads('!emma_sg_room:example.org')
          .listen(other.add);
      addTearDown(sub.cancel);

      await repository.sendAttachment('!design_room:example.org', photo());
      await pumpEventQueue();

      expect(other.every((tasks) => tasks.isEmpty), isTrue);
    });

    test('a merged chat sends on the leg the network selector picked', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      await repository.sendAttachment(
        'merged:anna',
        photo(),
        via: ChatNetwork.telegram,
      );
      await pumpEventQueue();

      final chats = await repository.watchChats().first;
      final message = chats
          .firstWhere((c) => c.id == 'merged:anna')
          .lastMessage!;
      expect(message.network, ChatNetwork.telegram);
      expect(message.roomId, '!anna_tg_room:example.org');
    });

    test('a batch arrives in the order it was picked', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      for (final name in ['one.jpg', 'two.jpg', 'three.jpg']) {
        await repository.sendAttachment(
          '!design_room:example.org',
          photo(name: name),
        );
      }
      await pumpEventQueue();

      final timeline = await repository.timelineFor('!design_room:example.org');
      await timeline.loadMore();
      final sent = timeline.view().messages
          .where((m) => m.isOwn && m.kind == MessageKind.image)
          .map((m) => m.body)
          .toList();

      // Newest first in the timeline, so the reverse of the pick order. The
      // queue only promises uploads *start* in order; emitting the events in
      // order is the repository's job, and this is the assertion of it.
      expect(sent, ['three.jpg', 'two.jpg', 'one.jpg']);
    });

    test('an unknown chat is an error, not a silently dropped file', () {
      final repository = demo();
      addTearDown(repository.dispose);

      expect(
        () => repository.sendAttachment('!nowhere:example.org', photo()),
        throwsArgumentError,
      );
    });
  });

  group('rejections', () {
    test('an empty file is refused with a sentence, not a task', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      await expectLater(
        repository.sendAttachment(
          '!design_room:example.org',
          photo(sizeBytes: 0),
        ),
        throwsA(
          isA<AttachmentRejectedException>()
              .having((e) => e.reason, 'reason', UploadRejectionReason.empty)
              .having((e) => e.message, 'message', contains('empty')),
        ),
      );

      // A rejection is not something the user can retry, so it must not leave a
      // bubble behind that they could only dismiss.
      expect(
        await repository.watchUploads('!design_room:example.org').first,
        isEmpty,
      );
    });

    test('a file past the server limit is refused before any bytes move',
        () async {
      final repository = demo();
      addTearDown(repository.dispose);

      await expectLater(
        repository.sendAttachment(
          '!design_room:example.org',
          photo(sizeBytes: kDemoMaxUploadBytes + 1),
        ),
        throwsA(
          isA<AttachmentRejectedException>().having(
            (e) => e.reason,
            'reason',
            UploadRejectionReason.tooLarge,
          ),
        ),
      );
    });
  });

  group('cancel and retry', () {
    test('cancelling stops the upload and sends no message', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      await repository.sendAttachment('!design_room:example.org', photo());
      final task = (await repository
              .watchUploads('!design_room:example.org')
              .first)
          .single;

      await repository.cancelUpload(task.id);
      await pumpEventQueue();

      final tasks = await repository.watchUploads('!design_room:example.org')
          .first;
      expect(tasks.single.state, UploadState.cancelled);

      final chats = await repository.watchChats().first;
      final chat = chats.firstWhere((c) => c.id == '!design_room:example.org');
      expect(chat.lastMessage!.body, isNot('holiday.jpg'));
    });

    test('retrying a cancelled upload sends it after all', () async {
      final repository = demo();
      addTearDown(repository.dispose);

      await repository.sendAttachment('!design_room:example.org', photo());
      final task = (await repository
              .watchUploads('!design_room:example.org')
              .first)
          .single;
      await repository.cancelUpload(task.id);
      await pumpEventQueue();

      // The queue still holds the plan, which is what spares the user finding
      // the file a second time.
      await repository.retryUpload(task.id);
      await pumpEventQueue();

      final chats = await repository.watchChats().first;
      final chat = chats.firstWhere((c) => c.id == '!design_room:example.org');
      expect(chat.lastMessage!.body, 'holiday.jpg');
    });
  });

  group('sendSourceFor', () {
    final chat = Chat(
      id: 'merged:anna',
      title: 'Anna',
      sources: const [
        ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
        ChatSource(roomId: '!sg:example.org', network: ChatNetwork.signal),
      ],
    );

    test('an explicit choice wins', () {
      expect(
        sendSourceFor(chat, via: ChatNetwork.signal).roomId,
        '!sg:example.org',
      );
    });

    test('falls back to the first leg when the chosen one is gone', () {
      // Sending nowhere would be worse than sending on the other leg of a
      // conversation the user is already looking at.
      expect(
        sendSourceFor(chat, via: ChatNetwork.discord).roomId,
        '!wa:example.org',
      );
    });

    test('a chat with no rooms is a StateError, not a null', () {
      expect(
        () => sendSourceFor(
          const Chat(id: 'x', title: 'x', sources: []),
        ),
        throwsStateError,
      );
    });
  });

  group('dispatchableUploads', () {
    UploadTask task(
      String id, {
      required UploadState state,
      String roomId = '!room:example.org',
    }) {
      return UploadTask(
        id: id,
        roomId: roomId,
        plan: planUpload(
              photo(),
              encrypted: false,
              maxUploadBytes: 0,
            )
            as UploadPlan,
        state: state,
      );
    }

    test('sends the finished head of the queue in order', () {
      final ready = dispatchableUploads([
        task('a', state: UploadState.sent),
        task('b', state: UploadState.sent),
        task('c', state: UploadState.uploading),
      ]);
      expect(ready.map((t) => t.id), ['a', 'b']);
    });

    test('an upload still in flight holds back the ones behind it', () {
      // The whole point: two photos uploading at once finish in whatever order
      // the network decides, and the room must not show them shuffled.
      final ready = dispatchableUploads([
        task('a', state: UploadState.uploading),
        task('b', state: UploadState.sent),
      ]);
      expect(ready, isEmpty);
    });

    test('a failed or cancelled upload does not block the batch forever', () {
      final ready = dispatchableUploads([
        task('a', state: UploadState.failed),
        task('b', state: UploadState.cancelled),
        task('c', state: UploadState.sent),
      ]);
      expect(ready.map((t) => t.id), ['c']);
    });

    test('a blocked upload is skipped rather than retried in a loop', () {
      final ready = dispatchableUploads([
        task('a', state: UploadState.sent),
        task('b', state: UploadState.sent),
      ], blocked: {'a'});
      expect(ready.map((t) => t.id), ['b']);
    });
  });

  group('uploadEchoMessage', () {
    UploadTask pending(UploadState state) => UploadTask(
      id: 'upload-1',
      roomId: '!room:example.org',
      plan:
          planUpload(photo(), encrypted: false, maxUploadBytes: 0) as UploadPlan,
      state: state,
    );

    test('renders an in-flight upload as a sending message', () {
      final echo = uploadEchoMessage(
        pending(UploadState.uploading),
        network: ChatNetwork.matrix,
        senderId: '@me:example.org',
        timestamp: DateTime(2026, 8, 17, 12),
      );

      expect(echo.deliveryState, DeliveryState.sending);
      expect(echo.kind, MessageKind.image);
      expect(echo.body, 'holiday.jpg');
      expect(echo.isOwn, isTrue);
      // Synthetic, and unmistakably so: a real event id starts with `$`.
      expect(echo.eventId, 'local:upload-1');
      // There is no event to fetch bytes for yet.
      expect(echo.attachmentUrl, isNull);
    });

    test('a failed upload reads as a failed message', () {
      final echo = uploadEchoMessage(
        pending(UploadState.failed),
        network: ChatNetwork.matrix,
        senderId: '@me:example.org',
      );
      expect(echo.deliveryState, DeliveryState.failed);
    });
  });
}
