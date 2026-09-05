import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import '../../app/localisation.dart';

import '../../app/providers.dart';
import 'send_network_chip.dart';

/// Largest file the preview will decode to show a thumbnail.
///
/// The preview reads the whole file, which is the one place in the send path
/// that does — everything else works from a 64 KiB header. Worth it for the
/// photo the user is about to send and is checking they picked the right one;
/// not worth it for a 60 MP RAW, which gets its icon instead.
const int kPreviewDecodeMaxBytes = 12 * 1024 * 1024;

/// What the user confirmed in the preview sheet: the files, and the words.
///
/// A record rather than a bare list because the caption cannot be recovered
/// afterwards — the sheet is gone by the time the caller sends, and a second
/// out-parameter threaded through `showWeftPanel`'s `Future` is not a thing
/// there is a way to spell.
typedef ConfirmedAttachments = ({
  List<AttachmentSource> sources,
  String? caption,
});

/// Confirms what is about to be sent, with what caption, and to which network.
///
/// Between the picker and the send because a picker gives no second chance:
/// once `sendAttachment` is called the file is in the room, and "I picked the
/// wrong photo" is then a redaction rather than a tap. Returns what the user
/// kept, or null if they backed out — an empty source list is impossible, since
/// removing the last file closes the sheet as a cancellation.
Future<ConfirmedAttachments?> showAttachmentPreviewSheet(
  BuildContext context, {
  required Chat chat,
  required List<AttachmentSource> sources,
  required ValueChanged<ChatNetwork> onPickNetwork,
}) {
  return showWeftPanel<ConfirmedAttachments>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _AttachmentPreviewSheet(
      chat: chat,
      sources: sources,
      onPickNetwork: onPickNetwork,
    ),
  );
}

class _AttachmentPreviewSheet extends ConsumerStatefulWidget {
  const _AttachmentPreviewSheet({
    required this.chat,
    required this.sources,
    required this.onPickNetwork,
  });

  final Chat chat;
  final List<AttachmentSource> sources;
  final ValueChanged<ChatNetwork> onPickNetwork;

  @override
  ConsumerState<_AttachmentPreviewSheet> createState() =>
      _AttachmentPreviewSheetState();
}

class _AttachmentPreviewSheetState
    extends ConsumerState<_AttachmentPreviewSheet> {
  late final List<AttachmentSource> _kept = [...widget.sources];
  final TextEditingController _caption = TextEditingController();

  /// Focused on desktop and pointedly *not* on a phone.
  ///
  /// On a desktop the sheet has already taken the window and there is a real
  /// keyboard under the user's hands: landing in the field means a caption is
  /// one sentence and Enter away. On a phone the same autofocus raises the soft
  /// keyboard over the file list — the half of the sheet the user opened it to
  /// look at — before they have decided whether they want to write anything at
  /// all, and dismissing it is a second gesture to get back to where they were.
  final FocusNode _captionFocus = FocusNode();

  @override
  void dispose() {
    _caption.dispose();
    _captionFocus.dispose();
    super.dispose();
  }

  void _remove(AttachmentSource source) {
    setState(() => _kept.remove(source));
    // Nothing left to send is the same decision as "cancel", and leaving an
    // empty sheet up with a dead Send button makes the user find the drag
    // handle to say what they have already said.
    if (_kept.isEmpty) Navigator.of(context).pop();
  }

  /// Hands back the files and the caption, trimmed to null when it is blank.
  ///
  /// Normalised here as well as in `planUpload` because this is where the
  /// question "did the user write a caption?" is actually asked — a field
  /// holding two spaces has to leave through this sheet as "no caption", not as
  /// a string that is only later found to be empty.
  void _send() {
    final caption = _caption.text.trim();
    Navigator.of(context).pop((
      sources: List<AttachmentSource>.unmodifiable(_kept),
      caption: caption.isEmpty ? null : caption,
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Read live rather than from the captured chat: picking a network in the
    // chip writes through the repository, and the sheet has to show the change
    // it just made.
    final chat =
        ref
            .watch(chatsProvider)
            .value
            ?.where((c) => c.id == widget.chat.id)
            .firstOrNull ??
        widget.chat;
    final sendNetwork = chat.sendNetwork;
    final total = _kept.fold(0, (sum, s) => sum + s.sizeBytes);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: WeftSpace.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.attachmentPreviewSendCount(_kept.length),
                  style: context.text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: WeftSpace.xxs),
                Text(
                  context.l10n.attachmentPreviewSizeTo(
                    formatAttachmentSize(total),
                    chat.title,
                  ),
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          Expanded(
            child: ListView.builder(
              controller: controller,
              padding: const EdgeInsets.symmetric(horizontal: WeftSpace.md),
              itemCount: _kept.length,
              itemBuilder: (context, i) => _PickedFileTile(
                source: _kept[i],
                onRemove: () => _remove(_kept[i]),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsetsDirectional.fromSTEB(
              WeftSpace.lg,
              WeftSpace.sm,
              WeftSpace.lg,
              WeftSpace.md,
            ),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: context.palette.border)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Above the buttons, not above the file list: the caption is
                  // the last thing decided before Send, and a field at the top
                  // of a scrolling sheet scrolls away exactly when the soft
                  // keyboard opens over it.
                  TextField(
                    controller: _caption,
                    focusNode: _captionFocus,
                    autofocus: context.isDesktop,
                    minLines: 1,
                    maxLines: 4,
                    // Newline rather than a send action. The Send button is two
                    // centimetres below and unambiguous; an Enter that fired the
                    // send would make a two-line caption impossible to write.
                    textInputAction: TextInputAction.newline,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: context.l10n.attachmentPreviewCaption,
                      hintText: context.l10n.attachmentPreviewCaptionHint(
                        _kept.length,
                      ),
                    ),
                  ),
                  const SizedBox(height: WeftSpace.sm),
                  Row(
                    children: [
                      // The same chip the composer shows, driven by the same
                      // setter: a merged chat must not send its photos
                      // somewhere other than where its text goes.
                      if (chat.isMerged && sendNetwork != null) ...[
                        SendNetworkChip(
                          chat: chat,
                          current: sendNetwork,
                          onPick: widget.onPickNetwork,
                        ),
                        const SizedBox(width: WeftSpace.sm),
                        Expanded(
                          child: Text(
                            context.l10n.attachmentPreviewVia(
                              sendNetwork.label,
                            ),
                            style: context.text.labelMedium?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ] else
                        const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(context.l10n.commonCancel),
                      ),
                      const SizedBox(width: WeftSpace.sm),
                      FilledButton.icon(
                        onPressed: _send,
                        icon: const Icon(Icons.send_rounded, size: 18),
                        label: Text(context.l10n.commonSend),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One picked file: what it is, how big, and a way to drop it.
class _PickedFileTile extends StatelessWidget {
  const _PickedFileTile({required this.source, required this.onRemove});

  final AttachmentSource source;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    // The same sniff the plan will run, so the icon in the preview and the kind
    // of the bubble that follows cannot disagree.
    final kind = messageKindFor(sniffMimeType(source));

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: WeftSpace.sm),
      leading: AttachmentSourceThumbnail(source: source, kind: kind),
      title: Text(
        source.basename,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(formatAttachmentSize(source.sizeBytes)),
      // Named: a preview of eight files is eight identical "Remove" buttons,
      // and which one a reader is on is exactly what they cannot see.
      trailing: IconButton(
        tooltip: context.l10n.attachmentPreviewRemove(source.basename),
        icon: const Icon(Icons.close_rounded),
        onPressed: onRemove,
      ),
    );
  }
}

/// A real thumbnail for a picked image, an icon for everything else.
///
/// Images are decoded from the file itself rather than from
/// [AttachmentSource.header]: a 64 KiB slice of a JPEG is a *truncated* JPEG,
/// which decodes to a grey band or to nothing at all depending on the platform
/// codec — the one thing worse than no preview is a preview that looks like the
/// file is corrupt.
///
/// Public because a share intent's files are previewed too, and "what a picked
/// file looks like before it is sent" must not be answered twice: the share
/// sheet shows a strip of these at [size] 64 above the conversation list.
class AttachmentSourceThumbnail extends ConsumerStatefulWidget {
  const AttachmentSourceThumbnail({
    super.key,
    required this.source,
    required this.kind,
    this.size = 44,
  });

  final AttachmentSource source;
  final MessageKind kind;

  /// Edge length of the square. The decode resolution follows it, so a bigger
  /// tile is not a bigger upscale of the same pixels.
  final double size;

  @override
  ConsumerState<AttachmentSourceThumbnail> createState() =>
      _PreviewThumbnailState();
}

class _PreviewThumbnailState extends ConsumerState<AttachmentSourceThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    if (widget.kind == MessageKind.image &&
        widget.source.sizeBytes <= kPreviewDecodeMaxBytes) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final bytes = await ref.read(attachmentFileReaderProvider)(widget.source);
      if (!mounted) return;
      setState(() => _bytes = bytes);
    } on Object {
      // A file that has gone between the picker and the sheet still has a name
      // and a size worth showing; the send will report the real failure.
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final iconSize = widget.size * 0.45;
    // The row beside this tile already names the file and its size, and the
    // thumbnail is that same file drawn small. Excluded rather than labelled:
    // a second announcement of the same name is noise, and there is nothing
    // here anyone can describe beyond it.
    return ExcludeSemantics(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: ClipRRect(
          borderRadius: WeftRadius.allSm,
          child: bytes == null
              ? Container(
                  color: context.colors.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Icon(
                    _iconFor(widget.kind),
                    size: iconSize,
                    color: context.colors.onSurfaceVariant,
                  ),
                )
              // `cacheWidth` decodes at thumbnail resolution: a row of eight
              // 12 MP photos otherwise holds half a gigabyte of ARGB in the
              // image cache for a 44pt square.
              : Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  cacheWidth: (widget.size * 3).round(),
                  errorBuilder: (_, _, _) => Container(
                    color: context.colors.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.broken_image_outlined,
                      size: iconSize,
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  static IconData _iconFor(MessageKind kind) => switch (kind) {
    MessageKind.image || MessageKind.sticker => Icons.image_rounded,
    MessageKind.video => Icons.movie_rounded,
    MessageKind.audio || MessageKind.voice => Icons.audiotrack_rounded,
    _ => Icons.insert_drive_file_rounded,
  };
}
