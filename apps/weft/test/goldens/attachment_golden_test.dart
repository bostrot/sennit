import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/features/chat/attachment_preview_sheet.dart';
import 'package:weft/features/chat/chat_view.dart';

import '../support/attachment_fixtures.dart';
import '../support/golden_harness.dart';

/// Goldens for the attachment surfaces built in Phase 02.
///
/// Every bubble is captured *inside [ChatView]* rather than pumped on a bare
/// Scaffold, because a bubble's chrome — the bubble colour, the corner that
/// squares off on the sender's side, the timestamp row, the grouping padding —
/// lives in `chat_view.dart` and is private to it. A golden of the content
/// alone would sit on a plain surface, drawing `peerBubbleText` on a background
/// it was never meant to be read against, and would pass unchanged through
/// exactly the regression it exists to catch: an attachment that no longer fits
/// the bubble around it.
///
/// The fixtures are stated rather than synthesised. [StubChatRepository] takes
/// the room's history and the in-flight uploads as values, so nothing in these
/// images depends on how many timer ticks elapsed or on what the demo
/// generator felt like producing.
void main() {
  setUpAll(loadGoldenFonts);

  /// A single-source Matrix room from the demo inbox, so the app bar, the
  /// composer and the chat title are the real ones.
  const chatId = '!design_room:example.org';

  /// Fixed, and well before [DemoChatRepository]'s own clock, so the day
  /// divider and the timestamps are the same on every run.
  final sentAt = DateTime(2026, 8, 15, 14, 20);

  WeftMessage message({
    required String eventId,
    required MessageKind kind,
    required String body,
    required int minutesAgo,
    bool isOwn = false,
    int? durationMs,
    int? sizeBytes,
    int? width,
    int? height,
    DeliveryState? delivery,
  }) => WeftMessage(
    eventId: eventId,
    roomId: chatId,
    network: ChatNetwork.matrix,
    senderId: isOwn ? '@me:example.org' : '@priya:example.org',
    senderName: isOwn ? 'You' : 'Priya',
    timestamp: sentAt.subtract(Duration(minutes: minutesAgo)),
    kind: kind,
    isOwn: isOwn,
    body: body,
    attachmentUrl: 'mxc://example.org/$eventId',
    durationMs: durationMs,
    mediaSizeBytes: sizeBytes,
    mediaWidth: width,
    mediaHeight: height,
    deliveryState: delivery,
  );

  UploadTask uploading({
    required String id,
    required String filename,
    required int sizeBytes,
    required UploadState state,
    double progress = 0,
    int attempts = 0,
    String? failure,
  }) => UploadTask(
    id: id,
    roomId: chatId,
    plan:
        planUpload(
              AttachmentSource(
                filename: filename,
                sizeBytes: sizeBytes,
                header: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]),
              ),
              encrypted: false,
              maxUploadBytes: 0,
            )
            as UploadPlan,
    state: state,
    progress: progress,
    attempts: attempts,
    failure: failure,
  );

  /// Pumps the chat and captures it under [name] for both themes.
  ///
  /// Light and dark are one helper rather than two tests because the thing
  /// being compared across them is the *same* tree: a bubble that reads on a
  /// dark surface and vanishes on a light one is the failure mode, and it is
  /// only visible when the two images come from an identical fixture.
  Future<void> expectChatGolden(
    WidgetTester tester,
    String name, {
    List<WeftMessage>? history,
    List<UploadTask>? uploads,
    Uint8List? bytes,
    Size size = const Size(560, 760),
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      final repository = StubChatRepository(
        history: history,
        uploads: uploads,
        bytes: bytes,
      );
      addTearDown(repository.dispose);

      if (bytes != null) await primeImage(tester, MemoryImage(bytes));
      // An upload has no event and therefore no server timestamp, so its echo
      // bubble reads the clock. Fixing it here is what stops the image
      // disagreeing with itself one minute later.
      await withClock(Clock.fixed(sentAt), () async {
        await pumpWeft(
          tester,
          const ChatView(chatId: chatId),
          size: size,
          mode: mode,
          repository: repository,
        );

        await expectLater(
          find.byType(ChatView),
          matchesGoldenFile('${name}_$suffix.png'),
        );
      });
    }
  }

  testWidgets('image bubbles, both themes', (tester) async {
    await expectChatGolden(
      tester,
      'attachment_image',
      bytes: kPhoto,
      // Taller than the others: three 16:9 bubbles do not fit a phone-height
      // frame, and a golden whose top message is sliced by the app bar hides
      // whatever changed up there.
      size: const Size(560, 1040),
      history: [
        message(
          eventId: 'photo_in',
          kind: MessageKind.image,
          body: 'from the harbour this morning',
          minutesAgo: 6,
          width: 400,
          height: 225,
        ),
        // A body that is only a filename is suppressed rather than drawn as a
        // caption, so this bubble must be the picture and nothing else.
        message(
          eventId: 'photo_out',
          kind: MessageKind.image,
          body: 'IMG_4021.HEIC',
          minutesAgo: 3,
          isOwn: true,
          width: 400,
          height: 225,
          delivery: DeliveryState.read,
        ),
        // The play badge over a poster, which is the one thing separating a
        // video from a still at a glance.
        message(
          eventId: 'clip_in',
          kind: MessageKind.video,
          body: 'rail-animation.mp4',
          minutesAgo: 1,
          width: 400,
          height: 225,
        ),
      ],
    );
  });

  testWidgets('file bubbles, both themes', (tester) async {
    await expectChatGolden(
      tester,
      'attachment_file',
      history: [
        message(
          eventId: 'pdf_in',
          kind: MessageKind.file,
          body: 'quarterly-report.pdf',
          minutesAgo: 9,
          sizeBytes: 2 * 1024 * 1024 + 400 * 1024,
        ),
        message(
          eventId: 'zip_out',
          kind: MessageKind.file,
          body: 'design-assets.zip',
          minutesAgo: 6,
          isOwn: true,
          sizeBytes: 18 * 1024 * 1024,
          delivery: DeliveryState.read,
        ),
        // No `info.size`: the second line is absent rather than an invented
        // "0 B", and the golden is where that reads as deliberate.
        message(
          eventId: 'txt_in',
          kind: MessageKind.file,
          body: 'notes.txt',
          minutesAgo: 4,
        ),
        // An audio attachment is a file bubble with a duration and the
        // Transcribe action, not a voice note's waveform.
        message(
          eventId: 'audio_in',
          kind: MessageKind.audio,
          body: 'voicemail.m4a',
          minutesAgo: 2,
          durationMs: 125000,
          sizeBytes: 940 * 1024,
        ),
      ],
    );
  });

  testWidgets('upload-in-progress bubbles, both themes', (tester) async {
    await expectChatGolden(
      tester,
      'attachment_upload',
      history: [
        message(
          eventId: 'settled',
          kind: MessageKind.file,
          body: 'brief.pdf',
          minutesAgo: 12,
          sizeBytes: 320 * 1024,
        ),
      ],
      uploads: [
        // The three states worth an image: a bar that is genuinely partway, the
        // one where a percentage would be a lie, and the dead end with a way
        // back out of it.
        uploading(
          id: 'upload-0',
          filename: 'harbour.jpg',
          sizeBytes: 96000,
          state: UploadState.hashing,
        ),
        uploading(
          id: 'upload-1',
          filename: 'holiday-with-sam.jpg',
          sizeBytes: 4 * 1024 * 1024,
          state: UploadState.uploading,
          progress: 0.42,
          attempts: 1,
        ),
        uploading(
          id: 'upload-2',
          filename: 'the-whole-album.zip',
          sizeBytes: 240 * 1024 * 1024,
          state: UploadState.failed,
          progress: 0.6,
          attempts: 3,
          failure: 'The server will not accept a file this large.',
        ),
      ],
    );
  });

  testWidgets('the pre-send preview sheet, both themes', (tester) async {
    final sources = [
      AttachmentSource(
        filename: '/tmp/harbour.jpg',
        sizeBytes: 96000,
        header: Uint8List.sublistView(kPhoto, 0, 64),
      ),
      AttachmentSource(
        filename: '/tmp/quarterly-report.pdf',
        sizeBytes: 2 * 1024 * 1024 + 400 * 1024,
        header: Uint8List.fromList('%PDF-1.7\n'.codeUnits),
      ),
    ];

    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      final repository = StubChatRepository();
      addTearDown(repository.dispose);
      final chat = (await repository.watchChats().first).firstWhere(
        (c) => c.id == chatId,
      );

      // The tile decodes at `size * 3`, so the primed key must be the
      // `ResizeImage` the widget builds and not the bare `MemoryImage`.
      await primeImage(tester, ResizeImage(MemoryImage(kPhoto), width: 132));
      await pumpWeft(
        tester,
        const Scaffold(body: SizedBox.expand()),
        size: const Size(560, 760),
        mode: mode,
        repository: repository,
        fileReader: (source) async => kPhoto,
      );

      // Shown the way the composer shows it — a modal route over the chat —
      // so the golden carries the scrim and the drag handle too.
      unawaited(
        showAttachmentPreviewSheet(
          tester.element(find.byType(Scaffold)),
          chat: chat,
          sources: sources,
          onPickNetwork: (_) {},
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('attachment_preview_$suffix.png'),
      );
    }
  });
}
