import 'package:flutter/foundation.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../data/chat_repository.dart';

/// Sends every file in [sources], returning the sentences the user needs to see.
///
/// Extracted from the composer the moment a second caller appeared: a share
/// intent sends the same list to the same repository and has the same two things
/// to get right, so a copy would have been a copy of the reasoning below rather
/// than of four lines.
///
/// Awaited in series, which costs nothing — `sendAttachment` returns on
/// *acceptance*, so twenty photos are twenty enqueues rather than twenty
/// uploads — and it is enqueuing in order that puts a batch into the room in the
/// order the user picked it.
///
/// Returns an empty list when everything was accepted. A returned sentence is
/// already user-facing: a rejection is not retryable and never becomes a bubble,
/// so the caller shows it as-is rather than leaving a progress bar the user could
/// only dismiss.
Future<List<String>> sendAttachments(
  ChatRepository repository,
  String chatId,
  List<AttachmentSource> sources, {
  ChatNetwork? via,
  bool isVoiceNote = false,
  int? durationMs,
}) async {
  final problems = <String>[];

  for (final source in sources) {
    try {
      await repository.sendAttachment(
        chatId,
        source,
        via: via,
        isVoiceNote: isVoiceNote,
        durationMs: durationMs,
      );
    } on AttachmentRejectedException catch (e) {
      problems.add('${source.basename}: ${e.message}');
    } on Object catch (error) {
      // Deliberately Object: below here is a homeserver, a socket and a file
      // that may have gone away, and the user's answer is the same for all of
      // them. One file failing must not abandon the rest of the batch.
      debugPrint('weft: attachment ${source.basename} failed to send: $error');
      problems.add('${source.basename} could not be sent.');
    }
  }

  return problems;
}
