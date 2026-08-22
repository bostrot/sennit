import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:weft/app/providers.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/attachment_bubble.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/media_viewer.dart';
import 'package:weft/services/attachments/media_exporter.dart';
import 'package:weft/services/attachments/media_store.dart';
import 'package:weft/services/attachments/video_surface.dart';
import 'package:weft/services/models/model_transport.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/attachment_fixtures.dart';
import 'support/semantics_probe.dart';

/// Records what it was asked to fetch and writes fixture bytes at the target.
class _FakeTransport implements ModelDownloadTransport {
  Uri? url;
  Map<String, String>? headers;
  File? target;
  int calls = 0;

  @override
  Future<void> download({
    required Uri url,
    required File target,
    required int expectedBytes,
    required String displayName,
    Map<String, String> headers = const {},
    void Function(int totalOnDisk)? onBytes,
    Future<bool> Function()? shouldContinue,
  }) async {
    calls++;
    this.url = url;
    this.headers = headers;
    this.target = target;
    await target.writeAsBytes(kPixel);
  }

  @override
  void dispose() {}
}

/// A store that hands back a file already on disk, with no I/O of its own.
///
/// Real staging awaits a real read, and a `testWidgets` body runs in a fake-async
/// zone where a real read never completes — the widget would sit on its spinner
/// for the whole test. [stageAttachment] is covered by the plain `test`s below,
/// where awaiting the disk works.
class _FakeStore implements MediaFileStore {
  _FakeStore(this.file, {this.failure, this.gate});

  final File? file;
  final String? failure;

  /// Held open to stand in for a download still on the wire.
  final Future<void>? gate;
  int calls = 0;

  @override
  Future<File> stage(
    WeftMessage message, {
    required ChatRepository repository,
    void Function(int received)? onBytes,
    Future<bool> Function()? shouldContinue,
  }) async {
    calls++;
    final gate = this.gate;
    if (gate != null) await gate;
    final failure = this.failure;
    if (failure != null) throw MediaUnavailableException(failure);
    return file!;
  }

  @override
  void dispose() {}
}

class _FakeExporter implements MediaExporter {
  _FakeExporter({this.canSave = true, this.savedPath = '/tmp/out.jpg'});

  @override
  final bool canSave;

  final String? savedPath;

  String? suggestedName;
  String? savedMimeType;
  String? sharedMimeType;
  Rect? sharedOrigin;
  int shares = 0;

  @override
  Future<String?> save(File file, {required String suggestedName}) async {
    this.suggestedName = suggestedName;
    savedMimeType = stagedMimeType(file);
    return savedPath;
  }

  @override
  Future<void> share(
    File file, {
    String? mimeType,
    String? text,
    Rect? origin,
  }) async {
    shares++;
    sharedMimeType = mimeType;
    sharedOrigin = origin;
  }
}

void main() {
  const roomId = '!room:example.org';

  WeftMessage media({
    required MessageKind kind,
    String eventId = '\$one',
    String body = 'holiday.jpg',
    String? attachmentUrl = 'mxc://example.org/abc',
    bool isOwn = false,
    int? sizeBytes,
    DateTime? timestamp,
  }) => WeftMessage(
    eventId: eventId,
    roomId: roomId,
    network: ChatNetwork.matrix,
    senderId: '@anna:example.org',
    senderName: 'Anna Maven',
    timestamp: timestamp ?? DateTime(2026, 3, 4, 9, 30),
    kind: kind,
    isOwn: isOwn,
    body: body,
    attachmentUrl: attachmentUrl,
    mediaSizeBytes: sizeBytes,
  );

  group('attachmentFileName', () {
    test('adopts a body that is a filename', () {
      expect(attachmentFileName(media(kind: MessageKind.image)), 'holiday.jpg');
    });

    // The failure this exists to prevent: a bridge's "Forwarded" or a real
    // caption becoming the name of a file in the user's Downloads folder.
    test('never lets a caption become a filename', () {
      final name = attachmentFileName(
        media(kind: MessageKind.image, body: 'from the beach'),
        mimeType: 'image/jpeg',
      );
      expect(name, isNot(contains('beach')));
      expect(name, endsWith('.jpg'));
    });

    test(
      'derives the extension from the sniffed type when there is no name',
      () {
        expect(
          attachmentFileName(
            media(kind: MessageKind.video, body: '', eventId: r'$clip'),
            mimeType: 'video/mp4',
          ),
          'weft-_clip.mp4',
        );
      },
    );

    test('leaves the extension off rather than inventing one', () {
      expect(
        attachmentFileName(
          media(kind: MessageKind.file, body: 'Forwarded'),
          mimeType: 'application/octet-stream',
        ),
        isNot(contains('.')),
      );
    });

    // A body is attacker-controlled: it arrives from whatever client sent the
    // event, and it decides a path here.
    test('a body cannot escape the directory it is written into', () {
      final name = attachmentFileName(
        media(kind: MessageKind.file, body: '../../secrets.env'),
      );
      expect(name, 'secrets.env');
      expect(name, isNot(contains('/')));
      expect(p.isAbsolute(name), isFalse);
    });

    test(
      'an event id with matrix punctuation still makes a path component',
      () {
        final name = attachmentFileName(
          media(
            kind: MessageKind.image,
            eventId: r'$aB/c:example.org',
            body: '',
          ),
        );
        expect(name, isNot(contains('/')));
        expect(name, isNot(contains(':')));
      },
    );
  });

  group('stageAttachment', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('weft_media_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    // The unencrypted branch: a URL exists, so the bytes stream to disk through
    // the download service and never pass through this isolate whole.
    test(
      'a plain attachment goes through the transport, with its headers',
      () async {
        final repository = StubChatRepository(
          location: AttachmentLocation(
            url: Uri.parse('https://hs.example.org/_matrix/client/v1/media/x'),
            headers: const {'authorization': 'Bearer tok'},
          ),
        );
        final transport = _FakeTransport();

        final file = await stageAttachment(
          media(kind: MessageKind.image),
          repository: repository,
          transport: transport,
          directory: dir,
        );

        expect(transport.calls, 1);
        expect(transport.url.toString(), contains('/media/x'));
        expect(transport.headers, {'authorization': 'Bearer tok'});
        expect(repository.byteCalls, 0, reason: 'no need to decrypt anything');
        expect(file.readAsBytesSync(), kPixel);
        expect(p.basename(file.path), 'holiday.jpg');
      },
    );

    // The encrypted branch, and the reason the fork exists: ciphertext behind an
    // mxc URI is not the file, so there is no URL to give the transport.
    test('an encrypted attachment is decrypted rather than fetched', () async {
      final repository = StubChatRepository(bytes: kPixel);
      final transport = _FakeTransport();

      final file = await stageAttachment(
        media(kind: MessageKind.image),
        repository: repository,
        transport: transport,
        directory: dir,
      );

      expect(transport.calls, 0);
      expect(repository.byteCalls, 1);
      expect(file.readAsBytesSync(), kPixel);
    });

    // Saving a 96-pixel crop of the photo the user asked for would look like it
    // had worked.
    test('the decrypted copy is the original, not the thumbnail', () async {
      var askedForThumbnail = true;
      final repository = _RecordingBytesRepository((thumbnail) {
        askedForThumbnail = thumbnail;
        return kPixel;
      });

      await stageAttachment(
        media(kind: MessageKind.image),
        repository: repository,
        transport: _FakeTransport(),
        directory: dir,
      );

      expect(askedForThumbnail, isFalse);
    });

    test('the second call reuses the staged file', () async {
      final repository = StubChatRepository(bytes: kPixel);
      final transport = _FakeTransport();
      final message = media(kind: MessageKind.image);

      final first = await stageAttachment(
        message,
        repository: repository,
        transport: transport,
        directory: dir,
      );
      final second = await stageAttachment(
        message,
        repository: repository,
        transport: transport,
        directory: dir,
      );

      expect(second.path, first.path);
      expect(repository.byteCalls, 1, reason: 'Share after Save is free');
    });

    // Two senders both send `image.jpg`; a flat staging folder would serve the
    // first one's photo for the second one's bubble.
    test('two events with the same filename do not collide', () async {
      final repository = StubChatRepository(bytes: kPixel);
      final one = await stageAttachment(
        media(kind: MessageKind.image, eventId: r'$one'),
        repository: repository,
        transport: _FakeTransport(),
        directory: dir,
      );
      final two = await stageAttachment(
        media(kind: MessageKind.image, eventId: r'$two'),
        repository: repository,
        transport: _FakeTransport(),
        directory: dir,
      );

      expect(p.basename(one.path), p.basename(two.path));
      expect(one.path, isNot(two.path));
    });

    // A half file left behind by a cancelled save would otherwise be handed on
    // by every later Share as though it were the whole thing.
    test('a download in progress is not mistaken for a finished one', () async {
      final repository = StubChatRepository(
        location: AttachmentLocation(url: Uri.parse('https://hs/x')),
      );
      final transport = _FakeTransport();

      final file = await stageAttachment(
        media(kind: MessageKind.image),
        repository: repository,
        transport: transport,
        directory: dir,
      );

      expect(transport.target!.path, endsWith('.part'));
      expect(transport.target!.existsSync(), isFalse);
      expect(file.path, isNot(endsWith('.part')));
      expect(file.existsSync(), isTrue);
    });

    test('an attachment with no bytes says so rather than writing nothing', () {
      expect(
        () => stageAttachment(
          media(kind: MessageKind.image),
          repository: StubChatRepository(),
          transport: _FakeTransport(),
          directory: dir,
        ),
        throwsA(isA<MediaUnavailableException>()),
      );
    });
  });

  group('the gallery', () {
    test('is the conversation\'s media, oldest first', () {
      // As the timeline holds it: newest first.
      final messages = [
        media(kind: MessageKind.video, eventId: r'$c'),
        media(kind: MessageKind.text, eventId: r'$b', attachmentUrl: null),
        media(kind: MessageKind.image, eventId: r'$a'),
      ];

      expect(viewableMedia(messages).map((m) => m.eventId), [r'$a', r'$c']);
    });

    // A swipe from a photograph to a spreadsheet is not a gesture anyone means
    // to make, so files and audio are not in the roll — they still open, alone.
    test('leaves out the kinds there is no picture of', () {
      final messages = [
        media(kind: MessageKind.file, eventId: r'$pdf', body: 'report.pdf'),
        media(kind: MessageKind.audio, eventId: r'$song', body: 'song.mp3'),
        media(kind: MessageKind.sticker, eventId: r'$sticker'),
      ];

      expect(viewableMedia(messages).map((m) => m.eventId), [r'$sticker']);
    });

    test('a hero tag names both the room and the event', () {
      final tag = mediaHeroTag(media(kind: MessageKind.image));
      expect(tag, contains(roomId));
      expect(tag, contains(r'$one'));
      expect(
        mediaHeroTag(media(kind: MessageKind.image, eventId: r'$two')),
        isNot(tag),
      );
    });
  });

  group('MediaViewer', () {
    late Directory dir;
    late File staged;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('weft_viewer_test');
      staged = File(p.join(dir.path, 'holiday.jpg'))..writeAsBytesSync(kPixel);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> pumpViewer(
      WidgetTester tester, {
      required List<WeftMessage> items,
      int initialIndex = 0,
      MediaFileStore? store,
      MediaExporter? exporter,
      ChatRepository? repository,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(
              repository ?? StubChatRepository(bytes: kPixel),
            ),
            mediaFileStoreProvider.overrideWithValue(
              store ?? _FakeStore(staged),
            ),
            mediaExporterProvider.overrideWithValue(
              exporter ?? _FakeExporter(),
            ),
            // `video_player` is a method channel; the stub is the whole reason
            // a video page can be built under `flutter test` at all.
            videoSurfaceProvider.overrideWithValue(
              (context, file) => Text('video:${p.basename(file.path)}'),
            ),
          ],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: MediaViewer(items: items, initialIndex: initialIndex),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('names the sender and when they sent it', (tester) async {
      await pumpViewer(tester, items: [media(kind: MessageKind.image)]);

      expect(find.text('Anna Maven'), findsOneWidget);
      expect(find.textContaining('Mar 4, 2026'), findsOneWidget);
    });

    testWidgets('an own attachment is attributed to you', (tester) async {
      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.image, isOwn: true)],
      );

      expect(find.text('You'), findsOneWidget);
    });

    // The same rule the bubble uses, read the same way round: a filename body is
    // not a caption and must not be printed over the picture.
    testWidgets('shows a caption but not a filename', (tester) async {
      await pumpViewer(tester, items: [media(kind: MessageKind.image)]);
      expect(find.text('holiday.jpg'), findsNothing);

      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.image, body: 'from the beach')],
      );
      expect(find.text('from the beach'), findsOneWidget);
    });

    testWidgets('an image can be pinched and panned', (tester) async {
      await pumpViewer(tester, items: [media(kind: MessageKind.image)]);
      await tester.pump();

      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.maxScale, greaterThan(1));
      expect(find.byType(Hero), findsWidgets);
    });

    testWidgets('a video plays inline once its bytes are down', (tester) async {
      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.video, body: 'clip.mp4')],
      );
      await tester.pump();

      expect(find.text('video:holiday.jpg'), findsOneWidget);
    });

    // The viewer is also where Save and Share live for a file, so it opens for
    // one — it just does not pretend to render it. (A PDF is the exception:
    // it gets a reader, so this placeholder is for everything else.)
    testWidgets('a file shows its name and size instead of a picture', (
      tester,
    ) async {
      await pumpViewer(
        tester,
        items: [
          media(kind: MessageKind.file, body: 'report.zip', sizeBytes: 96000),
        ],
      );

      expect(find.text('report.zip'), findsOneWidget);
      expect(find.text('94 kB'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('a PDF waits for its bytes instead of showing the '
        'placeholder', (tester) async {
      await pumpViewer(
        tester,
        items: [
          media(kind: MessageKind.file, body: 'report.pdf', sizeBytes: 96000),
        ],
      );

      // The file never stages in a test, so the reader sits at its loading
      // (or, depending on how the fake store failed, its error) state — the
      // point is that the name-and-size placeholder is gone.
      expect(find.text('report.pdf'), findsNothing);
      expect(find.text('94 kB'), findsNothing);
    });

    testWidgets('saving offers the name the file should have', (tester) async {
      final exporter = _FakeExporter();
      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.image)],
        exporter: exporter,
      );

      await tester.tap(find.byTooltip('Save'));
      await tester.pump();

      expect(exporter.suggestedName, 'holiday.jpg');
      // Sniffed from the staged bytes rather than trusted from the name: the
      // fixture is a PNG whatever the event called it.
      expect(exporter.savedMimeType, 'image/png');
      await tester.pump();
      expect(find.textContaining('Saved to'), findsOneWidget);
    });

    testWidgets('sharing announces what the file actually is', (tester) async {
      final exporter = _FakeExporter();
      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.image)],
        exporter: exporter,
      );

      await tester.tap(find.byTooltip('Share'));
      await tester.pump();

      expect(exporter.shares, 1);
      expect(exporter.sharedMimeType, 'image/png');
      // Anchors the popover on iPad and macOS; the whole-screen rect puts it in
      // the middle of the screen pointing at nothing.
      expect(exporter.sharedOrigin, isNotNull);
    });

    // A Save button that throws when tapped is worse than no Save button.
    testWidgets('a platform with no save dialog is not offered one', (
      tester,
    ) async {
      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.image)],
        exporter: _FakeExporter(canSave: false),
      );

      expect(find.byTooltip('Save'), findsNothing);
      expect(find.byTooltip('Share'), findsOneWidget);
    });

    testWidgets('a cancelled save dialog reports nothing', (tester) async {
      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.image)],
        exporter: _FakeExporter(savedPath: null),
      );

      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Saved to'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // The failure belongs on the page it happened on: a toast over a black
    // screen leaves nothing behind explaining why the screen is black.
    testWidgets('an attachment that cannot be fetched says so in place', (
      tester,
    ) async {
      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.image)],
        store: _FakeStore(null, failure: 'This attachment is gone.'),
        repository: StubChatRepository(),
      );
      await tester.pump();

      expect(find.text('This attachment is gone.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('swiping moves to the next item and its header', (
      tester,
    ) async {
      await pumpViewer(
        tester,
        items: [
          media(kind: MessageKind.image, eventId: r'$a'),
          media(
            kind: MessageKind.image,
            eventId: r'$b',
            body: 'the next morning',
          ),
        ],
      );
      await tester.pump();

      expect(find.text('the next morning'), findsNothing);
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();

      expect(find.text('the next morning'), findsOneWidget);
    });

    testWidgets('a swipe says where in the gallery it landed', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpViewer(
        tester,
        items: [
          media(kind: MessageKind.image, eventId: r'$a'),
          media(
            kind: MessageKind.image,
            eventId: r'$b',
            body: 'the next morning',
          ),
        ],
      );
      await tester.pump();
      final announced = watchAnnouncements(tester);

      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();

      // A swipe replaces the whole screen and said nothing at all. Position
      // first: "2 of 2" is the fact a swipe is asking about.
      expect(announced, hasLength(1));
      expect(announced.single, startsWith('2 of 2'));
      expect(announced.single, contains('the next morning'));
      handle.dispose();
    });

    testWidgets('the picture itself says what it is and whose it is', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.image, body: 'on the beach')],
      );
      await tester.pump();

      // A full-screen photo with no label is a black screen with nothing on
      // it, and the caption was a separate node floating over the top of it —
      // so it is said as part of the picture and drawn as one node, not two.
      expect(
        labelsIn(tester),
        contains('Photo, from Anna Maven, on the beach'),
      );
      handle.dispose();
    });

    // Eighty photos in a conversation must not become eighty downloads the
    // moment the viewer opens.
    testWidgets('only the page being looked at is fetched', (tester) async {
      final store = _FakeStore(staged);
      await pumpViewer(
        tester,
        items: [
          media(kind: MessageKind.image, eventId: r'$a'),
          media(kind: MessageKind.image, eventId: r'$b'),
          media(kind: MessageKind.image, eventId: r'$c'),
        ],
        store: store,
      );
      await tester.pump();

      expect(store.calls, 1);
    });

    // Save on a 200 MB video is exactly the case where the file is still
    // coming down when the button is reached for; giving up there would make
    // the action fail on the only file slow enough to need it.
    testWidgets('saving waits for a fetch already in flight', (tester) async {
      final gate = Completer<void>();
      final store = _FakeStore(staged, gate: gate.future);
      final exporter = _FakeExporter();

      await pumpViewer(
        tester,
        items: [media(kind: MessageKind.image)],
        store: store,
        exporter: exporter,
      );

      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      expect(exporter.suggestedName, isNull, reason: 'nothing to save yet');
      expect(store.calls, 1, reason: 'the tap must not start a second fetch');

      gate.complete();
      await tester.pumpAndSettle();
      expect(exporter.suggestedName, 'holiday.jpg');
    });
  });

  // The join between the two halves: the bubble publishes a hero tag and a tap,
  // and the viewer is what they lead to. Tested through a real thread rather
  // than by constructing the viewer directly, because what breaks silently here
  // is the wiring — a bubble whose `onOpen` is still null opens nothing, and
  // every unit test above would still pass.
  group('from the thread', () {
    const chatId = '!design_room:example.org';

    /// A JPEG header over the thumbnail threshold, so the demo plan is an
    /// `m.image` and the message it appends renders as a picture.
    AttachmentSource photo() => AttachmentSource(
      filename: 'holiday.jpg',
      sizeBytes: 96000,
      header: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]),
    );

    testWidgets('tapping a photo opens it full screen', (tester) async {
      final dir = Directory.systemTemp.createTempSync('weft_thread_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final staged = File(p.join(dir.path, 'holiday.jpg'))
        ..writeAsBytesSync(kPixel);

      final repository = StubChatRepository(bytes: kPixel);
      addTearDown(repository.dispose);

      Widget app(Widget home) => ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository),
          mediaFileStoreProvider.overrideWithValue(_FakeStore(staged)),
          mediaExporterProvider.overrideWithValue(_FakeExporter()),
          videoSurfaceProvider.overrideWithValue(
            (context, file) => const SizedBox.shrink(),
          ),
        ],
        child: MaterialApp(theme: WeftTheme.build(), home: home),
      );

      // Sent before the thread is opened, and deliberately: demo mode's
      // timeline is read once when the chat opens, so a photo enqueued after
      // that is in the upload list rather than in the history. What is being
      // tested here is the settled bubble, not the progress one.
      await tester.pumpWidget(app(const SizedBox.shrink()));
      unawaited(repository.sendAttachment(chatId, photo()));
      await tester.pumpAndSettle();

      await tester.pumpWidget(app(const ChatView(chatId: chatId)));
      await tester.pumpAndSettle();

      expect(find.byType(MediaAttachment), findsOneWidget);
      await tester.tap(find.byType(MediaAttachment));
      await tester.pumpAndSettle();

      expect(find.byType(MediaViewer), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Answers [attachmentBytes] through a callback so a test can assert *how* it
/// was asked, not only that it was.
class _RecordingBytesRepository extends DemoChatRepository {
  _RecordingBytesRepository(this.onBytes);

  final Uint8List? Function(bool thumbnail) onBytes;

  @override
  Future<AttachmentLocation?> attachmentLocation(
    String roomId,
    String eventId,
  ) async => null;

  @override
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  }) async => onBytes(thumbnail);
}
