import 'package:flutter/material.dart';

import '../focus.dart';
import '../surface.dart';
import '../theme.dart';
import '../tokens.dart';
import 'mac_glass.dart';

/// The window's source list.
///
/// Translucent, because on a Mac this layer is showing the desktop through the
/// window — the single most recognisable thing about a native sidebar, and the
/// reason it is glass rather than a coloured column.
class MacSidebar extends StatelessWidget {
  const MacSidebar({
    super.key,
    required this.children,
    this.width = MacMetrics.sidebarWidth,
    this.top,
  });

  final List<Widget> children;
  final double width;

  /// The sidebar's toolbar segment, drawn above the list and outside its
  /// scroll — the traffic lights live here.
  final Widget? top;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: MacGlass(
        kind: MacGlassKind.sidebar,
        border: const Border(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (top != null) top!,
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(
                  left: WeftSpace.sm,
                  right: WeftSpace.sm,
                  bottom: WeftSpace.md,
                ),
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A titled group of sidebar rows.
///
/// The heading is 11pt, semibold and quiet — it labels the group without
/// competing with the rows under it. macOS makes these collapsible; [onToggle]
/// is what makes a group's disclosure real rather than decorative.
class MacSidebarSection extends StatelessWidget {
  const MacSidebarSection({
    super.key,
    required this.title,
    required this.children,
    this.expanded = true,
    this.onToggle,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final bool expanded;
  final VoidCallback? onToggle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final heading = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        WeftSpace.sm,
        WeftSpace.md,
        WeftSpace.xs,
        WeftSpace.xs,
      ),
      child: Row(
        children: [
          if (onToggle != null)
            AnimatedRotation(
              duration: context.motion.fast,
              turns: expanded ? 0 : -0.25,
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 14,
                color: context.colors.onSurfaceVariant,
              ),
            ),
          Expanded(
            child: Text(
              title,
              style: context.text.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onToggle == null)
          heading
        else
          Semantics(
            button: true,
            expanded: expanded,
            label: title,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: heading,
            ),
          ),
        AnimatedCrossFade(
          duration: context.motion.fast,
          sizeCurve: context.motion.standard,
          crossFadeState: expanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          firstChild: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
          secondChild: const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// One row in the source list.
///
/// 28pt tall with a 7pt capsule, which is the system's shape — and the
/// selected row is a *filled* capsule in the accent colour rather than Material's
/// tinted container, because that is the one piece of a sidebar everyone
/// recognises at a glance.
class MacSidebarRow extends StatefulWidget {
  const MacSidebarRow({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.leading,
    this.selected = false,
    this.badge,
    this.trailing,
    this.onSecondaryTapUp,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback onTap;

  /// A glyph, drawn in the accent colour when unselected. Ignored when
  /// [leading] is given.
  final IconData? icon;

  /// An arbitrary leading widget — a network mark, an avatar.
  final Widget? leading;

  final bool selected;

  /// Unread count. Drawn as a plain number, which is what the system does —
  /// a red pill on a sidebar row is an iOS badge.
  final int? badge;

  final Widget? trailing;
  final ValueChanged<TapUpDetails>? onSecondaryTapUp;

  /// Overrides what a screen reader hears, for a row whose visible label is
  /// not the whole story.
  final String? semanticsLabel;

  @override
  State<MacSidebarRow> createState() => _MacSidebarRowState();
}

class _MacSidebarRowState extends State<MacSidebarRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = widget.selected;

    final fill = switch ((selected, _hovered)) {
      (true, _) => colors.primary,
      (_, true) => colors.onSurface.withValues(alpha: 0.07),
      _ => Colors.transparent,
    };
    final ink = selected ? colors.onPrimary : colors.onSurface;
    final quiet = selected
        ? colors.onPrimary.withValues(alpha: 0.75)
        : colors.onSurfaceVariant;

    return WeftFocusable(
      selected: selected,
      onTap: widget.onTap,
      label: widget.semanticsLabel ?? widget.label,
      borderRadius: BorderRadius.circular(MacMetrics.sidebarRowRadius),
      ringInset: 0,
      onHoverChanged: (value) => setState(() => _hovered = value),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: widget.onSecondaryTapUp,
        child: AnimatedContainer(
          duration: context.motion.instant,
          height: MacMetrics.sidebarRowHeight,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsetsDirectional.only(start: 6, end: 6),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(MacMetrics.sidebarRowRadius),
          ),
          child: Row(
            children: [
              if (widget.leading != null)
                widget.leading!
              else if (widget.icon != null)
                Icon(
                  widget.icon,
                  size: 15,
                  color: selected ? colors.onPrimary : colors.primary,
                ),
              if (widget.leading != null || widget.icon != null)
                const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodyMedium?.copyWith(
                    color: ink,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.badge != null && widget.badge! > 0)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4),
                  child: Text(
                    '${widget.badge}',
                    style: context.text.labelSmall?.copyWith(color: quiet),
                  ),
                ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 4),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
