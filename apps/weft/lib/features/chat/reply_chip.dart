import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// The quoted context above a reply, as one tappable line.
///
/// Two states, and the second is the reason this is a widget rather than a
/// `Text`. A [ReplyPreview.stub] is a reply whose target has not been paginated
/// in yet: the chip still renders, still says it is answering something, and is
/// still tappable — because tapping it is how the timeline is told to go and
/// fetch the thing. An answer with no visible question is a worse lie than an
/// answer above a greyed-out "message not loaded".
class ReplyChip extends StatelessWidget {
  const ReplyChip({
    super.key,
    required this.preview,
    required this.own,
    this.onTap,
    this.compact = false,
  });

  final ReplyPreview preview;

  /// Whether the chip sits inside the user's own bubble, which decides which
  /// text colour it has to stay readable against.
  final bool own;

  final VoidCallback? onTap;

  /// The composer's context bar, which sits on the app surface rather than
  /// inside a bubble and has room for two full lines.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = own ? palette.ownBubbleText : palette.peerBubbleText;
    // The rule down the left takes the network's colour when the target is on a
    // known leg — in a merged chat that is the answer to "which app was this
    // said on?", which the reply itself may not share.
    final accent = preview.network == null
        ? ink.withValues(alpha: 0.45)
        : palette.networkColor(preview.network!);

    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.xs),
      child: Material(
        color: ink.withValues(alpha: 0.10),
        borderRadius: WeftRadius.allSm,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(maxWidth: compact ? 640 : 496),
            padding: const EdgeInsets.fromLTRB(
              WeftSpace.sm,
              WeftSpace.xs,
              WeftSpace.sm,
              WeftSpace.xs,
            ),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: accent, width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview.network != null) ...[
                      NetworkGlyph(network: preview.network!, size: 11),
                      const SizedBox(width: WeftSpace.xs),
                    ],
                    Flexible(
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.labelSmall?.copyWith(
                          color: preview.isStub
                              ? ink.withValues(alpha: 0.6)
                              : accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  _body,
                  maxLines: compact ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall?.copyWith(
                    color: ink.withValues(alpha: preview.isStub ? 0.55 : 0.8),
                    fontStyle: _placeholder ? FontStyle.italic : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _title {
    if (preview.isStub) return 'Replying to a message';
    return preview.senderName?.trim().isNotEmpty ?? false
        ? preview.senderName!
        : preview.senderId ?? 'Unknown';
  }

  /// Whether the body line is stand-in text rather than the sender's words, so
  /// it can be set in italics and never be mistaken for something they wrote.
  bool get _placeholder => _body != preview.body;

  String get _body {
    if (preview.isStub) return 'Not loaded yet — tap to find it';
    if (preview.redacted) return 'Message deleted';
    if (preview.body.isNotEmpty) return preview.body;
    return switch (preview.kind) {
      MessageKind.image => 'Photo',
      MessageKind.video => 'Video',
      MessageKind.voice => 'Voice message',
      MessageKind.audio => 'Audio',
      MessageKind.file => 'File',
      MessageKind.sticker => 'Sticker',
      MessageKind.location => 'Location',
      MessageKind.poll => 'Poll',
      _ => 'Message',
    };
  }
}
