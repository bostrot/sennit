/// The contents of a bubble that carries a file.
///
/// Split out of `chat_view.dart` because "what a photo looks like" and "what a
/// PDF looks like" are different enough to be worth naming, and because the
/// upload bubble has to render the *same* shapes before there is an event to
/// fetch bytes for. Every colour, radius and gap here comes from `weft_design`:
/// a bubble that invents its own padding stops matching the ones above it the
/// first time the scale changes.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/providers.dart';

/// The hero tag joining a bubble's thumbnail to its full-screen self.
///
/// Published here, where the flight starts, so the viewer has one place to read
/// it from and the two cannot drift into two different strings — a hero whose
/// ends disagree does not fail, it simply stops animating, which is the kind of
/// bug nobody files.
///
/// Keyed by room *and* event: a merged conversation draws messages from several
/// rooms at once, and two servers issuing the same event id — unlikely, but
/// nothing forbids it — would make Flutter throw on a duplicate tag.
String mediaHeroTag(WeftMessage message) =>
    'attachment:${message.roomId}/${message.eventId}';

/// Kinds that render as an attachment rather than as their `body` text.
///
/// [MessageKind.voice] is deliberately absent: a voice note has its own bubble
/// with a waveform, and it is a recording rather than a file the user chose.
const Set<MessageKind> kAttachmentKinds = {
  MessageKind.image,
  MessageKind.video,
  MessageKind.sticker,
  MessageKind.audio,
  MessageKind.file,
};

/// Whether [message] should draw an [AttachmentBubble].
///
/// The `attachmentUrl` check is what separates a real `m.file` event from a
/// text message that merely mentions one — `mapEvent` only sets it when the
/// event actually carries a `url` or a `file` block.
bool rendersAsAttachment(WeftMessage message) =>
    message.attachmentUrl != null && kAttachmentKinds.contains(message.kind);

/// The user's caption for an attachment, or null when there is nothing worth
/// showing under it.
///
/// Bridges label a forwarded picture "Forwarded", and a client that predates
/// MSC2530 captions puts the *filename* in `body` — so the naive reading shows
/// `IMG_4021.jpg` under a photo of a dog. Both are noise rather than captions.
/// Lifted out of the old inline heuristic so the file bubble, which shows the
/// name deliberately, does not have to re-derive the same rule backwards.
String? attachmentCaption(WeftMessage message) {
  final caption = message.body.trim();
  if (caption.isEmpty) return null;
  if (caption.toLowerCase() == 'forwarded') return null;
  // A body that is exactly the filename is a filename, not a caption. The same
  // rule the save path uses to decide whether that body is worth writing the
  // file under, so the two cannot disagree about what is a name.
  if (looksLikeFilename(caption)) return null;
  return caption;
}

/// Playback length as `m:ss`, or null when the sender never announced one.
String? formatMediaDuration(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return null;
  final total = Duration(milliseconds: milliseconds);
  final minutes = total.inMinutes;
  final seconds = total.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// The body of a bubble carrying an attachment.
///
/// Dispatches on [WeftMessage.kind] rather than on the mime type: the mapping
/// from `m.image`/`m.video`/`m.audio`/`m.file` to a kind already happened in
/// `weft_matrix`, and re-deciding it here is how the two drift apart.
class AttachmentBubble extends StatelessWidget {
  const AttachmentBubble({
    super.key,
    required this.message,
    required this.own,
    this.onOpen,
    this.transcribing = false,
    this.onTranscribe,
    this.onRetranscribe,
  });

  final WeftMessage message;

  /// Own messages sit on a different bubble colour, so everything drawn on top
  /// of them needs the matching foreground.
  final bool own;

  /// Opens the full-screen viewer. Null until it exists, which is why the
  /// bubble is tappable only when there is somewhere to go.
  final VoidCallback? onOpen;

  final bool transcribing;
  final VoidCallback? onTranscribe;
  final VoidCallback? onRetranscribe;

  @override
  Widget build(BuildContext context) {
    return switch (message.kind) {
      MessageKind.image ||
      MessageKind.video ||
      MessageKind.sticker => MediaAttachment(message: message, onOpen: onOpen),
      MessageKind.audio => _AudioAttachment(
        message: message,
        own: own,
        transcribing: transcribing,
        onTranscribe: onTranscribe,
        onRetranscribe: onRetranscribe,
      ),
      _ => _FileAttachment(message: message, own: own, onOpen: onOpen),
    };
  }
}

/// An image, video poster or sticker, loaded through the repository so an
/// encrypted attachment is decrypted locally before display.
///
/// Without this an image message rendered as its `body` — often just the
/// filename, or "Forwarded" for a forwarded picture — which looked like the
/// picture had been lost.
class MediaAttachment extends ConsumerStatefulWidget {
  const MediaAttachment({super.key, required this.message, this.onOpen});

  final WeftMessage message;
  final VoidCallback? onOpen;

  @override
  ConsumerState<MediaAttachment> createState() => _MediaAttachmentState();
}

class _MediaAttachmentState extends ConsumerState<MediaAttachment> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await ref
        .read(chatRepositoryProvider)
        .attachmentBytes(widget.message.roomId, widget.message.eventId);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final caption = attachmentCaption(widget.message);
    final isVideo = widget.message.kind == MessageKind.video;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: WeftRadius.allSm,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320, minWidth: 140),
            child: Stack(
              alignment: Alignment.center,
              children: [
                GestureDetector(
                  onTap: _bytes == null ? null : widget.onOpen,
                  // The flight the viewer lands: the same decoded bytes on both
                  // ends, so the picture the user tapped is visibly the picture
                  // that fills the screen. Only wrapped once there *are* bytes —
                  // a hero whose source is a grey placeholder animates a grey
                  // box into a photo, which reads as a glitch.
                  child: switch ((_bytes, _failed)) {
                    (final Uint8List bytes, _) => Hero(
                      tag: mediaHeroTag(widget.message),
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            _placeholder(context, broken: true),
                      ),
                    ),
                    (_, true) => _placeholder(context, broken: true),
                    _ => _placeholder(context, broken: false),
                  },
                ),
                // Over the picture rather than under it: a poster with a
                // caption line reading "Video" is indistinguishable from a
                // still at a glance, which is the one thing the badge exists to
                // prevent.
                if (isVideo) const _PlayBadge(),
              ],
            ),
          ),
        ),
        if (caption != null)
          Padding(
            padding: const EdgeInsets.only(top: WeftSpace.xs),
            child: Text(caption, style: context.text.bodyMedium),
          ),
      ],
    );
  }

  /// Reserves the attachment's own shape while the bytes are still coming.
  ///
  /// [WeftMessage.mediaAspectRatio] is used when the sender announced one, so an
  /// encrypted photo does not lay out as a squat grey box and then reflow the
  /// whole timeline under the reader's thumb when it decodes.
  Widget _placeholder(BuildContext context, {required bool broken}) {
    final ratio = widget.message.mediaAspectRatio;
    const width = 220.0;
    final height = ratio == null ? 140.0 : (width / ratio).clamp(90.0, 320.0);

    return Container(
      width: width,
      height: height,
      color: context.colors.surfaceContainerHighest,
      alignment: Alignment.center,
      child: broken
          ? Icon(
              Icons.broken_image_outlined,
              color: context.colors.onSurfaceVariant,
            )
          : const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }
}

/// The play affordance on a video poster.
///
/// Its own scrim disc rather than a bare icon: a white glyph vanishes on a
/// bright frame and a dark one vanishes on a night shot.
class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: context.colors.scrim.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.play_arrow_rounded,
          size: 30,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// A sound file that is not a voice note: a song, a forwarded clip, an export.
///
/// Rendered as a file with a duration rather than as a waveform — the waveform
/// belongs to voice notes, where it says "someone spoke for this long". The
/// Transcribe action is carried over unchanged, because `canTranscribe` has
/// always covered [MessageKind.audio] and the only reason an audio attachment
/// never offered it is that it used to fall through to plain text.
class _AudioAttachment extends StatelessWidget {
  const _AudioAttachment({
    required this.message,
    required this.own,
    required this.transcribing,
    this.onTranscribe,
    this.onRetranscribe,
  });

  final WeftMessage message;
  final bool own;
  final bool transcribing;
  final VoidCallback? onTranscribe;
  final VoidCallback? onRetranscribe;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final duration = formatMediaDuration(message.durationMs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AttachmentGlyph(icon: Icons.audiotrack_rounded, tint: onBubble),
            const SizedBox(width: WeftSpace.sm),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.body.isEmpty ? 'Audio' : message.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyMedium?.copyWith(
                      color: onBubble,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (duration != null)
                    Text(
                      duration,
                      style: context.text.labelSmall?.copyWith(
                        color: onBubble.withValues(alpha: 0.7),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        AttachmentTranscript(
          message: message,
          own: own,
          transcribing: transcribing,
          onTranscribe: onTranscribe,
          onRetranscribe: onRetranscribe,
        ),
      ],
    );
  }
}

/// Anything with no better rendering: a PDF, an archive, a spreadsheet.
class _FileAttachment extends StatelessWidget {
  const _FileAttachment({
    required this.message,
    required this.own,
    this.onOpen,
  });

  final WeftMessage message;
  final bool own;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final bytes = message.mediaSizeBytes;
    final size = bytes == null ? null : formatAttachmentSize(bytes);

    return InkWell(
      onTap: onOpen,
      borderRadius: WeftRadius.allSm,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AttachmentGlyph(icon: _iconFor(message.body), tint: onBubble),
          const SizedBox(width: WeftSpace.sm),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.body.isEmpty ? 'File' : message.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodyMedium?.copyWith(
                    color: onBubble,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                // No size line at all when the sender omitted `info.size`: an
                // invented "0 B" reads as a broken file rather than as a
                // missing field.
                if (size != null)
                  Text(
                    size,
                    style: context.text.labelSmall?.copyWith(
                      color: onBubble.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Extension-driven glyph. Deliberately coarse — a handful of families the
  /// user recognises at a glance beats a long table nobody reads.
  static IconData _iconFor(String filename) {
    final dot = filename.lastIndexOf('.');
    final extension = dot <= 0
        ? ''
        : filename.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'pdf' => Icons.picture_as_pdf_rounded,
      'zip' || 'gz' || 'tar' || '7z' || 'rar' => Icons.folder_zip_rounded,
      'doc' || 'docx' || 'odt' || 'rtf' || 'txt' || 'md' =>
        Icons.description_rounded,
      'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_rounded,
      'ppt' || 'pptx' || 'odp' => Icons.slideshow_rounded,
      'apk' || 'exe' || 'dmg' || 'deb' => Icons.terminal_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }
}

/// A file bubble's leading icon on its own tinted disc.
class _AttachmentGlyph extends StatelessWidget {
  const _AttachmentGlyph({required this.icon, required this.tint});

  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: WeftRadius.allSm,
      ),
      child: Icon(icon, size: 20, color: tint.withValues(alpha: 0.9)),
    );
  }
}

/// The Transcribe affordance and, once there is one, the transcript.
///
/// Shared by the voice bubble and the audio attachment rather than written
/// twice: they offer the same action against the same `canTranscribe` rule, and
/// a copy would have drifted the moment either gained a state.
class AttachmentTranscript extends StatelessWidget {
  const AttachmentTranscript({
    super.key,
    required this.message,
    required this.own,
    required this.transcribing,
    this.onTranscribe,
    this.onRetranscribe,
  });

  final WeftMessage message;
  final bool own;
  final bool transcribing;
  final VoidCallback? onTranscribe;

  /// Long-press action on an existing transcript.
  final VoidCallback? onRetranscribe;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final transcript = message.transcript;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (transcribing)
          Padding(
            padding: const EdgeInsets.only(top: WeftSpace.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: onBubble.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(width: WeftSpace.sm),
                Text(
                  'Transcribing…',
                  style: context.text.labelSmall?.copyWith(
                    color: onBubble.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          )
        else if (transcript == null && onTranscribe != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onTranscribe,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
              ),
              icon: Icon(
                Icons.graphic_eq_rounded,
                size: 14,
                color: onBubble.withValues(alpha: 0.8),
              ),
              label: Text(
                'Transcribe',
                style: context.text.labelSmall?.copyWith(
                  color: onBubble.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        if (transcript != null) ...[
          const SizedBox(height: WeftSpace.sm),
          GestureDetector(
            onLongPress: onRetranscribe,
            child: Container(
              padding: const EdgeInsets.all(WeftSpace.sm),
              decoration: BoxDecoration(
                color: onBubble.withValues(alpha: 0.08),
                borderRadius: WeftRadius.allSm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 13,
                    color: onBubble.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: WeftSpace.xs),
                  Flexible(
                    child: Text(
                      transcript,
                      style: context.text.bodySmall?.copyWith(
                        color: onBubble.withValues(alpha: 0.9),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// An attachment the user has picked but the homeserver has not accepted yet.
///
/// Drawn from the [UploadTask] rather than from a message because there is no
/// message: no event id, nothing to fetch bytes for, and a real chance the
/// whole thing fails. What it owes the user is the two facts a spinner cannot
/// give — *how far* this is, and *a way out* — so the bar is determinate and the
/// cancel button is present from the first frame rather than appearing once the
/// upload is far enough along to be worth abandoning.
class UploadProgressBubble extends StatelessWidget {
  const UploadProgressBubble({
    super.key,
    required this.task,
    required this.own,
    required this.onCancel,
    required this.onRetry,
  });

  final UploadTask task;
  final bool own;

  /// Abandons the upload. Also the way a failed one is dismissed: the task is
  /// already terminal, so there is nothing left to stop, only something to
  /// clear off the timeline.
  final VoidCallback onCancel;

  /// Tries again with a fresh attempt budget. Only offered when the queue says
  /// the task can actually be retried.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final failed = task.state == UploadState.failed;
    final plan = task.plan;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AttachmentGlyph(
              icon: failed
                  ? Icons.error_outline_rounded
                  : _kindIcon(plan.kind),
              tint: failed ? context.colors.error : onBubble,
            ),
            const SizedBox(width: WeftSpace.sm),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    plan.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyMedium?.copyWith(
                      color: onBubble,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _statusLine(context, task),
                    style: context.text.labelSmall?.copyWith(
                      color: failed
                          ? context.colors.error
                          : onBubble.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: WeftSpace.sm),
            IconButton(
              onPressed: onCancel,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: failed ? 'Discard' : 'Cancel upload',
              icon: Icon(
                Icons.close_rounded,
                color: onBubble.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
        // Determinate on purpose. An indeterminate bar over an upload whose
        // byte count is known says less than nothing: it is the state a stalled
        // 200 MB video and a finished one look identical in.
        Padding(
          padding: const EdgeInsets.only(top: WeftSpace.xs),
          child: ClipRRect(
            borderRadius: WeftRadius.pill,
            child: LinearProgressIndicator(
              value: task.progress.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: onBubble.withValues(alpha: 0.15),
              color: failed ? context.colors.error : context.colors.primary,
            ),
          ),
        ),
        if (task.canRetry)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('Retry'),
            ),
          ),
      ],
    );
  }

  /// One line saying what is happening, in the user's terms.
  ///
  /// A percentage only while there is one to report: `hashing` is reading and
  /// encrypting the file, which can take a visible moment on a large video and
  /// during which "0%" would look like a stall.
  static String _statusLine(BuildContext context, UploadTask task) {
    final size = formatAttachmentSize(task.plan.sizeBytes);
    return switch (task.state) {
      UploadState.queued => 'Waiting · $size',
      UploadState.hashing => 'Preparing · $size',
      UploadState.uploading => '${(task.progress * 100).round()}% of $size',
      UploadState.retrying => 'Retrying · attempt ${task.attempts + 1}',
      UploadState.sent => 'Sending…',
      UploadState.cancelled => 'Cancelled',
      UploadState.failed => task.failure ?? 'Upload failed',
    };
  }

  static IconData _kindIcon(MessageKind kind) => switch (kind) {
    MessageKind.image || MessageKind.sticker => Icons.image_rounded,
    MessageKind.video => Icons.movie_rounded,
    MessageKind.audio || MessageKind.voice => Icons.audiotrack_rounded,
    _ => Icons.insert_drive_file_rounded,
  };
}
