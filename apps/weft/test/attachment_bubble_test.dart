import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/attachment_bubble.dart';
import 'package:weft/features/chat/attachment_preview_sheet.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/services/attachments/attachment_picker.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/attachment_fixtures.dart';
import 'package:weft/app/localisation.dart';

/// A picker that never touches a platform channel.
///
/// Every real implementation behind [AttachmentPicker] is a method channel, so
/// this is what makes the composer's whole pick → preview → send path testable
/// without a device: the sheet, the preview and the enqueue are the production
/// ones, and only the file dialog is pretend.
class _FakePicker implements AttachmentPicker {
  _FakePicker(this.result, {this.hasCamera = true});

  final List<AttachmentSource> result;
  final bool hasCamera;

  /// What the composer asked for, so a test can assert the Camera row actually
  /// opens the camera rather than the gallery.
  AttachmentPickSource? asked;

  @override
  bool supports(AttachmentPickSource source) =>
      source == AttachmentPickSource.camera ? hasCamera : true;

  @override
  Future<List<AttachmentSource>> pick(AttachmentPickSource source) async {
    asked = source;
    return result;
  }
}

void main() {
  const roomId = '!design_room:example.org';

  /// A JPEG header over the thumbnail threshold, which is what makes the plan
  /// an `m.image` rather than an `m.file`.
  AttachmentSource photo({String name = 'holiday.jpg', int size = 96000}) =>
      AttachmentSource(
        filename: name,
        sizeBytes: size,
        header: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]),
      );

  UploadPlan planFor(AttachmentSource source) =>
      planUpload(source, encrypted: false, maxUploadBytes: 0) as UploadPlan;

  WeftMessage message({
    required MessageKind kind,
    String body = 'holiday.jpg',
    String? attachmentUrl = '\$event',
    int? durationMs,
    int? sizeBytes,
    int? width,
    int? height,
    String? transcript,
    String? attachmentName,
  }) => WeftMessage(
    eventId: '\$event',
    roomId: roomId,
    network: ChatNetwork.matrix,
    senderId: '@anna:example.org',
    senderName: 'Anna',
    timestamp: DateTime(2026, 3, 4, 9, 30),
    kind: kind,
    isOwn: false,
    body: body,
    attachmentUrl: attachmentUrl,
    attachmentName: attachmentName,
    durationMs: durationMs,
    mediaSizeBytes: sizeBytes,
    mediaWidth: width,
    mediaHeight: height,
    transcript: transcript,
  );

  /// Pumps a bubble against a repository that answers [attachmentBytes] with
  /// [bytes] — null being demo mode's own answer, and the same answer an
  /// undecryptable attachment gets.
  Future<void> pumpBubble(
    WidgetTester tester,
    Widget child, {
    Uint8List? bytes,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(
            bytes == null
                ? DemoChatRepository()
                : StubChatRepository(bytes: bytes),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );
  }

  group('helpers', () {
    test('a size is shown in the units a file manager would use', () {
      expect(formatAttachmentSize(0), '0 B');
      expect(formatAttachmentSize(999), '999 B');
      expect(formatAttachmentSize(1024), '1.0 kB');
      expect(formatAttachmentSize(96000), '94 kB');
      expect(formatAttachmentSize(12 * 1024 * 1024), '12 MB');
      expect(formatAttachmentSize(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('a filename in the body is not a caption', () {
      // The two shapes that used to render as text under a photo.
      expect(attachmentCaption(message(kind: MessageKind.image)), isNull);
      expect(
        attachmentCaption(message(kind: MessageKind.image, body: 'Forwarded')),
        isNull,
      );
      expect(
        attachmentCaption(
          message(kind: MessageKind.image, body: 'IMG_4021.HEIC'),
        ),
        isNull,
      );
      // …and the things that genuinely are captions, including the sentence
      // that merely happens to mention a file.
      expect(
        attachmentCaption(
          message(kind: MessageKind.image, body: 'from the beach'),
        ),
        'from the beach',
      );
      expect(
        attachmentCaption(
          message(kind: MessageKind.image, body: 'here is report.pdf'),
        ),
        'here is report.pdf',
      );
    });

    test('a declared filename settles what the body is, with no guessing', () {
      // The heuristic above is a guess made when the sender said nothing. Once
      // they have separated the two keys there is nothing left to guess, and
      // guessing anyway loses in both directions.
      expect(
        attachmentCaption(
          message(
            kind: MessageKind.image,
            body: 'screenshot.png',
            attachmentName: 'IMG_4021.HEIC',
          ),
        ),
        'screenshot.png',
        reason: 'a caption that names a file is still a caption',
      );
      expect(
        attachmentCaption(
          message(
            kind: MessageKind.image,
            body: 'Forwarded',
            attachmentName: 'IMG_4021.HEIC',
          ),
        ),
        'Forwarded',
        reason: 'a sender who wrote "Forwarded" under a photo meant to',
      );
      // An empty body is still nothing to show, declared name or not.
      expect(
        attachmentCaption(
          message(
            kind: MessageKind.image,
            body: '',
            attachmentName: 'IMG_4021.HEIC',
          ),
        ),
        isNull,
      );
    });

    test('the name shown is the declared one, or the body', () {
      expect(
        attachmentFilename(
          message(
            kind: MessageKind.file,
            body: 'the contract, finally',
            attachmentName: 'contract.pdf',
          ),
        ),
        'contract.pdf',
      );
      // No declared name: the body *is* the name, which is what every client
      // that predates MSC2530 writes.
      expect(
        attachmentFilename(message(kind: MessageKind.file, body: 'notes.txt')),
        'notes.txt',
      );
    });

    test('a duration is only shown when there is one', () {
      expect(formatMediaDuration(null), isNull);
      expect(formatMediaDuration(0), isNull);
      expect(formatMediaDuration(9000), '0:09');
      expect(formatMediaDuration(125000), '2:05');
    });

    test('only an event that carries a file draws an attachment bubble', () {
      expect(rendersAsAttachment(message(kind: MessageKind.file)), isTrue);
      expect(rendersAsAttachment(message(kind: MessageKind.audio)), isTrue);
      // A voice note has its own waveform bubble, and a text message that
      // mentions a file is still a text message.
      expect(rendersAsAttachment(message(kind: MessageKind.voice)), isFalse);
      expect(
        rendersAsAttachment(
          message(kind: MessageKind.image, attachmentUrl: null),
        ),
        isFalse,
      );
    });
  });

  group('AttachmentBubble', () {
    testWidgets('an image whose bytes never arrive keeps its shape', (
      tester,
    ) async {
      // Demo mode's `attachmentBytes` returns null, which is the same path an
      // undecryptable photo takes: a placeholder, never a crash and never the
      // filename as text.
      await pumpBubble(
        tester,
        AttachmentBubble(message: message(kind: MessageKind.image), own: false),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.text('holiday.jpg'), findsNothing);
    });

    testWidgets('an image that decodes is the picture, and opens on tap', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.image),
          own: false,
          onOpen: () {},
        ),
        bytes: kPixel,
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      // The flight the viewer lands on. A tag that disagrees with the viewer's
      // does not throw — it silently stops animating — so it is asserted rather
      // than assumed.
      expect(
        tester.widget<Hero>(find.byType(Hero)).tag,
        mediaHeroTag(message(kind: MessageKind.image)),
      );
      // The handler is read rather than tapped: a `MemoryImage` resolves on the
      // real event loop, which a widget test's fake-async zone never runs, so
      // the decoded picture has no hit area to aim at. The rule under test is
      // the guard on `onTap`, and that is what is asserted — the tap itself is
      // exercised end to end in `media_viewer_test`.
      final detector = tester.widget<GestureDetector>(
        find.descendant(
          of: find.byType(MediaAttachment),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(detector.onTap, isNotNull);
    });

    testWidgets('a photo with no bytes yet cannot be opened', (tester) async {
      // Opening the viewer on an attachment that failed to decrypt would show a
      // full screen of the same placeholder, having animated to get there.
      var opened = false;
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.image),
          own: false,
          onOpen: () => opened = true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.broken_image_outlined));
      expect(opened, isFalse);
      expect(find.byType(Hero), findsNothing);
    });

    testWidgets('an announced shape is reserved before the bytes arrive', (
      tester,
    ) async {
      // The reflow this prevents: an encrypted 16:9 photo laying out as a squat
      // box and then pushing the timeline down under the reader's thumb the
      // moment it decodes.
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.image, width: 1600, height: 900),
          own: false,
        ),
      );
      await tester.pumpAndSettle();

      final wide = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.broken_image_outlined),
          matching: find.byType(Container),
        ),
      );
      expect(wide.width / wide.height, closeTo(16 / 9, 0.01));

      // A sender that announced nothing gets the default box rather than a
      // division by null.
      await pumpBubble(
        tester,
        AttachmentBubble(message: message(kind: MessageKind.image), own: false),
      );
      await tester.pumpAndSettle();

      final unknown = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.broken_image_outlined),
          matching: find.byType(Container),
        ),
      );
      expect(unknown.height, isNot(closeTo(wide.height, 1)));
    });

    testWidgets('a caption is drawn under the picture, a filename is not', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.image, body: 'from the beach'),
          own: false,
        ),
        bytes: kPixel,
      );
      await tester.pumpAndSettle();
      expect(find.text('from the beach'), findsOneWidget);

      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.image, body: 'IMG_4021.HEIC'),
          own: false,
        ),
        bytes: kPixel,
      );
      await tester.pumpAndSettle();
      expect(find.text('IMG_4021.HEIC'), findsNothing);
    });

    testWidgets('a sticker is a picture with no play badge', (tester) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.sticker, body: 'party parrot'),
          own: false,
        ),
        bytes: kPixel,
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      // Contained, not covered: a sticker is a transparent cutout, and a box
      // whose height came from a default rather than from the sender would
      // otherwise crop it.
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
    });

    testWidgets('a photo still fills its box', (tester) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.image, body: ''),
          own: false,
        ),
        bytes: kPixel,
      );
      await tester.pumpAndSettle();

      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
    });

    testWidgets('a video is marked as one over the poster', (tester) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.video, body: 'clip.mp4'),
          own: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    // The other half of the sticker fix. A sticker the timeline declined to
    // fetch — an animated one carrying WebM, which `attachmentServesAsThumbnail`
    // refuses — must not draw the broken-image glyph that the whole change
    // exists to get rid of.
    testWidgets('a sticker with no bytes is not reported as broken', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.sticker, body: ''),
          own: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);
    });

    // The rule it must not swallow: a photo that genuinely failed still says so.
    testWidgets('a photo with no bytes is still reported as broken', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.image, body: ''),
          own: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.byIcon(Icons.emoji_emotions_outlined), findsNothing);
    });

    testWidgets('a file shows its name, its size and a matching icon', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(
            kind: MessageKind.file,
            body: 'contract.pdf',
            sizeBytes: 2 * 1024 * 1024,
          ),
          own: false,
        ),
      );

      expect(find.text('contract.pdf'), findsOneWidget);
      expect(find.text('2.0 MB'), findsOneWidget);
      expect(find.byIcon(Icons.picture_as_pdf_rounded), findsOneWidget);
    });

    testWidgets('a file with no announced size shows none rather than 0 B', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.file, body: 'notes.txt'),
          own: false,
        ),
      );

      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.textContaining('B'), findsNothing);
    });

    testWidgets('an audio attachment keeps the Transcribe action', (
      tester,
    ) async {
      var transcribed = false;
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(
            kind: MessageKind.audio,
            body: 'voicemail.m4a',
            durationMs: 125000,
          ),
          own: false,
          onTranscribe: () => transcribed = true,
        ),
      );

      expect(find.text('voicemail.m4a'), findsOneWidget);
      expect(find.text('2:05'), findsOneWidget);

      await tester.tap(find.text('Transcribe'));
      expect(transcribed, isTrue);
    });

    testWidgets('an existing transcript is shown instead of the action', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(
            kind: MessageKind.audio,
            body: 'voicemail.m4a',
            transcript: 'call me back',
          ),
          own: false,
          onTranscribe: () {},
        ),
      );

      expect(find.text('call me back'), findsOneWidget);
      expect(find.text('Transcribe'), findsNothing);
    });

    testWidgets('a captioned photo draws the words and not the name', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(
            kind: MessageKind.image,
            body: 'at the beach',
            attachmentName: 'IMG_4021.HEIC',
          ),
          own: false,
        ),
        bytes: kPixel,
      );
      await tester.pumpAndSettle();

      expect(find.text('at the beach'), findsOneWidget);
      expect(find.text('IMG_4021.HEIC'), findsNothing);
    });

    testWidgets('a caption is rendered as rich text, not as markup', (
      tester,
    ) async {
      // The regression: a bare `Text` printed the sender's HTML source under
      // the picture, and a mention arrived as a raw user id.
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(
            kind: MessageKind.image,
            body: 'at the beach',
            attachmentName: 'IMG_4021.HEIC',
          ).copyWith(formattedBody: 'at <em>the</em> beach'),
          own: false,
        ),
        bytes: kPixel,
      );
      await tester.pumpAndSettle();

      expect(find.byType(RichTextView), findsOneWidget);
      expect(find.textContaining('<em>'), findsNothing);
    });

    testWidgets('a captioned file shows both the name and the words', (
      tester,
    ) async {
      // A file bubble is the case a caption used to be lost in entirely: the
      // name is what the row is *for*, so there was nowhere for the sentence
      // to go.
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(
            kind: MessageKind.file,
            body: 'the contract, finally',
            attachmentName: 'contract.pdf',
            sizeBytes: 183000,
          ),
          own: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('contract.pdf'), findsOneWidget);
      expect(find.text('the contract, finally'), findsOneWidget);
    });

    testWidgets('an uncaptioned photo still shows nothing under it', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        AttachmentBubble(
          message: message(kind: MessageKind.image, body: 'IMG_4021.HEIC'),
          own: false,
        ),
        bytes: kPixel,
      );
      await tester.pumpAndSettle();

      expect(find.text('IMG_4021.HEIC'), findsNothing);
      expect(find.byType(RichTextView), findsNothing);
    });
  });

  group('UploadProgressBubble', () {
    testWidgets('an upload in flight reports how far it has got', (
      tester,
    ) async {
      final task = UploadTask(
        id: 'upload-0',
        roomId: roomId,
        plan: planFor(photo()),
        state: UploadState.uploading,
        progress: 0.42,
      );

      var cancelled = false;
      await pumpBubble(
        tester,
        UploadProgressBubble(
          task: task,
          own: true,
          onCancel: () => cancelled = true,
          onRetry: () {},
        ),
      );

      // Determinate, and reporting the number the bar is drawn from — an
      // indeterminate bar over a known byte count says less than nothing.
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.42, 0.001));
      expect(find.text('42% of 94 kB'), findsOneWidget);
      expect(find.text('holiday.jpg'), findsOneWidget);
      // No retry while it is still going: the only sensible action is to stop.
      expect(find.text('Retry'), findsNothing);

      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(cancelled, isTrue);
    });

    testWidgets('hashing says what it is doing rather than showing 0%', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        UploadProgressBubble(
          task: UploadTask(
            id: 'upload-0',
            roomId: roomId,
            plan: planFor(photo()),
            state: UploadState.hashing,
          ),
          own: true,
          onCancel: () {},
          onRetry: () {},
        ),
      );

      expect(find.text('Preparing · 94 kB'), findsOneWidget);
      expect(find.textContaining('0%'), findsNothing);
    });

    testWidgets('a failed upload offers a retry and says why', (tester) async {
      var retried = false;
      await pumpBubble(
        tester,
        UploadProgressBubble(
          task: UploadTask(
            id: 'upload-0',
            roomId: roomId,
            plan: planFor(photo()),
            state: UploadState.failed,
            progress: 0.6,
            attempts: 3,
            failure: 'The server is not accepting uploads.',
          ),
          own: true,
          onCancel: () {},
          onRetry: () => retried = true,
        ),
      );

      expect(find.text('The server is not accepting uploads.'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);

      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);
    });

    testWidgets('a cancelled upload can also be revived', (tester) async {
      await pumpBubble(
        tester,
        UploadProgressBubble(
          task: UploadTask(
            id: 'upload-0',
            roomId: roomId,
            plan: planFor(photo()),
            state: UploadState.cancelled,
          ),
          own: true,
          onCancel: () {},
          onRetry: () {},
        ),
      );

      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('the composer attach path', () {
    Future<DemoChatRepository> pumpChat(
      WidgetTester tester,
      _FakePicker picker, {
      String chatId = roomId,
      Duration uploadTick = Duration.zero,
    }) async {
      final repository = DemoChatRepository(uploadTick: uploadTick);
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(repository),
            attachmentPickerProvider.overrideWithValue(picker),
            // The preview sheet reads the picked file to show a thumbnail;
            // these sources name files that do not exist on disk.
            attachmentFileReaderProvider.overrideWithValue(
              (source) async => source.header,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(),
            home: ChatView(chatId: chatId),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('a picked photo is previewed and then sent', (tester) async {
      final picker = _FakePicker([photo()]);
      final repository = await pumpChat(tester, picker);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo or video'));
      await tester.pumpAndSettle();

      expect(picker.asked, AttachmentPickSource.media);
      // Nothing is sent by picking: the preview is the second chance a picker
      // does not give.
      expect(find.text('Send 1 file'), findsOneWidget);
      expect(find.text('94 kB to Design Team'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      final chats = await repository.watchChats().first;
      final sent = chats.firstWhere((c) => c.id == roomId).lastMessage!;
      expect(sent.kind, MessageKind.image);
      expect(sent.body, 'holiday.jpg');
    });

    testWidgets('an upload in flight is a bubble with a way out', (
      tester,
    ) async {
      // A tick slow enough to observe. The instant transport every other test
      // uses would take the upload from picked to sent inside one frame, which
      // is the one state this bubble exists to show.
      final picker = _FakePicker([photo()]);
      await pumpChat(
        tester,
        picker,
        uploadTick: const Duration(milliseconds: 100),
      );

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo or video'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('holiday.jpg'), findsOneWidget);

      // The tooltip names the file: a timeline can hold several uploads at
      // once, and three identical "Cancel upload" buttons are three different
      // consequences a screen-reader user cannot tell apart.
      await tester.tap(find.byTooltip('Cancel upload of holiday.jpg'));
      await tester.pump();

      // Cancelling stops the upload without throwing the file away: the bubble
      // stays, now offering the retry that spares picking it again.
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('cancelling the preview sends nothing', (tester) async {
      final picker = _FakePicker([photo()]);
      final repository = await pumpChat(tester, picker);
      final before = (await repository.watchChats().first)
          .firstWhere((c) => c.id == roomId)
          .lastMessage;

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(picker.asked, AttachmentPickSource.files);
      final after = (await repository.watchChats().first)
          .firstWhere((c) => c.id == roomId)
          .lastMessage;
      expect(after, before);
    });

    testWidgets('removing the last file is the same as cancelling', (
      tester,
    ) async {
      final picker = _FakePicker([photo(), photo(name: 'second.jpg')]);
      await pumpChat(tester, picker);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo or video'));
      await tester.pumpAndSettle();
      expect(find.text('Send 2 files'), findsOneWidget);

      // Each row's remove button names its own file, which is what makes the
      // two of them distinguishable at all — by tooltip here, and by
      // announcement for a reader.
      await tester.tap(find.byTooltip('Remove holiday.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('Send 1 file'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove second.jpg'));
      await tester.pumpAndSettle();
      // The sheet is gone, and it closed as a cancellation rather than sending
      // an empty batch.
      expect(find.textContaining('Send '), findsNothing);
    });

    testWidgets('a desktop with no camera is not offered one', (tester) async {
      await pumpChat(tester, _FakePicker(const [], hasCamera: false));

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();

      expect(find.text('Photo or video'), findsOneWidget);
      expect(find.text('Camera'), findsNothing);
    });

    testWidgets('a file the server will not take never becomes a bubble', (
      tester,
    ) async {
      // Over `kDemoMaxUploadBytes`, so `planUpload` rejects it outright.
      final picker = _FakePicker([photo(name: 'huge.jpg', size: 1 << 30)]);
      await pumpChat(tester, picker);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo or video'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // A rejection is not retryable, so it is a sentence rather than a
      // progress bubble the user could only dismiss.
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('a caption typed in the preview rides on the photo', (
      tester,
    ) async {
      final picker = _FakePicker([photo()]);
      final repository = await pumpChat(tester, picker);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo or video'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Caption'),
        'at the beach',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      final chats = await repository.watchChats().first;
      final sent = chats.firstWhere((c) => c.id == roomId).lastMessage!;
      // One event carrying both, not a photo with a sentence racing it.
      expect(sent.kind, MessageKind.image);
      expect(sent.body, 'at the beach');
      expect(sent.attachmentName, 'holiday.jpg');
    });

    testWidgets('a caption left blank sends the filename, as before', (
      tester,
    ) async {
      final picker = _FakePicker([photo()]);
      final repository = await pumpChat(tester, picker);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo or video'));
      await tester.pumpAndSettle();

      // Touched and then cleared, which is the shape that produced a body of
      // whitespace: the field is non-empty right up to the moment it is read.
      final field = find.widgetWithText(TextField, 'Caption');
      await tester.enterText(field, 'never mind');
      await tester.pumpAndSettle();
      await tester.enterText(field, '   ');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      final chats = await repository.watchChats().first;
      final sent = chats.firstWhere((c) => c.id == roomId).lastMessage!;
      expect(sent.body, 'holiday.jpg');
      expect(sent.attachmentName, isNull);
    });

    testWidgets('one caption goes on the first of a batch, not on each', (
      tester,
    ) async {
      final picker = _FakePicker([
        photo(name: 'one.jpg'),
        photo(name: 'two.jpg'),
      ]);
      final repository = await pumpChat(tester, picker);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo or video'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Caption'),
        'the whole afternoon',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      final timeline = await repository.timelineFor(roomId);
      await timeline.loadMore();
      final sent = timeline
          .view()
          .messages
          .where((m) => m.isOwn && m.kind == MessageKind.image)
          .toList();

      // Newest first, so the reverse of the pick order. The caption belongs to
      // `one.jpg` — repeated on both it is the same sentence shouted twice.
      expect(sent.map((m) => m.attachmentName ?? m.body), [
        'two.jpg',
        'one.jpg',
      ]);
      expect(sent.last.body, 'the whole afternoon');
      expect(sent.first.body, 'two.jpg');
    });

    testWidgets('the caption field is cleared with the sheet', (tester) async {
      // The controller belongs to the sheet's state, so a second pick must not
      // arrive pre-loaded with the last one's words — which is exactly what a
      // caption hoisted to the composer would do.
      final picker = _FakePicker([photo()]);
      await pumpChat(tester, picker);

      Future<void> openPreview() async {
        await tester.tap(find.byTooltip('Attach'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Photo or video'));
        await tester.pumpAndSettle();
      }

      await openPreview();
      await tester.enterText(
        find.widgetWithText(TextField, 'Caption'),
        'first time',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      await openPreview();
      expect(find.text('first time'), findsNothing);
    });

    testWidgets('the preview reads only what it can decode', (tester) async {
      // Bigger than the decode cap, so the tile shows an icon instead of
      // pulling a 60 MP RAW through the image cache for a 44pt square.
      expect(kPreviewDecodeMaxBytes, 12 * 1024 * 1024);

      final picker = _FakePicker([
        photo(name: 'enormous.jpg', size: kPreviewDecodeMaxBytes + 1),
      ]);
      await pumpChat(tester, picker);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo or video'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.image_rounded), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });
}
