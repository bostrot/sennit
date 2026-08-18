import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/intents.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/attachment_preview_sheet.dart';
import 'package:weft/features/share/share_target_sheet.dart';
import 'package:weft/services/attachments/attachment_picker.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// A stand-in for `MainActivity`.
///
/// The platform side of a share is two questions — what is this file, and where
/// can I open it — so a fake is a map from URI to an answer for each. Every test
/// below stages *real* files, because the thing being tested is that a
/// `content://` URI ends up as an [AttachmentSource] whose `filename` the upload
/// path can actually open.
class _FakeShareHost {
  _FakeShareHost(this.channel) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  final MethodChannel channel;

  /// URI → the map `readSharedFileMeta` answers with, or null for a provider
  /// that will not say.
  final Map<String, Map<String, Object?>?> meta = {};

  /// URI → the path `stageSharedFile` returns, or null for a file that could
  /// not be copied.
  final Map<String, String?> staged = {};

  /// What `getInitialIntent` replays on a cold start.
  Map<String, Object?>? initialIntent;

  /// URIs actually staged, in order — the assertion that a file refused for its
  /// size was refused *before* its bytes moved.
  final List<String> stageCalls = [];

  /// Every call, for the methods whose *shape* is the thing under test rather
  /// than their answer — publishing share targets, where what crosses the
  /// channel is the contract `ShareShortcuts.kt` reads back.
  final List<MethodCall> calls = [];

  /// How many targets the device claims to have published. Fewer than asked for
  /// on a launcher at its per-activity cap, which is a device property.
  int published = 0;

  /// A platform that refuses. Set to throw the way a real one does — a missing
  /// handler on desktop, a `PlatformException` from a launcher that said no.
  Object? Function(MethodCall call)? answer;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    if (answer != null) return answer!(call);
    final uri = (call.arguments as Map?)?['uri'] as String?;
    switch (call.method) {
      case 'publishShareTargets':
        return published;
      case 'clearShareTargets':
        return true;
      case 'getInitialIntent':
        return initialIntent;
      case 'readSharedFileMeta':
        return meta[uri];
      case 'stageSharedFile':
        stageCalls.add(uri!);
        return staged[uri];
      default:
        return null;
    }
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('weft-test/intents');
  const roomId = '!design_room:example.org';

  late Directory sandbox;
  late _FakeShareHost host;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('weft-share-test');
    host = _FakeShareHost(channel);
  });

  tearDown(() {
    host.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  /// A file on disk that sniffs as a JPEG, whatever anyone declares it to be.
  ///
  /// Only the first three bytes decide the type; the rest is there so the size
  /// is a realistic one and the header slice is a genuine truncation of a bigger
  /// file rather than the whole thing.
  File jpegFile(String name, {int size = 96000}) {
    final bytes = Uint8List(size);
    bytes.setAll(0, const [0xFF, 0xD8, 0xFF, 0xE0]);
    return File('${sandbox.path}/$name')..writeAsBytesSync(bytes);
  }

  /// Registers [uri] the way Android would: a display name and a size from the
  /// content resolver, and a staged copy to open.
  void share(
    String uri,
    File file, {
    String? name,
    Object? size = _unset,
    String? mimeType,
  }) {
    host.meta[uri] = {
      'name': name ?? file.uri.pathSegments.last,
      'size': size == _unset ? file.lengthSync() : size,
      'mimeType': mimeType,
    };
    host.staged[uri] = file.path;
  }

  WeftIntents intents({int maxFileBytes = kMaxSharedFileBytes}) =>
      WeftIntents(channel: channel, maxFileBytes: maxFileBytes);

  group('resolving a share intent', () {
    test('a shared photo becomes a source the upload path can open', () async {
      final file = jpegFile('holiday.jpg');
      share('content://media/1', file, mimeType: '*/*');

      final resolved = await intents().resolveSharedFiles(
        const SharedPayload(mimeType: '*/*', uris: ['content://media/1']),
      );

      expect(resolved.problems, isEmpty);
      final source = resolved.sources.single;
      expect(source.filename, file.path, reason: 'the upload opens this path');
      expect(source.basename, 'holiday.jpg');
      expect(source.sizeBytes, 96000);
      expect(
        source.header,
        hasLength(kAttachmentHeaderBytes),
        reason: 'a header slice, not the file',
      );
      // The declared type is carried through untouched and then overruled: a
      // share intent saying `*/*` about a JPEG is the normal case, and sending
      // it as m.file shows a paperclip on every other client.
      expect(source.declaredMimeType, '*/*');
      expect(sniffMimeType(source), 'image/jpeg');
      expect(messageKindFor(sniffMimeType(source)), MessageKind.image);
    });

    test('the resolver'
        's per-file type beats the intent'
        's batch type', () async {
      final file = jpegFile('scan.pdf');
      share('content://media/1', file, mimeType: 'application/pdf');

      final resolved = await intents().resolveSharedFiles(
        const SharedPayload(mimeType: '*/*', uris: ['content://media/1']),
      );

      expect(resolved.sources.single.declaredMimeType, 'application/pdf');
    });

    test('the intent'
        's type is used when the provider offers none', () async {
      // The other direction of the same rule: a content provider is allowed to
      // say nothing about a URI, and the intent's own type is then the only
      // hint there is. Both are still only hints — `sniffMimeType` has the last
      // word — but dropping this one sends a photo shared by an app with a
      // terse provider as `application/octet-stream`.
      final file = jpegFile('holiday.jpg');
      share('content://media/1', file, mimeType: null);

      final resolved = await intents().resolveSharedFiles(
        const SharedPayload(
          mimeType: 'image/jpeg',
          uris: ['content://media/1'],
        ),
      );

      expect(resolved.sources.single.declaredMimeType, 'image/jpeg');
    });

    test('a SEND_MULTIPLE batch resolves in the order it was shared', () async {
      share('content://media/1', jpegFile('one.jpg'));
      share('content://media/2', jpegFile('two.jpg'));

      final resolved = await intents().resolveSharedFiles(
        const SharedPayload(
          mimeType: 'image/*',
          uris: ['content://media/1', 'content://media/2'],
        ),
      );

      expect(
        resolved.sources.map((s) => s.basename),
        ['one.jpg', 'two.jpg'],
        reason: 'the room must read in the order the user picked',
      );
    });

    test('a file over the cap is refused before a byte is copied', () async {
      final file = jpegFile('holiday.mp4');
      share('content://media/1', file, size: 200 * 1024 * 1024);

      final resolved = await intents().resolveSharedFiles(
        const SharedPayload(mimeType: 'video/mp4', uris: ['content://media/1']),
      );

      expect(resolved.sources, isEmpty);
      expect(
        host.stageCalls,
        isEmpty,
        reason: 'the whole point of asking for the size first',
      );
      expect(
        resolved.problems.single,
        allOf(
          contains('holiday.mp4'),
          contains('200 MB'),
          contains('too large'),
          contains('100 MB'),
        ),
      );
    });

    test(
      'a provider that under-reports a size is caught by the copy',
      () async {
        final file = jpegFile('holiday.jpg', size: 96000);
        // No size at all, which is legal: a stream with no backing file.
        share('content://media/1', file, size: null);

        final resolved = await intents(
          maxFileBytes: 1024,
        ).resolveSharedFiles(const SharedPayload(uris: ['content://media/1']));

        expect(resolved.sources, isEmpty);
        expect(resolved.problems.single, contains('too large'));
        expect(
          file.existsSync(),
          isFalse,
          reason: 'the staged copy of a file that will not be sent is dropped',
        );
      },
    );

    test(
      'a file that cannot be staged is a sentence, not a lost batch',
      () async {
        share('content://media/1', jpegFile('one.jpg'));
        host.meta['content://media/2'] = {'name': 'gone.jpg', 'size': 4000};
        host.staged['content://media/2'] = null;

        final resolved = await intents().resolveSharedFiles(
          const SharedPayload(uris: ['content://media/1', 'content://media/2']),
        );

        expect(resolved.sources.single.basename, 'one.jpg');
        expect(resolved.problems.single, 'gone.jpg could not be read.');
      },
    );

    test('a provider with nothing to say still yields a usable name', () async {
      final file = jpegFile('opaque');
      host.meta['content://media/4021'] = null;
      host.staged['content://media/4021'] = file.path;

      final resolved = await intents().resolveSharedFiles(
        const SharedPayload(uris: ['content://media/4021']),
      );

      // The staged path is the authority on the name; the URI's last segment is
      // only what the sentence would have used had staging failed.
      expect(resolved.sources.single.basename, 'opaque');
    });

    test('a file:// URI is opened where it is, not staged again', () async {
      // What an iOS staged share becomes: `StagedShareReader` has already had
      // the platform move the bytes out of the App Group container and into the
      // app's own, so both platform calls exist to reach exactly this state and
      // neither is implemented on the platform this branch runs on.
      final file = jpegFile('holiday.jpg');

      final resolved = await intents().resolveSharedFiles(
        SharedPayload(
          mimeType: 'image/jpeg',
          uris: [Uri.file(file.path).toString()],
        ),
      );

      expect(resolved.problems, isEmpty);
      expect(host.calls, isEmpty, reason: 'nothing to ask the platform');
      final source = resolved.sources.single;
      expect(source.filename, file.path);
      expect(source.basename, 'holiday.jpg');
      expect(source.sizeBytes, 96000);
      expect(sniffMimeType(source), 'image/jpeg');
    });

    test('a file:// URI with a space in its name round-trips', () async {
      // `Uri.file` percent-encodes, and a path that reaches the upload path
      // still holding `%20` is a file that does not exist.
      final file = jpegFile('holiday snap.jpg');

      final resolved = await intents().resolveSharedFiles(
        SharedPayload(uris: [Uri.file(file.path).toString()]),
      );

      expect(resolved.sources.single.basename, 'holiday snap.jpg');
    });

    test('a staged file that vanished is a sentence, not a crash', () async {
      // The window is real: the ingest cache is swept on a day's TTL, and a
      // share left open in the sheet across that is a share whose files went.
      final resolved = await intents().resolveSharedFiles(
        SharedPayload(uris: [Uri.file('${sandbox.path}/gone.jpg').toString()]),
      );

      expect(resolved.sources, isEmpty);
      expect(resolved.problems.single, 'gone.jpg could not be read.');
    });

    test('the cap applies to a staged file too', () async {
      // The third look at the same number — the extension checks it twice
      // before writing anything — and the only one in a process whose source
      // this repository can see.
      final file = jpegFile('holiday.jpg', size: 96000);

      final resolved = await intents(maxFileBytes: 1024).resolveSharedFiles(
        SharedPayload(uris: [Uri.file(file.path).toString()]),
      );

      expect(resolved.sources, isEmpty);
      expect(resolved.problems.single, contains('too large'));
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'unlike a content:// copy, this file is not this call'
            's to throw away',
      );
    });

    test('a text-only share resolves to nothing at all', () async {
      final resolved = await intents().resolveSharedFiles(
        const SharedPayload(text: 'hello'),
      );

      expect(resolved.isEmpty, isTrue);
      expect(host.stageCalls, isEmpty);
    });
  });

  group('cold start', () {
    test('the replayed launching intent carries file URIs', () async {
      host.initialIntent = const {
        'type': 'share',
        'mimeType': 'image/jpeg',
        'uris': ['content://media/1'],
      };

      SharedPayload? delivered;
      final weftIntents = intents()..onShare = (p) => delivered = p;
      await weftIntents.deliverInitialIntent();

      expect(delivered, isNotNull);
      expect(
        delivered!.uris,
        ['content://media/1'],
        reason:
            'a cold-start share of a photo must not arrive as an empty '
            'sheet',
      );
      expect(delivered!.text, isNull);
    });

    test('a replayed intent is only delivered once', () async {
      host.initialIntent = const {
        'type': 'share',
        'uris': ['content://media/1'],
      };

      var shares = 0;
      final weftIntents = intents()..onShare = (_) => shares++;
      await weftIntents.deliverInitialIntent();
      host.initialIntent = null;
      await weftIntents.deliverInitialIntent();

      expect(shares, 1);
    });
  });

  group('the share sheet', () {
    /// A photo already resolved — what [WeftIntents.resolveSharedFiles] returns
    /// for a staged `content://` URI, asserted for real in the group above.
    AttachmentSource photo({String name = 'holiday.jpg', int size = 96000}) =>
        AttachmentSource(
          filename: '/tmp/weft-share/$name',
          sizeBytes: size,
          header: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]),
        );

    Future<DemoChatRepository> pumpSheet(
      WidgetTester tester,
      SharedPayload payload, {
      ResolvedShare resolved = const ResolvedShare(),
      ChatRepository Function(DemoChatRepository inner)? wrap,
    }) async {
      final resolver = _FakeResolver(resolved);
      // Instant uploads: the tick exists so a human can watch the progress
      // bubble, and a `pumpAndSettle` would wait out every one of them.
      final repository = DemoChatRepository(uploadTick: Duration.zero);
      addTearDown(repository.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(
              wrap?.call(repository) ?? repository,
            ),
            sharedFileResolverProvider.overrideWithValue(resolver),
            // The strip decodes each picked file to show a thumbnail; these
            // sources describe files a widget test cannot read.
            attachmentFileReaderProvider.overrideWithValue(
              (source) async => source.header,
            ),
          ],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showShareTargetSheet(context, payload),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return repository;
    }

    /// Choose a conversation from the list and confirm the send.
    ///
    /// Two taps rather than one since Phase 04 task 7. Choosing the target and
    /// confirming are separate steps because three things live between them —
    /// the caption, a merged chat's outgoing network, and ticking a second
    /// conversation — and the pre-selected path from a Direct Share face has
    /// landed on that same confirmation since task 4.
    Future<void> shareTo(WidgetTester tester, String title) async {
      // Scrolled to first: the header carries a thumbnail strip when files are
      // shared, and the last row of a three-chat list falls just past the
      // bottom of a 600px test viewport because of it. A real sheet is
      // scrollable for the same reason.
      await tester.ensureVisible(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send to $title'));
      await tester.pumpAndSettle();
    }

    /// The thread as the chat view would draw it: newest first.
    Future<List<WeftMessage>> messages(DemoChatRepository repository) async {
      final timeline = await repository.timelineFor(roomId);
      await timeline.loadMore();
      return timeline.view().messages;
    }

    Future<WeftMessage?> lastMessage(DemoChatRepository repository) async {
      final chats = await repository.watchChats().first;
      return chats.firstWhere((c) => c.id == roomId).lastMessage;
    }

    testWidgets('a shared photo is shown and then sent', (tester) async {
      final repository = await pumpSheet(
        tester,
        const SharedPayload(mimeType: '*/*', uris: ['content://media/1']),
        resolved: ResolvedShare(sources: [photo()]),
      );

      expect(find.text('holiday.jpg · 94 kB'), findsOneWidget);
      expect(find.byType(AttachmentSourceThumbnail), findsOneWidget);

      await shareTo(tester, 'Design Team');

      final sent = await lastMessage(repository);
      expect(sent!.kind, MessageKind.image);
      expect(sent.body, 'holiday.jpg');
      expect(find.text('Sent to Design Team'), findsOneWidget);
    });

    testWidgets('a batch is summarised and sent whole', (tester) async {
      final repository = await pumpSheet(
        tester,
        const SharedPayload(
          mimeType: 'image/*',
          uris: ['content://media/1', 'content://media/2'],
        ),
        resolved: ResolvedShare(
          sources: [
            photo(name: 'one.jpg'),
            photo(name: 'two.jpg'),
          ],
        ),
      );

      expect(find.text('2 files · 188 kB'), findsOneWidget);
      expect(find.byType(AttachmentSourceThumbnail), findsNWidgets(2));

      await shareTo(tester, 'Design Team');

      final history = await messages(repository);
      expect(
        history.take(2).map((m) => m.body),
        ['two.jpg', 'one.jpg'],
        reason: 'newest first, so the batch landed in the order it was shared',
      );
    });

    testWidgets('a caption is sent before the photo it describes', (
      tester,
    ) async {
      late _RecordingRepository recorder;
      final repository = await pumpSheet(
        tester,
        const SharedPayload(
          text: 'look at this',
          mimeType: 'image/jpeg',
          uris: ['content://media/1'],
        ),
        resolved: ResolvedShare(sources: [photo()]),
        wrap: (inner) => recorder = _RecordingRepository(inner),
      );

      expect(find.text('"look at this" · holiday.jpg · 94 kB'), findsOneWidget);

      await shareTo(tester, 'Design Team');

      expect(
        recorder.sent,
        ['text: look at this', 'file: holiday.jpg'],
        reason: 'a caption that lands after its photo reads backwards',
      );
      expect((await messages(repository)).first.body, 'holiday.jpg');
    });

    testWidgets('text alone still goes, exactly as it did before', (
      tester,
    ) async {
      final repository = await pumpSheet(
        tester,
        const SharedPayload(text: 'hello', mimeType: 'text/plain'),
      );

      expect(find.text('"hello"'), findsOneWidget);
      await shareTo(tester, 'Design Team');

      expect((await lastMessage(repository))!.body, 'hello');
    });

    testWidgets('a file too large says so, and sends nothing', (tester) async {
      final repository = await pumpSheet(
        tester,
        const SharedPayload(mimeType: 'video/mp4', uris: ['content://media/1']),
        resolved: const ResolvedShare(
          problems: [
            'holiday.mp4 is 200 MB, which is too large to share — the limit '
                'is 100 MB.',
          ],
        ),
      );
      final before = await lastMessage(repository);

      expect(find.textContaining('too large'), findsOneWidget);
      // Nothing left to send: the conversations are still listed, because the
      // sheet is showing why, but tapping one must not silently do nothing.
      await tester.tap(find.text('Design Team'));
      await tester.pumpAndSettle();

      expect(await lastMessage(repository), before);
    });

    group('a share aimed at a conversation', () {
      // Android's Direct Share, and later the iOS extension's picker: the user
      // tapped a face in another app's share sheet, so "who" is already answered
      // and the sheet must not ask it again.
      testWidgets('goes straight to the chosen chat', (tester) async {
        final repository = await pumpSheet(
          tester,
          const SharedPayload(
            text: 'hello',
            mimeType: 'text/plain',
            targetChatId: roomId,
          ),
        );

        expect(find.text('Send to Design Team'), findsWidgets);
        expect(
          find.text('Signal Contact'),
          findsNothing,
          reason: 'the target list is a question that has been answered',
        );

        await tester.tap(
          find.widgetWithText(FilledButton, 'Send to Design Team'),
        );
        await tester.pumpAndSettle();

        expect((await lastMessage(repository))!.body, 'hello');
      });

      testWidgets('a stale shortcut falls back to the picker', (tester) async {
        // A launcher holds a long-lived shortcut indefinitely, so the chat behind
        // one can have been archived, left or unmerged since it was published.
        // Sending to an id nothing on screen accounts for is the one outcome
        // worse than asking again.
        await pumpSheet(
          tester,
          const SharedPayload(
            text: 'hello',
            mimeType: 'text/plain',
            targetChatId: '!gone_forever:example.org',
          ),
        );

        expect(find.text('Share to…'), findsOneWidget);
        expect(find.text('Design Team'), findsWidgets);
      });

      testWidgets('the user can still choose someone else', (tester) async {
        // A Direct Share row is four small faces; a mis-tap on it is ordinary,
        // and without a way back the only escape is to cancel and start again in
        // the other app.
        final repository = await pumpSheet(
          tester,
          const SharedPayload(
            text: 'hello',
            mimeType: 'text/plain',
            targetChatId: roomId,
          ),
        );

        await tester.tap(find.text('Choose another chat'));
        await tester.pumpAndSettle();

        expect(find.text('Share to…'), findsOneWidget);
        await shareTo(tester, 'Design Team');

        expect((await lastMessage(repository))!.body, 'hello');
      });

      testWidgets('nothing sendable disables the send', (tester) async {
        final repository = await pumpSheet(
          tester,
          const SharedPayload(
            mimeType: 'video/mp4',
            uris: ['content://media/1'],
            targetChatId: roomId,
          ),
          resolved: const ResolvedShare(
            problems: ['holiday.mp4 is 200 MB, which is too large to share.'],
          ),
        );
        final before = await lastMessage(repository);

        await tester.tap(
          find.widgetWithText(FilledButton, 'Send to Design Team'),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();

        expect(await lastMessage(repository), before);
      });
    });
  });

  group('publishing share targets', () {
    /// One `ShareTargetSlot.toJson()` with the resolved `iconPath` added, which
    /// is the shape `ShareShortcuts.publish` reads on the other side.
    Map<String, Object?> slot(String chatId, {String? iconPath}) => {
      'id': 'chat_${chatId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}',
      'chatId': chatId,
      'shortLabel': 'Grace',
      'longLabel': 'Grace Hopper',
      'link': 'weft://chat/$chatId',
      'networks': const ['matrix'],
      'iconPath': iconPath,
      'rank': 0,
    };

    test('the slots cross the channel WeftIntents already owns', () async {
      host.published = 2;

      final count = await intents().publishShareTargets([
        slot('merged:contact_1', iconPath: '/tmp/grace.png'),
        slot('!design:example.org'),
      ]);

      // What the *device* published, not what was asked for: the per-activity
      // cap is a device property and the platform clamps to it.
      expect(count, 2);
      final call = host.calls.single;
      expect(call.method, 'publishShareTargets');
      final slots = (call.arguments! as Map)['slots']! as List;
      expect(slots, hasLength(2));
      expect((slots.first as Map)['chatId'], 'merged:contact_1');
      expect(
        (slots.first as Map)['iconPath'],
        '/tmp/grace.png',
        reason: 'the avatar is resolved on this side; Kotlin only decodes it',
      );
    });

    test('clearing is a call, and asks for nothing back', () async {
      await intents().clearShareTargets();
      expect(host.calls.single.method, 'clearShareTargets');
    });

    test('a platform with no shortcuts publishes none, quietly', () async {
      // Every platform but Android, and an Android launcher at its limit. A
      // share sheet showing the app icon instead of faces is a worse share
      // sheet, not a broken app.
      host.answer = (_) => throw MissingPluginException();
      expect(await intents().publishShareTargets([slot('x')]), 0);
      await intents().clearShareTargets();

      host.answer = (_) => throw PlatformException(code: 'refused');
      expect(await intents().publishShareTargets([slot('x')]), 0);
      await intents().clearShareTargets();
    });
  });
}

/// Sentinel for "the test did not say", so that an explicit null size — a
/// provider that does not know — is distinguishable from the default.
const Object _unset = Object();

/// Records what the sheet sent, and in which order.
///
/// The demo repository keeps a sent *text* only as the chat's preview, so
/// "caption first, then the photo" cannot be read back out of it — the photo
/// overwrites the preview a moment later. The claim is about the order of two
/// calls, so it is asserted on the calls.
class _RecordingRepository implements ChatRepository {
  _RecordingRepository(this.inner);

  final DemoChatRepository inner;
  final List<String> sent = [];

  @override
  Stream<List<Chat>> watchChats() => inner.watchChats();

  @override
  Chat? chatForRoom(String roomId) => inner.chatForRoom(roomId);

  @override
  Stream<List<UploadTask>> watchUploads(String chatId) =>
      inner.watchUploads(chatId);

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) {
    sent.add('text: $body');
    return inner.send(chatId, body, via: via);
  }

  @override
  Future<void> sendAttachment(
    String chatId,
    AttachmentSource source, {
    ChatNetwork? via,
    bool isVoiceNote = false,
  }) {
    sent.add('file: ${source.basename}');
    return inner.sendAttachment(
      chatId,
      source,
      via: via,
      isVoiceNote: isVoiceNote,
    );
  }

  /// Everything else throws on purpose: a share sheet that starts calling it
  /// should fail loudly rather than quietly do half a send.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A resolution that has already happened.
///
/// The sheet's own behaviour — the summary, the thumbnails, what a tap sends,
/// and what a refused file does to the list — is what the widget group is about;
/// the resolution behind it is asserted against real files and a real channel in
/// the group above, where a real event loop exists to finish a disk read.
class _FakeResolver implements SharedFileResolver {
  const _FakeResolver(this.resolved);

  final ResolvedShare resolved;

  @override
  Future<ResolvedShare> resolveSharedFiles(SharedPayload payload) async =>
      resolved;
}
