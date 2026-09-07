import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/attachment_preview_sheet.dart';
import 'package:weft_attachments/weft_attachments.dart';

import 'support/attachment_fixtures.dart';
import 'support/golden_harness.dart';

/// The caption on a photo, and the keyboard that was drawn over it.
///
/// The preview sheet puts the caption field and Send in its last rows, and a
/// modal bottom sheet is laid out over the whole screen — so tapping the field
/// raised the keyboard across both of them and the user typed a caption they
/// could not see. Asserted in pixels against the phone-sized view, because
/// nothing about the widget tree was ever wrong.
void main() {
  const chatId = '!design_room:example.org';
  const screen = Size(400, 800);
  const keyboard = 300.0;

  final sources = [
    AttachmentSource(
      filename: '/tmp/harbour.jpg',
      sizeBytes: 96000,
      header: Uint8List.sublistView(kPhoto, 0, 64),
    ),
  ];

  /// Opens the sheet over an empty scaffold, the way the composer opens it.
  Future<void> openPreview(WidgetTester tester) async {
    final repository = DemoChatRepository(uploadTick: Duration.zero);
    addTearDown(repository.dispose);
    final chat = (await repository.watchChats().first).firstWhere(
      (c) => c.id == chatId,
    );

    await pumpWeft(
      tester,
      const Scaffold(body: SizedBox.expand()),
      size: screen,
      repository: repository,
      fileReader: (source) async => kPhoto,
    );

    unawaited(
      showAttachmentPreviewSheet(
        tester.element(find.byType(Scaffold)),
        chat: chat,
        sources: sources,
        onPickNetwork: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => tester.view.reset());
  }

  Rect caption(WidgetTester tester) => tester.getRect(find.byType(TextField));
  Rect send(WidgetTester tester) =>
      tester.getRect(find.byIcon(Icons.send_rounded));

  testWidgets('the caption and Send sit above the raised keyboard', (
    tester,
  ) async {
    await openPreview(tester);
    expect(caption(tester).bottom, greaterThan(screen.height - keyboard));

    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    await tester.pumpAndSettle();

    expect(caption(tester).bottom, lessThanOrEqualTo(screen.height - keyboard));
    expect(send(tester).bottom, lessThanOrEqualTo(screen.height - keyboard));
    // The file being captioned is still on screen: a sheet that saved the
    // caption by hiding the photo would have answered the wrong question.
    expect(find.text('harbour.jpg'), findsOneWidget);
    expect(
      tester.getRect(find.text('harbour.jpg')).bottom,
      lessThanOrEqualTo(screen.height - keyboard),
    );
  });

  testWidgets('the sheet is put back when the keyboard is dismissed', (
    tester,
  ) async {
    await openPreview(tester);
    final before = caption(tester);

    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();

    expect(caption(tester), before);
  });
}
