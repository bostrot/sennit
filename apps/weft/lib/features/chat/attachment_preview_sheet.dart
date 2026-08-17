import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/providers.dart';
import 'attachment_bubble.dart';
import 'send_network_chip.dart';

/// Largest file the preview will decode to show a thumbnail.
///
/// The preview reads the whole file, which is the one place in the send path
/// that does — everything else works from a 64 KiB header. Worth it for the
/// photo the user is about to send and is checking they picked the right one;
/// not worth it for a 60 MP RAW, which gets its icon instead.
const int kPreviewDecodeMaxBytes = 12 * 1024 * 1024;

/// Confirms what is about to be sent, and to which network.
///
/// Between the picker and the send because a picker gives no second chance:
/// once `sendAttachment` is called the file is in the room, and "I picked the
/// wrong photo" is then a redaction rather than a tap. Returns the files the
/// user kept, or null if they backed out — an empty list is impossible, since
/// removing the last file closes the sheet as a cancellation.
Future<List<AttachmentSource>?> showAttachmentPreviewSheet(
  BuildContext context, {
  required Chat chat,
  required List<AttachmentSource> sources,
  required ValueChanged<ChatNetwork> onPickNetwork,
}) {
  return showModalBottomSheet<List<AttachmentSource>>(
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

  void _remove(AttachmentSource source) {
    setState(() => _kept.remove(source));
    // Nothing left to send is the same decision as "cancel", and leaving an
    // empty sheet up with a dead Send button makes the user find the drag
    // handle to say what they have already said.
    if (_kept.isEmpty) Navigator.of(context).pop();
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
                  _kept.length == 1
                      ? 'Send 1 file'
                      : 'Send ${_kept.length} files',
                  style: context.text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: WeftSpace.xxs),
                Text(
                  '${formatAttachmentSize(total)} to ${chat.title}',
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
            padding: const EdgeInsets.fromLTRB(
              WeftSpace.lg,
              WeftSpace.sm,
              WeftSpace.lg,
              WeftSpace.md,
            ),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: context.palette.divider)),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  // The same chip the composer shows, driven by the same
                  // setter: a merged chat must not send its photos somewhere
                  // other than where its text goes.
                  if (chat.isMerged && sendNetwork != null) ...[
                    SendNetworkChip(
                      chat: chat,
                      current: sendNetwork,
                      onPick: widget.onPickNetwork,
                    ),
                    const SizedBox(width: WeftSpace.sm),
                    Expanded(
                      child: Text(
                        'via ${sendNetwork.label}',
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
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: WeftSpace.sm),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(_kept),
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text('Send'),
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
      leading: _PreviewThumbnail(source: source, kind: kind),
      title: Text(
        source.basename,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(formatAttachmentSize(source.sizeBytes)),
      trailing: IconButton(
        tooltip: 'Remove',
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
class _PreviewThumbnail extends ConsumerStatefulWidget {
  const _PreviewThumbnail({required this.source, required this.kind});

  final AttachmentSource source;
  final MessageKind kind;

  @override
  ConsumerState<_PreviewThumbnail> createState() => _PreviewThumbnailState();
}

class _PreviewThumbnailState extends ConsumerState<_PreviewThumbnail> {
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
      final bytes = await ref.read(attachmentFileReaderProvider)(
        widget.source,
      );
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
    return SizedBox(
      width: 44,
      height: 44,
      child: ClipRRect(
        borderRadius: WeftRadius.allSm,
        child: bytes == null
            ? Container(
                color: context.colors.surfaceContainerHighest,
                alignment: Alignment.center,
                child: Icon(
                  _iconFor(widget.kind),
                  size: 20,
                  color: context.colors.onSurfaceVariant,
                ),
              )
            // `cacheWidth` decodes at thumbnail resolution: a row of eight
            // 12 MP photos otherwise holds half a gigabyte of ARGB in the
            // image cache for a 44pt square.
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                cacheWidth: 132,
                errorBuilder: (_, _, _) => Container(
                  color: context.colors.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: 20,
                    color: context.colors.onSurfaceVariant,
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
