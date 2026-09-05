import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/localisation.dart';

/// The way into a thread, drawn under the message it hangs off.
///
/// This is the whole of what the flat timeline shows for a thread: a name, a
/// count, and one line of the newest reply. The replies themselves are not here
/// and deliberately not loaded — a Telegram forum group has forty topics on one
/// screen, and forty sub-conversations held in memory to draw forty single
/// lines is the difference between a chat that opens and one that does not.
///
/// A row rather than a chip, and the width is the reason. A chip sized to its
/// contents makes "Bugs · 2 replies" and "Wednesday's release, if the CI ever
/// goes green · 14 replies" two very different shapes stacked one above the
/// other, and the eye reads the ragged edge as disorder rather than as two
/// topics.
class ThreadIndicator extends StatelessWidget {
  const ThreadIndicator({
    super.key,
    required this.thread,
    required this.own,
    this.onOpen,
  });

  final ThreadSummary thread;

  /// Which side of the conversation the root sits on, so the indicator lines up
  /// under the bubble rather than floating in the middle of the column.
  final bool own;

  /// Opens the thread. Null in a preview, where nothing on a message acts.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final latest = thread.latestReply;
    final title = thread.title;

    // The count is the one thing always worth saying, and it is said first
    // because it is what the eye is looking for. The name follows it when there
    // is one — a Matrix thread has no name and falls back to the root's own
    // words, which are already in the bubble directly above, so repeating them
    // in the indicator would be the same sentence twice.
    final count = l10n.threadReplyCount(thread.replyCount);
    final preview = latest == null
        ? null
        : l10n.threadLatestReply(latest.senderName, replyPreviewOf(latest));

    return Align(
      alignment: own
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: WeftFocusable(
        button: onOpen != null,
        onTap: onOpen,
        // One sentence for the whole row. The parts are a count, a name and a
        // quotation, and read as three separate nodes they arrive as fragments
        // with no grammar between them.
        label: semanticsSentence([
          l10n.threadOpen,
          title,
          count,
          if (thread.hasUnread) l10n.threadUnreadCount(thread.unreadCount),
          preview,
        ]),
        borderRadius: WeftRadius.allSm,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(
            horizontal: WeftSpace.sm,
            vertical: WeftSpace.xs,
          ),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHigh,
            borderRadius: WeftRadius.allSm,
            // A leading rule rather than a border all the way round: the row is
            // a continuation of the message above it, and a fully-boxed card
            // reads as a separate thing that happens to be nearby.
            border: BorderDirectional(
              start: BorderSide(color: context.colors.primary, width: 2),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.forum_outlined,
                    size: 14,
                    color: context.colors.primary,
                  ),
                  const SizedBox(width: WeftSpace.xs),
                  Flexible(
                    child: Text(
                      title == null ? count : '$title · $count',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.labelMedium?.copyWith(
                        color: context.colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (thread.hasUnread) ...[
                    const SizedBox(width: WeftSpace.xs),
                    _UnreadDot(count: thread.unreadCount),
                  ],
                ],
              ),
              if (preview != null)
                Padding(
                  padding: const EdgeInsets.only(top: WeftSpace.xxs),
                  child: Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // Measured against the container the row actually paints,
                    // not against the scaffold behind it: the tint is what is
                    // under this line.
                    style: context.text.bodySmall?.copyWith(
                      color: palette.muted(
                        context.colors.onSurface,
                        context.colors.surfaceContainerHigh,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line of a thread's newest reply.
///
/// An attachment says nothing in words, so the kind stands in for the body —
/// "Anna: Photo" beats "Anna: " followed by nothing, which reads as a message
/// that failed to load.
String replyPreviewOf(WeftMessage message) {
  final body = message.body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (body.isNotEmpty) return body;
  return '';
}

/// The count of unread replies, as the badge the inbox row already uses.
class _UnreadDot extends StatelessWidget {
  const _UnreadDot({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16),
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.xs,
        vertical: 0,
      ),
      decoration: BoxDecoration(
        color: context.colors.primary,
        borderRadius: WeftRadius.pill,
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: context.text.labelSmall?.copyWith(
          color: context.colors.onPrimary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }
}
