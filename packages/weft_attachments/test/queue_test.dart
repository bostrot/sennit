import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_attachments/weft_attachments.dart';

import 'support/fake_transport.dart';
import 'support/fixtures.dart';

/// Records what it was asked to wait for and returns immediately, so the
/// backoff schedule is asserted rather than endured.
class RecordingDelay {
  final List<Duration> waits = [];

  Future<void> call(Duration duration) async => waits.add(duration);
}

/// Lets the event loop run. Every transition in the queue is a microtask or
/// two; a handful of zero-duration turns drains all of them.
Future<void> pump([int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  const key = EncryptedFileInfo(
    key: 'k3y-mAt3r14l',
    iv: 'aXY0MgAAAAAA',
    sha256: 'c2hhMjU2LW9mLXRoZS1jaXBoZXJ0ZXh0',
  );

  UploadPlan planFor({
    String filename = 'photo.png',
    int sizeBytes = 200 * 1024,
    bool encrypted = false,
  }) {
    final decision = planUpload(
      AttachmentSource(
        filename: filename,
        sizeBytes: sizeBytes,
        header: Uint8List.fromList(png(width: 1600, height: 900)),
      ),
      encrypted: encrypted,
      maxUploadBytes: 100 * 1024 * 1024,
    );
    return decision as UploadPlan;
  }

  UploadPayloadLoader payload({
    List<int> bytes = const [1, 2, 3, 4],
    EncryptedFileInfo? file,
  }) {
    return () async => UploadPayload(bytes: bytes, file: file);
  }

  group('defaultUploadBackoff', () {
    test('quadruples: 1s, 4s, 16s', () {
      expect(defaultUploadBackoff(1), const Duration(seconds: 1));
      expect(defaultUploadBackoff(2), const Duration(seconds: 4));
      expect(defaultUploadBackoff(3), const Duration(seconds: 16));
    });

    test('is total for nonsense attempt numbers', () {
      expect(defaultUploadBackoff(0), kUploadBackoffBase);
      expect(defaultUploadBackoff(-5), kUploadBackoffBase);
      // Clamped rather than overflowed.
      expect(defaultUploadBackoff(400).inSeconds, greaterThan(0));
    });
  });

  group('UploadState', () {
    test('terminal states are the three that need a new instruction', () {
      final terminal = UploadState.values.where((s) => s.isTerminal).toSet();
      expect(terminal, {
        UploadState.sent,
        UploadState.failed,
        UploadState.cancelled,
      });
    });

    test('a backing-off task holds no concurrency slot', () {
      expect(UploadState.retrying.isActive, isFalse);
      expect(UploadState.hashing.isActive, isTrue);
      expect(UploadState.uploading.isActive, isTrue);
      expect(UploadState.queued.isActive, isFalse);
    });
  });

  group('a successful upload', () {
    test('walks queued -> hashing -> uploading -> sent', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(transport: transport);
      addTearDown(queue.dispose);

      final states = <UploadState>[];
      final sub = queue.updates.listen((snapshot) {
        states.add(snapshot.single.state);
      });
      addTearDown(sub.cancel);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      expect(task.state, UploadState.queued);

      await pump();
      expect(transport.calls, hasLength(1));
      expect(transport.last.mimeType, 'image/png');
      expect(transport.last.uploadId, task.id);
      expect(queue.task(task.id)!.state, UploadState.uploading);

      transport.last.succeed('mxc://example.org/abc');
      await pump();

      final done = queue.task(task.id)!;
      expect(done.state, UploadState.sent);
      expect(done.uri, 'mxc://example.org/abc');
      expect(done.progress, 1.0);
      expect(done.attempts, 1);
      expect(done.failure, isNull);

      // One distinct snapshot per transition, in order.
      expect(states, [
        UploadState.queued,
        UploadState.hashing,
        UploadState.uploading,
        UploadState.sent,
      ]);
    });

    test('carries the key material through to the event content', () async {
      final transport = FakeTransport(autoComplete: true);
      final queue = UploadQueue(transport: transport);
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(encrypted: true),
        roomId: '!room:example.org',
        loadPayload: payload(file: key),
      );
      await pump();

      final sent = queue.task(task.id)!;
      expect(sent.state, UploadState.sent);
      expect(sent.file, key);

      final content = sent.plan.toEventContent(uri: sent.uri!, file: sent.file);
      // The encrypted shape: no top-level url, the URI inside the file block.
      expect(content['url'], isNull);
      expect((content['file']! as Map)['url'], sent.uri);
    });
  });

  group('ordering and concurrency', () {
    test('starts tasks in the order they were enqueued', () async {
      final transport = FakeTransport(autoComplete: true);
      final queue = UploadQueue(transport: transport, maxConcurrent: 1);
      addTearDown(queue.dispose);

      final ids = [
        for (var i = 0; i < 5; i++)
          queue
              .enqueue(
                planFor(filename: 'photo-$i.png'),
                roomId: '!room:example.org',
                loadPayload: payload(),
              )
              .id,
      ];

      await pump(20);
      expect(transport.startOrder, ids);
      expect(queue.tasks.map((t) => t.state), everyElement(UploadState.sent));
    });

    test('keeps each chat FIFO when two chats interleave', () async {
      final transport = FakeTransport(autoComplete: true);
      final queue = UploadQueue(transport: transport, maxConcurrent: 2);
      addTearDown(queue.dispose);

      final rooms = ['!a:example.org', '!b:example.org'];
      for (var i = 0; i < 6; i++) {
        queue.enqueue(
          planFor(filename: 'photo-$i.png'),
          roomId: rooms[i.isEven ? 0 : 1],
          id: 'task-$i',
          loadPayload: payload(),
        );
      }

      await pump(20);
      expect(
        transport.startOrder.where((id) => int.parse(id.split('-')[1]).isEven),
        ['task-0', 'task-2', 'task-4'],
      );
      expect(queue.tasksFor(rooms[0]).map((t) => t.id), [
        'task-0',
        'task-2',
        'task-4',
      ]);
    });

    test('never exceeds the concurrency cap', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(transport: transport, maxConcurrent: 2);
      addTearDown(queue.dispose);

      final ids = [
        for (var i = 0; i < 6; i++)
          queue
              .enqueue(
                planFor(filename: 'photo-$i.png'),
                roomId: '!room:example.org',
                loadPayload: payload(),
              )
              .id,
      ];

      await pump();
      expect(transport.calls, hasLength(2));
      expect(transport.peakConcurrency, 2);
      expect(queue.task(ids[2])!.state, UploadState.queued);

      // A slot frees up, and the oldest waiting task takes it.
      transport.calls[0].succeed();
      await pump();
      expect(transport.calls, hasLength(3));
      expect(transport.startOrder.last, ids[2]);
      expect(transport.peakConcurrency, 2);
    });

    test('defaults to two at a time', () {
      expect(kDefaultMaxConcurrentUploads, 2);
      final queue = UploadQueue(transport: FakeTransport());
      expect(queue.maxConcurrent, kDefaultMaxConcurrentUploads);
      expect(queue.maxAttempts, kMaxUploadAttempts);
    });
  });

  group('retry and backoff', () {
    test('tries three times, waiting 1s then 4s, then fails', () async {
      final transport = FakeTransport();
      final delay = RecordingDelay();
      final queue = UploadQueue(transport: transport, delay: delay.call);
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );

      await pump();
      transport.last.fail('The server is having a moment');
      await pump();
      expect(transport.callsFor(task.id), 2);
      expect(queue.task(task.id)!.attempts, 2);

      transport.last.fail('The server is having a moment');
      await pump();
      expect(transport.callsFor(task.id), 3);

      transport.last.fail('The server is having a moment');
      await pump();

      final failed = queue.task(task.id)!;
      expect(failed.state, UploadState.failed);
      expect(failed.attempts, 3);
      expect(failed.failure, 'The server is having a moment');
      expect(transport.callsFor(task.id), 3);
      expect(delay.waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 4),
      ]);
    });

    test('does not spend retries on a failure that cannot succeed', () async {
      final transport = FakeTransport();
      final delay = RecordingDelay();
      final queue = UploadQueue(transport: transport, delay: delay.call);
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();
      transport.last.fail(
        'That file is too large for this server',
        retryable: false,
      );
      await pump();

      final failed = queue.task(task.id)!;
      expect(failed.state, UploadState.failed);
      expect(failed.attempts, 1);
      expect(failed.failure, 'That file is too large for this server');
      expect(transport.calls, hasLength(1));
      expect(delay.waits, isEmpty);
    });

    test('treats an undeclared exception as transient', () async {
      final transport = FakeTransport();
      final delay = RecordingDelay();
      final queue = UploadQueue(transport: transport, delay: delay.call);
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );

      for (var i = 0; i < 3; i++) {
        await pump();
        transport.last.throwRaw(StateError('socket went away'));
      }
      await pump();

      expect(queue.task(task.id)!.state, UploadState.failed);
      expect(queue.task(task.id)!.failure, contains('socket went away'));
      expect(transport.calls, hasLength(3));
    });

    test('a failing payload counts as an attempt and is retried', () async {
      final transport = FakeTransport(autoComplete: true);
      final delay = RecordingDelay();
      final queue = UploadQueue(transport: transport, delay: delay.call);
      addTearDown(queue.dispose);

      var loads = 0;
      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: () async {
          loads++;
          if (loads == 1) throw StateError('the file moved');
          return const UploadPayload(bytes: [1, 2, 3]);
        },
      );

      await pump(20);
      expect(loads, 2);
      expect(queue.task(task.id)!.state, UploadState.sent);
      expect(queue.task(task.id)!.attempts, 2);
      expect(delay.waits, [const Duration(seconds: 1)]);
    });

    test(
      'a backing-off task frees its slot for the rest of the share',
      () async {
        final transport = FakeTransport();
        final blocked = Completer<void>();
        final queue = UploadQueue(
          transport: transport,
          maxConcurrent: 1,
          delay: (_) => blocked.future,
        );
        addTearDown(queue.dispose);

        final first = queue.enqueue(
          planFor(filename: 'first.png'),
          roomId: '!room:example.org',
          loadPayload: payload(),
        );
        final second = queue.enqueue(
          planFor(filename: 'second.png'),
          roomId: '!room:example.org',
          loadPayload: payload(),
        );

        await pump();
        expect(transport.startOrder, [first.id]);

        transport.last.fail('A blip');
        await pump();

        // The first is still waiting out its backoff, and the second is on the
        // wire rather than stuck behind it.
        expect(queue.task(first.id)!.state, UploadState.retrying);
        expect(transport.startOrder, [first.id, second.id]);
        blocked.complete();
      },
    );
  });

  group('cancel', () {
    test('stops an in-flight upload and ignores its late success', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(transport: transport);
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();
      expect(queue.task(task.id)!.state, UploadState.uploading);

      expect(queue.cancel(task.id), isTrue);
      expect(queue.task(task.id)!.state, UploadState.cancelled);
      expect(transport.cancelled, [task.id]);

      // The socket had already finished by the time the user pressed cancel.
      transport.last.succeed();
      await pump();
      expect(queue.task(task.id)!.state, UploadState.cancelled);
      expect(queue.task(task.id)!.uri, isNull);
    });

    test('stops a queued task before it ever reaches the transport', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(transport: transport, maxConcurrent: 1);
      addTearDown(queue.dispose);

      final first = queue.enqueue(
        planFor(filename: 'first.png'),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      final second = queue.enqueue(
        planFor(filename: 'second.png'),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );

      await pump();
      expect(queue.cancel(second.id), isTrue);

      transport.calls.single.succeed();
      await pump();

      expect(queue.task(first.id)!.state, UploadState.sent);
      expect(queue.task(second.id)!.state, UploadState.cancelled);
      expect(transport.startOrder, [first.id]);
    });

    test('stops a task that is waiting out a backoff', () async {
      final transport = FakeTransport();
      final blocked = Completer<void>();
      final queue = UploadQueue(
        transport: transport,
        delay: (_) => blocked.future,
      );
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();
      transport.last.fail('A blip');
      await pump();
      expect(queue.task(task.id)!.state, UploadState.retrying);

      expect(queue.cancel(task.id), isTrue);
      blocked.complete();
      await pump();

      expect(queue.task(task.id)!.state, UploadState.cancelled);
      expect(transport.calls, hasLength(1));
    });

    test('is a no-op for an unknown or finished task', () async {
      final transport = FakeTransport(autoComplete: true);
      final queue = UploadQueue(transport: transport);
      addTearDown(queue.dispose);

      expect(queue.cancel('nobody'), isFalse);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();
      expect(queue.task(task.id)!.state, UploadState.sent);
      expect(queue.cancel(task.id), isFalse);
    });
  });

  group('a failed task', () {
    test('stays in the queue with its plan intact', () async {
      final transport = FakeTransport();
      final delay = RecordingDelay();
      final queue = UploadQueue(
        transport: transport,
        maxAttempts: 1,
        delay: delay.call,
      );
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(filename: 'holiday.png'),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();
      transport.last.fail('The server is having a moment');
      await pump();

      final failed = queue.task(task.id)!;
      expect(failed.state, UploadState.failed);
      expect(failed.canRetry, isTrue);
      expect(failed.plan.filename, 'holiday.png');
      expect(failed.plan.msgtype, 'm.image');
      expect(queue.tasks, hasLength(1));
    });

    test('can be retried by hand with a fresh attempt budget', () async {
      final transport = FakeTransport();
      final delay = RecordingDelay();
      final queue = UploadQueue(
        transport: transport,
        maxAttempts: 1,
        delay: delay.call,
      );
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();
      transport.last.fail('The server is having a moment');
      await pump();
      expect(queue.task(task.id)!.state, UploadState.failed);

      expect(queue.retry(task.id), isTrue);
      await pump();
      transport.last.succeed();
      await pump();

      final sent = queue.task(task.id)!;
      expect(sent.state, UploadState.sent);
      expect(sent.attempts, 1);
      expect(sent.failure, isNull);
      expect(transport.callsFor(task.id), 2);
    });

    test('cannot be retried while it is still running', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(transport: transport);
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();
      expect(queue.retry(task.id), isFalse);
      expect(queue.retry('nobody'), isFalse);
    });
  });

  group('progress', () {
    test('is reported as a fraction and emitted as a new snapshot', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(transport: transport);
      addTearDown(queue.dispose);

      final seen = <double>[];
      final sub = queue.updates.listen((snapshot) {
        if (snapshot.single.state == UploadState.uploading) {
          seen.add(snapshot.single.progress);
        }
      });
      addTearDown(sub.cancel);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();

      transport.last.report(50, 100);
      await pump();
      expect(queue.task(task.id)!.progress, 0.5);

      // Nothing has changed, so nothing is emitted.
      transport.last.report(50, 100);
      // A transport that cannot count tells us nothing; the bar stays put.
      transport.last.report(10, 0);
      await pump();
      expect(queue.task(task.id)!.progress, 0.5);

      transport.last.report(100, 100);
      await pump();
      expect(seen, [0.0, 0.5, 1.0]);
    });

    test('ignores progress for a task that is no longer uploading', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(transport: transport);
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();
      queue.cancel(task.id);
      transport.last.report(50, 100);
      await pump();

      expect(queue.task(task.id)!.progress, 0.0);
      expect(queue.task(task.id)!.state, UploadState.cancelled);
    });
  });

  group('queue housekeeping', () {
    test('rejects a duplicate id rather than shadowing a task', () {
      final queue = UploadQueue(transport: FakeTransport());
      addTearDown(queue.dispose);

      queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        id: 'task-1',
        loadPayload: payload(),
      );
      expect(
        () => queue.enqueue(
          planFor(),
          roomId: '!room:example.org',
          id: 'task-1',
          loadPayload: payload(),
        ),
        throwsArgumentError,
      );
    });

    test('remove takes finished tasks only', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(transport: transport);
      addTearDown(queue.dispose);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();
      expect(queue.remove(task.id), isFalse);

      transport.last.succeed();
      await pump();
      expect(queue.remove(task.id), isTrue);
      expect(queue.tasks, isEmpty);
      expect(queue.task(task.id), isNull);
    });

    test('clearFinished keeps failures, which still need a decision', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(
        transport: transport,
        maxAttempts: 1,
        maxConcurrent: 3,
      );
      addTearDown(queue.dispose);

      final sent = queue.enqueue(
        planFor(filename: 'sent.png'),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      final failed = queue.enqueue(
        planFor(filename: 'failed.png'),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      final cancelled = queue.enqueue(
        planFor(filename: 'cancelled.png'),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );

      await pump();
      transport.calls[0].succeed();
      transport.calls[1].fail('The server is having a moment');
      queue.cancel(cancelled.id);
      await pump();

      queue.clearFinished();
      expect(queue.tasks.map((t) => t.id), [failed.id]);
      expect(queue.task(sent.id), isNull);
      expect(queue.task(cancelled.id), isNull);
    });

    test('dispose cancels what is outstanding and closes the stream', () async {
      final transport = FakeTransport();
      final queue = UploadQueue(transport: transport);

      final closed = Completer<void>();
      final sub = queue.updates.listen(null, onDone: closed.complete);
      addTearDown(sub.cancel);

      final task = queue.enqueue(
        planFor(),
        roomId: '!room:example.org',
        loadPayload: payload(),
      );
      await pump();

      await queue.dispose();
      await closed.future;

      expect(queue.task(task.id)!.state, UploadState.cancelled);
      expect(transport.cancelled, [task.id]);
      // The transport was injected, so the queue does not own its lifetime.
      expect(transport.disposeCount, 0);
      expect(
        () => queue.enqueue(
          planFor(),
          roomId: '!room:example.org',
          loadPayload: payload(),
        ),
        throwsStateError,
      );
    });
  });

  group('UploadTask', () {
    test('copyWith leaves untouched fields alone', () {
      final task = UploadTask(
        id: 'task-1',
        roomId: '!room:example.org',
        plan: planFor(),
      );
      final moved = task.copyWith(state: UploadState.uploading, progress: 0.25);

      expect(moved.id, task.id);
      expect(moved.plan, same(task.plan));
      expect(moved.state, UploadState.uploading);
      expect(moved.progress, 0.25);
      expect(moved.attempts, 0);
    });

    test('equality covers everything that changes under an id', () {
      final plan = planFor();
      final a = UploadTask(id: 'x', roomId: '!r:example.org', plan: plan);
      final b = UploadTask(id: 'x', roomId: '!r:example.org', plan: plan);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(a.copyWith(state: UploadState.uploading)));
      expect(a, isNot(a.copyWith(progress: 0.5)));
    });
  });
}
