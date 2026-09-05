import 'package:flutter/material.dart';

import '../surface.dart';
import '../theme.dart';
import '../tokens.dart';

/// The pause before a tooltip appears, as the system uses it.
///
/// Material pops one almost immediately, which on a toolbar of eight buttons
/// means a tooltip follows the pointer across the window. macOS waits.
const Duration kMacTooltipDelay = Duration(milliseconds: 900);

/// A square icon button, the size the system's toolbars use.
///
/// The hover fill is the whole interaction model on this surface: macOS has no
/// ripple, and a control that does not light up under the pointer reads as
/// decoration. [selected] draws the same fill permanently, which is how a
/// toggled toolbar item — sidebar shown, filter on — states itself.
class MacToolbarButton extends StatefulWidget {
  const MacToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.size = MacMetrics.controlSize,
    this.iconSize = 15,
    this.accent,
  });

  final IconData icon;

  /// Also the button's accessibility label — a toolbar of glyphs is unreadable
  /// without one, and there is no visible text to fall back on.
  final String tooltip;

  final VoidCallback? onPressed;
  final bool selected;
  final double size;
  final double iconSize;

  /// Overrides the glyph colour. For the one destructive item in a toolbar.
  final Color? accent;

  @override
  State<MacToolbarButton> createState() => _MacToolbarButtonState();
}

class _MacToolbarButtonState extends State<MacToolbarButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = widget.onPressed != null;

    final fill = switch ((enabled, widget.selected, _pressed, _hovered)) {
      (false, _, _, _) => Colors.transparent,
      (_, true, _, _) => colors.primary.withValues(alpha: 0.90),
      (_, _, true, _) => colors.onSurface.withValues(alpha: 0.16),
      (_, _, _, true) => colors.onSurface.withValues(alpha: 0.09),
      _ => Colors.transparent,
    };
    final ink = switch ((enabled, widget.selected)) {
      (false, _) => colors.onSurface.withValues(alpha: 0.28),
      (_, true) => colors.onPrimary,
      _ => widget.accent ?? colors.onSurface,
    };

    return Tooltip(
      message: widget.tooltip,
      waitDuration: kMacTooltipDelay,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.tooltip,
        child: MouseRegion(
          // The arrow either way: a Mac shows no special cursor over a
          // disabled control, it simply does not light up.
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapCancel: enabled
                ? () => setState(() => _pressed = false)
                : null,
            onTap: enabled
                ? () {
                    setState(() => _pressed = false);
                    widget.onPressed!.call();
                  }
                : null,
            child: AnimatedContainer(
              duration: context.motion.instant,
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(MacMetrics.controlRadius),
              ),
              child: Icon(widget.icon, size: widget.iconSize, color: ink),
            ),
          ),
        ),
      ),
    );
  }
}

/// Several toolbar buttons as one floating group.
///
/// Tahoe stops drawing toolbar items as bare glyphs on the window and puts
/// related ones inside a shared capsule, so a toolbar reads as two or three
/// objects rather than nine. The capsule is what carries the grouping.
class MacToolbarGroup extends StatelessWidget {
  const MacToolbarGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color: context.colors.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(MacMetrics.controlRadius + 2),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// The toolbar's search field.
///
/// Short, quiet, and 24pt tall — it is a control in a bar, not the page's
/// headline. Expands on focus the way the system's does, which is what tells
/// the user their typing is going somewhere.
class MacSearchField extends StatefulWidget {
  const MacSearchField({
    super.key,
    required this.controller,
    this.hintText = 'Search',
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.width = 180,
    this.focusedWidth = 260,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final double width;
  final double focusedWidth;
  final bool autofocus;

  @override
  State<MacSearchField> createState() => _MacSearchFieldState();
}

class _MacSearchFieldState extends State<MacSearchField> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  bool _owned = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _owned = widget.focusNode == null;
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (_focus.hasFocus != _focused) setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    if (_owned) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final palette = context.palette;

    return AnimatedContainer(
      duration: context.motion.fast,
      curve: context.motion.standard,
      width: _focused ? widget.focusedWidth : widget.width,
      height: MacMetrics.fieldHeight,
      padding: const EdgeInsetsDirectional.only(
        start: WeftSpace.dense,
        end: WeftSpace.xs,
      ),
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: _focused ? 0.10 : 0.07),
        borderRadius: BorderRadius.circular(MacMetrics.controlRadius - 1),
        border: Border.all(
          color: _focused ? palette.focusRing : Colors.transparent,
          width: _focused ? 2 : 0,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 13, color: colors.onSurfaceVariant),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              autofocus: widget.autofocus,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              cursorHeight: 13,
              cursorWidth: 1,
              style: context.text.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: widget.hintText,
                hintStyle: context.text.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (widget.controller.text.isNotEmpty)
            _ClearButton(
              onPressed: () {
                widget.controller.clear();
                widget.onChanged?.call('');
                setState(() {});
              },
            ),
        ],
      ),
    );
  }
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Clear search',
    child: GestureDetector(
      onTap: onPressed,
      child: Icon(
        Icons.cancel_rounded,
        size: 13,
        color: context.colors.onSurfaceVariant,
      ),
    ),
  );
}

/// A push button, at the system's size.
///
/// Material's `FilledButton` is 40pt tall with 24pt of side padding, which is
/// a thumb target; a Mac's default button is 22pt. [prominent] is the blue
/// default-action button, the one Return activates.
class MacPushButton extends StatefulWidget {
  const MacPushButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.prominent = false,
    this.destructive = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool prominent;
  final bool destructive;
  final IconData? icon;

  @override
  State<MacPushButton> createState() => _MacPushButtonState();
}

class _MacPushButtonState extends State<MacPushButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = widget.onPressed != null;

    final background = switch ((enabled, widget.prominent)) {
      (false, true) => colors.primary.withValues(alpha: 0.35),
      (_, true) =>
        _hovered
            ? Color.lerp(colors.primary, Colors.white, 0.10)!
            : colors.primary,
      (false, false) => colors.onSurface.withValues(alpha: 0.05),
      _ => colors.onSurface.withValues(alpha: _hovered ? 0.14 : 0.09),
    };
    final ink = switch ((enabled, widget.prominent, widget.destructive)) {
      (false, _, _) => colors.onSurface.withValues(alpha: 0.30),
      (_, true, _) => colors.onPrimary,
      (_, _, true) => colors.error,
      _ => colors.onSurface,
    };

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Semantics(
          button: true,
          enabled: enabled,
          label: widget.label,
          child: AnimatedContainer(
            duration: context.motion.instant,
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: WeftSpace.md),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(MacMetrics.controlRadius - 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 13, color: ink),
                  const SizedBox(width: 5),
                ],
                Text(
                  widget.label,
                  style: context.text.labelLarge?.copyWith(color: ink),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
