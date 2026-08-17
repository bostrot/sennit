import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft_attachments/weft_attachments.dart';

/// The send half of [ChatRepository], as it stands before the transport lands.
///
/// These tests exist to pin the *shape* of the contract, not its behaviour: the
/// four members are declared, `weft_attachments` types cross the boundary, and
/// the demo repository still satisfies the widened interface. The
/// `UnimplementedError` expectations are deliberately load-bearing — they are
/// what fails, loudly, the moment the real send path is wired, which is the
/// point at which they get rewritten into behavioural tests.
void main() {
  final source = AttachmentSource(
    filename: 'holiday.jpg',
    sizeBytes: 2048,
    header: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]),
  );

  group('ChatRepository send-path contract', () {
    test('the demo repository still satisfies the widened interface', () {
      final ChatRepository repository = DemoChatRepository();
      expect(repository, isA<ChatRepository>());
    });

    test('watching uploads for a chat with none yields nothing', () async {
      final repository = DemoChatRepository();

      // No upload can be started yet, so an empty stream is the truthful
      // answer rather than a stub: the timeline renders no pending bubbles.
      expect(await repository.watchUploads('chat_0').toList(), isEmpty);
    });

    test('sending an attachment reports that it is not wired yet', () {
      final repository = DemoChatRepository();

      // Never a silent success: a send that quietly did nothing would lose the
      // user's file with no trace anywhere in the UI.
      expect(
        () => repository.sendAttachment('chat_0', source),
        throwsUnimplementedError,
      );
    });

    test('retry and cancel take a task id, not a chat id', () {
      final repository = DemoChatRepository();

      expect(
        () => repository.retryUpload('upload-1'),
        throwsUnimplementedError,
      );
      expect(
        () => repository.cancelUpload('upload-1'),
        throwsUnimplementedError,
      );
    });
  });
}
