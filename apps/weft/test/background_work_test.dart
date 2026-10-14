import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/background/background_work.dart';
import 'package:weft_attachments/weft_attachments.dart';

/// Records what [BackgroundWork] asked the platform for.
class _FakeHost implements BackgroundWorkHost {
  final List<BackgroundWorkStatus?> calls = [];
  bool failNext = false;

  bool get showing => calls.isNotEmpty && calls.last != null;

  @override
  Future<void> show(BackgroundWorkStatus status) async {
    if (failNext) {
      failNext = false;
      throw StateError('foreground service refused');
    }
    calls.add(status);
  }

  @override
  Future<void> stop() async => calls.add(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHost host;
  late BackgroundWork work;

  setUp(() {
    host = _FakeHost();
    work = BackgroundWork(host: host);
  });

  UploadTask upload(String id, UploadState state, double progress) =>
      UploadTask(
        id: id,
        roomId: '!room:example.org',
        plan:
            planUpload(
                  AttachmentSource(
                    filename: '$id.jpg',
                    sizeBytes: 96000,
                    header: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]),
                  ),
                  encrypted: false,
                  maxUploadBytes: 0,
                )
                as UploadPlan,
        state: state,
        progress: progress,
      );

  test('a job shows a notification and takes it down when it ends', () async {
    final job = work.begin('Backing up your chats');
    job.update(fraction: 0.25);
    await work.idle;

    expect(host.showing, isTrue);
    expect(host.calls.last!.title, 'Backing up your chats');
    expect(host.calls.last!.percent, 25);

    job.end();
    await work.idle;
    expect(host.calls.last, isNull);
    expect(work.current, isNull);
  });

  test(
    'progress that does not move a whole percent is not re-posted',
    () async {
      final job = work.begin('Restoring a backup', fraction: 0);
      for (var i = 0; i < 100; i++) {
        job.update(fraction: 0.1 + i / 100000);
      }
      await work.idle;

      // Begin at 0%, then 10% once — not a hundred re-posts of the same bar.
      expect(host.calls.map((s) => s!.percent), [0, 10]);
    },
  );

  test('indeterminate progress has no percent', () async {
    final job = work.begin('Restoring a backup', fraction: 0.5);
    job.update(indeterminate: true);
    await work.idle;
    expect(host.calls.last!.fraction, isNull);
    expect(host.calls.last!.percent, isNull);
  });

  test(
    'the oldest job leads; the notification stays until the last one ends',
    () async {
      final backup = work.begin('Backing up your chats');
      final search = work.begin('Making messages searchable');
      await work.idle;
      expect(host.calls.last!.title, 'Backing up your chats');
      expect(host.calls.last!.others, 1);

      backup.end();
      await work.idle;
      expect(host.showing, isTrue);
      expect(host.calls.last!.title, 'Making messages searchable');
      expect(host.calls.last!.others, 0);

      search.end();
      await work.idle;
      expect(host.calls.last, isNull);
    },
  );

  test('run ends the job when the body throws', () async {
    await expectLater(
      work.run('Backing up your chats', (_) async => throw StateError('disk')),
      throwsStateError,
    );
    await work.idle;
    expect(work.current, isNull);
    expect(host.calls.last, isNull);
  });

  test(
    'ending a handle twice, or updating it after, changes nothing',
    () async {
      final first = work.begin('Backing up your chats');
      final second = work.begin('Restoring a backup');
      first.end();
      first.end();
      first.update(fraction: 0.9);
      await work.idle;
      expect(work.current!.title, 'Restoring a backup');
      second.end();
    },
  );

  test('a host that fails does not break the job', () async {
    host.failNext = true;
    final result = await work.run('Backing up your chats', (job) async {
      job.update(fraction: 0.5);
      return 'archive';
    });
    await work.idle;
    expect(result, 'archive');
    expect(host.calls.last, isNull);
  });

  test('without a host nothing is posted and jobs still run', () async {
    final bare = BackgroundWork();
    expect(await bare.run('Backing up your chats', (_) async => 7), 7);
    expect(bare.current, isNull);
  });

  group('uploads', () {
    test('one job while anything is unfinished, its bar the average', () async {
      work.reflectUploads([
        upload('a', UploadState.uploading, 0.5),
        upload('b', UploadState.queued, 0),
        upload('c', UploadState.sent, 1),
      ]);
      await work.idle;
      expect(host.calls.last!.title, 'Sending 2 attachments');
      expect(host.calls.last!.percent, 25);

      work.reflectUploads([
        upload('a', UploadState.sent, 1),
        upload('b', UploadState.uploading, 0.8),
        upload('c', UploadState.sent, 1),
      ]);
      await work.idle;
      expect(host.calls.last!.title, 'Sending 1 attachment');
      expect(host.calls.last!.percent, 80);
      expect(host.calls.last!.others, 0);
    });

    test('ends once every upload is sent, failed or cancelled', () async {
      work.reflectUploads([upload('a', UploadState.uploading, 0.1)]);
      await work.idle;
      expect(host.showing, isTrue);

      work.reflectUploads([
        upload('a', UploadState.failed, 0.1),
        upload('b', UploadState.cancelled, 0),
      ]);
      await work.idle;
      expect(host.calls.last, isNull);
    });

    test('an empty queue starts nothing', () async {
      work.reflectUploads(const []);
      await work.idle;
      expect(host.calls, isEmpty);
    });
  });

  group('IosBackgroundWorkHost', () {
    const channel = MethodChannel(IosBackgroundWorkHost.channelName);
    late List<MethodCall> log;

    setUp(() {
      log = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            log.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('begins once however often the status changes, then ends', () async {
      final ios = IosBackgroundWorkHost();
      await ios.show(const BackgroundWorkStatus(title: 'Backing up'));
      await ios.show(
        const BackgroundWorkStatus(title: 'Backing up', fraction: 1),
      );
      await ios.stop();
      await ios.stop();

      expect(log.map((c) => c.method), ['begin', 'end']);
      expect(log.first.arguments, {'name': 'Backing up'});
    });
  });
}
