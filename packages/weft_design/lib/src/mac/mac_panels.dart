import 'package:flutter/material.dart';

import '../surface.dart';
import 'mac_glass.dart';

/// Opens a panel in whatever form this surface uses.
///
/// One call site, two platforms: on touch this is the bottom sheet the app has
/// always shown, and on a Mac it is a popover pointing at [anchorContext] — or,
/// with no anchor to point at, a sheet from the title bar. The [builder] is the
/// same in both cases, which is what makes this a routing decision rather than
/// a second implementation of every panel.
///
/// [anchorContext] is the `BuildContext` of the control that opened the panel.
/// Pass it wherever there is one; a popover with no anchor is a dialog, and the
/// system knows the difference.
///
/// [showDragHandle] is honoured on touch and ignored on the desktop, where
/// there is nothing to drag — a Mac panel is dismissed with Escape or by
/// clicking away from it.
Future<T?> showWeftPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  BuildContext? anchorContext,
  double? width,
  bool isScrollControlled = true,
  bool useRootNavigator = true,
  bool showDragHandle = false,
  Color? backgroundColor,
}) {
  if (!context.isMac) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useRootNavigator: useRootNavigator,
      showDragHandle: showDragHandle,
      backgroundColor: backgroundColor,
      builder: builder,
    );
  }

  final anchor = _anchorRect(anchorContext);
  if (anchor == null) {
    return showMacSheet<T>(
      context: context,
      builder: builder,
      width: width,
      useRootNavigator: useRootNavigator,
    );
  }
  return showMacPopover<T>(
    context: context,
    anchor: anchor,
    builder: builder,
    width: width,
    useRootNavigator: useRootNavigator,
  );
}

/// The screen rect of the widget that opened a panel, or null if it has gone.
Rect? _anchorRect(BuildContext? anchorContext) {
  if (anchorContext == null || !anchorContext.mounted) return null;
  final box = anchorContext.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  final origin = box.localToGlobal(Offset.zero);
  return origin & box.size;
}

/// A popover, pointing at [anchor].
///
/// Positioned below the anchor and aligned to its starting edge, flipping above
/// it when there is no room below — which is what the system does, and what
/// stops a popover opened from a toolbar at the bottom of a short window from
/// being drawn off screen.
Future<T?> showMacPopover<T>({
  required BuildContext context,
  required Rect anchor,
  required WidgetBuilder builder,
  double? width,
  bool useRootNavigator = true,
}) {
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _MacPopoverRoute<T>(
      anchor: anchor,
      width: width ?? MacMetrics.popoverWidth,
      builder: builder,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

/// A document-modal sheet, dropping from the window's title bar.
Future<T?> showMacSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double? width,
  bool useRootNavigator = true,
}) {
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _MacSheetRoute<T>(
      width: width ?? 460,
      builder: builder,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

class _MacPopoverRoute<T> extends PopupRoute<T> {
  _MacPopoverRoute({
    required this.anchor,
    required this.width,
    required this.builder,
    required this.barrierLabel,
  });

  final Rect anchor;
  final double width;
  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _PopoverLayout(anchor: anchor, width: width),
      child: _PopoverPanel(
        width: width,
        // Grows from the edge nearest its anchor, which is what makes a
        // popover read as coming *out of* the control rather than appearing
        // over it.
        animation: animation,
        child: Builder(builder: builder),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout({required this.anchor, required this.width});

  final Rect anchor;
  final double width;

  static const double _gap = 6;
  static const double _margin = 10;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final below = constraints.maxHeight - anchor.bottom - _gap - _margin;
    final above = anchor.top - _gap - _margin;
    return BoxConstraints(
      maxWidth: width,
      // Whichever side has room, so the panel is never given a height it
      // cannot be drawn in.
      maxHeight: (below > above ? below : above).clamp(80.0, double.infinity),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final below = size.height - anchor.bottom - _gap;
    final y = childSize.height <= below
        ? anchor.bottom + _gap
        : (anchor.top - _gap - childSize.height).clamp(_margin, size.height);
    final x = (anchor.left + anchor.width / 2 - childSize.width / 2).clamp(
      _margin,
      (size.width - childSize.width - _margin).clamp(_margin, size.width),
    );
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PopoverLayout old) =>
      old.anchor != anchor || old.width != width;
}

class _PopoverPanel extends StatelessWidget {
  const _PopoverPanel({
    required this.width,
    required this.child,
    required this.animation,
  });

  final double width;
  final Widget child;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final panel = MacGlass(
      kind: MacGlassKind.popover,
      elevated: true,
      borderRadius: BorderRadius.circular(MacMetrics.popoverRadius),
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(width: width, child: child),
      ),
    );

    if (reduced) return panel;
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        alignment: Alignment.topCenter,
        child: panel,
      ),
    );
  }
}

class _MacSheetRoute<T> extends PopupRoute<T> {
  _MacSheetRoute({
    required this.width,
    required this.builder,
    required this.barrierLabel,
  });

  final double width;
  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  /// A sheet dims its window; a popover does not. That difference is what says
  /// "this one is modal" without a word of explanation.
  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.28);

  /// Dismissible, unlike a true document-modal sheet.
  ///
  /// A Mac sheet is answered with its own buttons and cannot be clicked away
  /// from — but these panels are the phone's bottom sheets, and a bottom sheet
  /// is dismissed by swiping it away. Several of them carry no button at all,
  /// so making this modal in the strict sense would trap the window in a panel
  /// with no way out.
  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: MacGlass(
          kind: MacGlassKind.popover,
          elevated: true,
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(MacMetrics.sheetRadius),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Builder(builder: builder),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, -1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    );
  }
}
