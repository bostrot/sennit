import 'package:flutter/foundation.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
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
///
/// [caption] goes on the **first** attachment only, and that is a choice worth
/// naming. One field above a strip of eight photos is one sentence about the
/// batch, not eight copies of it: repeated on every file it arrives as the same
/// words shouted eight times, and dropped onto the last it reads as a caption on
/// whichever picture happened to finish first. The leading item is where every
/// other messenger puts an album's caption, and it is the one the batch is read
/// from top to bottom against.
Future<List<String>> sendAttachments(
  AppL10n l10n,
  ChatRepository repository,
  String chatId,
  List<AttachmentSource> sources, {
  ChatNetwork? via,
  bool isVoiceNote = false,
  int? durationMs,
  String? caption,
}) async {
  final problems = <String>[];

  // Indexed rather than a `for-in` with an identity check: picking the same
  // file twice from the system picker is legal, and two entries that are the
  // same object would then both be "the first".
  for (var i = 0; i < sources.length; i++) {
    final source = sources[i];
    try {
      await repository.sendAttachment(
        chatId,
        source,
        via: via,
        isVoiceNote: isVoiceNote,
        durationMs: durationMs,
        caption: i == 0 ? caption : null,
      );
    } on AttachmentRejectedException catch (e) {
      problems.add(
        l10n.attachmentProblem(
          source.basename,
          l10n.attachmentRejection(e.rejection),
        ),
      );
    } on Object catch (error) {
      // Deliberately Object: below here is a homeserver, a socket and a file
      // that may have gone away, and the user's answer is the same for all of
      // them. One file failing must not abandon the rest of the batch.
      debugPrint('weft: attachment ${source.basename} failed to send: $error');
      problems.add(l10n.attachmentSendFailed(source.basename));
    }
  }

  return problems;
}
