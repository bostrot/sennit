import 'package:flutter/material.dart';
import 'package:weft_domain/weft_domain.dart';

import '../theme.dart';
import '../tokens.dart';
import 'network_glyph.dart';
import 'weft_avatar.dart';

/// One conversation in the inbox.
///
/// A merged chat is signalled three ways so it never depends on colour alone:
/// the avatar's gradient ring, a row of network glyphs, and the "Merged" label
/// in its accessibility description.
class ChatTile extends StatefulWidget {
  const ChatTile({
    super.key,
    required this.chat,
    required this.onTap,
    this.selected = false,
    this.timeLabel,
    this.onLongPress,
    this.avatarHeaders,
    this.leading,
  });

  /// Replaces the avatar while the inbox is in selection mode.
  final Widget? leading;

  /// Headers for the avatar fetch — Matrix media is authenticated.
  final Map<String, String>? avatarHeaders;

  final Chat chat;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  /// Preformatted, locale-aware time string. Formatting lives in the app layer
  /// so this package stays free of `intl`.
  final String? timeLabel;

  @override
  State<ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<ChatTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final colors = context.colors;
    final unread = chat.unreadCount > 0;

    return Semantics(
      selected: widget.selected,
      label: [
        chat.title,
        if (chat.isMerged) 'Merged across ${chat.networks.length} networks',
        if (unread) '${chat.unreadCount} unread',
      ].join(', '),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: context.motion.fast,
            curve: context.motion.standard,
            margin: const EdgeInsets.symmetric(
              horizontal: WeftSpace.sm,
              vertical: 2,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: WeftSpace.md,
              vertical: WeftSpace.md,
            ),
            decoration: BoxDecoration(
              color: widget.selected
                  ? colors.primaryContainer
                  : _hovered
                  ? colors.surfaceContainerHigh
                  : Colors.transparent,
              borderRadius: WeftRadius.allLg,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                widget.leading ??
                    WeftAvatar(
                      label: chat.title,
                      imageUrl: chat.avatarUrl,
                      imageHeaders: widget.avatarHeaders,
                      networks: chat.networks,
                      size: 46,
                    ),
                const SizedBox(width: WeftSpace.md),
                Expanded(child: _body(context)),
                const SizedBox(width: WeftSpace.sm),
                _trailing(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final chat = widget.chat;
    final unread = chat.unreadCount > 0;
    final last = chat.lastMessage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                chat.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.titleSmall?.copyWith(
                  fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
            if (chat.pinned) ...[
              const SizedBox(width: WeftSpace.xs),
              Icon(
                Icons.push_pin_rounded,
                size: 13,
                color: context.colors.onSurfaceVariant,
              ),
            ],
            if (chat.muted) ...[
              const SizedBox(width: WeftSpace.xs),
              Icon(
                Icons.notifications_off_rounded,
                size: 13,
                color: context.colors.onSurfaceVariant,
              ),
            ],
          ],
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            if (last != null && last.isOwn) ...[
              Icon(
                _deliveryIcon(last.deliveryState),
                size: 14,
                color: last.deliveryState == DeliveryState.read
                    ? context.colors.primary
                    : context.colors.onSurfaceVariant,
              ),
              const SizedBox(width: WeftSpace.xs),
            ],
            Expanded(
              child: Text(
                _preview(last),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall?.copyWith(
                  color: unread
                      ? context.colors.onSurface
                      : context.colors.onSurfaceVariant,
                  fontWeight: unread ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
        if (chat.isMerged) ...[
          const SizedBox(height: WeftSpace.sm),
          _MergedStrip(networks: chat.networks),
        ],
      ],
    );
  }

  Widget _trailing(BuildContext context) {
    final chat = widget.chat;
    final palette = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.timeLabel != null)
          Text(
            widget.timeLabel!,
            style: context.text.labelSmall?.copyWith(
              color: chat.unreadCount > 0
                  ? context.colors.primary
                  : context.colors.onSurfaceVariant,
              fontWeight: chat.unreadCount > 0
                  ? FontWeight.w700
                  : FontWeight.w400,
            ),
          ),
        const SizedBox(height: WeftSpace.sm),
        if (chat.unreadCount > 0)
          Container(
            constraints: const BoxConstraints(minWidth: 20),
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: palette.unreadDot,
              borderRadius: WeftRadius.pill,
            ),
            alignment: Alignment.center,
            child: Text(
              chat.unreadCount > 99 ? '99+' : '${chat.unreadCount}',
              style: TextStyle(
                color: context.colors.onPrimary,
                fontSize: 11,
                height: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }

  static String _preview(WeftMessage? last) {
    if (last == null) return 'No messages yet';
    if (last.redacted) return 'Message deleted';
    return switch (last.kind) {
      MessageKind.image => '📷 Photo',
      MessageKind.video => '🎥 Video',
      MessageKind.voice =>
        last.transcript != null ? '🎙 ${last.transcript}' : '🎙 Voice message',
      MessageKind.audio => '🎵 Audio',
      MessageKind.file => '📎 File',
      MessageKind.location => '📍 Location',
      MessageKind.sticker => 'Sticker',
      MessageKind.poll => '📊 Poll',
      MessageKind.event => last.body,
      MessageKind.text => last.body,
    };
  }

  static IconData _deliveryIcon(DeliveryState? state) => switch (state) {
    DeliveryState.sending => Icons.schedule_rounded,
    DeliveryState.failed => Icons.error_outline_rounded,
    DeliveryState.read => Icons.done_all_rounded,
    DeliveryState.delivered => Icons.done_all_rounded,
    _ => Icons.done_rounded,
  };
}

/// The row of network marks under a merged chat's preview.
class _MergedStrip extends StatelessWidget {
  const _MergedStrip({required this.networks});

  final List<ChatNetwork> networks;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: palette.mergedAccent.withValues(alpha: 0.16),
            borderRadius: WeftRadius.pill,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.merge_rounded, size: 11, color: palette.mergedAccent),
              const SizedBox(width: 3),
              Text(
                'Merged',
                style: context.text.labelSmall?.copyWith(
                  color: palette.mergedAccent,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: WeftSpace.sm),
        for (final n in networks) ...[
          NetworkGlyph(network: n, size: 14),
          const SizedBox(width: 3),
        ],
      ],
    );
  }
}
