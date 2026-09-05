import 'package:flutter/material.dart';

import 'surface.dart';

/// An [AppBar] that knows where the window's own controls are.
///
/// A macOS window with full-size content has no title bar: the close, minimise
/// and zoom buttons float over whatever the app draws at the top-left corner.
/// The shell reserves that space in its own toolbar — but a *pushed* screen
/// covers the whole window, and its back button lands underneath the traffic
/// lights. Two controls in the same twenty points, one of which is the system's
/// and wins every click.
///
/// This is the same [AppBar] with that space reserved, so a back arrow starts
/// where the lights stop. On touch, and on any desktop whose window controls
/// live at the trailing edge, it is [AppBar] unchanged.
class WeftAppBar extends StatelessWidget implements PreferredSizeWidget {
  const WeftAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.bottom,
    this.backgroundColor,
    this.toolbarHeight,
    this.centerTitle,
    this.automaticallyImplyLeading = true,
    this.elevation,
    this.foregroundColor,
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final Color? backgroundColor;
  final double? toolbarHeight;
  final bool? centerTitle;
  final bool automaticallyImplyLeading;
  final double? elevation;
  final Color? foregroundColor;

  /// How much of the leading edge the system's own controls occupy.
  static double insetFor(BuildContext context) =>
      context.isMac ? MacMetrics.trafficLightInset : 0;

  @override
  Size get preferredSize => Size.fromHeight(
    (toolbarHeight ?? kToolbarHeight) + (bottom?.preferredSize.height ?? 0),
  );

  @override
  Widget build(BuildContext context) {
    final inset = insetFor(context);
    if (inset == 0) {
      return AppBar(
        title: title,
        actions: actions,
        leading: leading,
        bottom: bottom,
        backgroundColor: backgroundColor,
        toolbarHeight: toolbarHeight,
        centerTitle: centerTitle,
        automaticallyImplyLeading: automaticallyImplyLeading,
        elevation: elevation,
        foregroundColor: foregroundColor,
      );
    }

    // Whatever would have been in the leading slot, moved right by the inset.
    // Resolved here rather than left to `automaticallyImplyLeading`, because
    // the padding has to wrap the button and the AppBar only wraps what it is
    // given.
    final implied =
        leading ??
        (automaticallyImplyLeading && Navigator.of(context).canPop()
            ? const BackButton()
            : null);

    return AppBar(
      title: title,
      actions: actions,
      bottom: bottom,
      backgroundColor: backgroundColor,
      toolbarHeight: toolbarHeight,
      centerTitle: centerTitle,
      elevation: elevation,
      foregroundColor: foregroundColor,
      automaticallyImplyLeading: false,
      // The inset plus room for the control itself. A leading widget is laid
      // out in a box of exactly this width, so without the extra the button
      // would be squeezed into the space the lights are already using.
      leadingWidth: implied == null ? inset : inset + 44,
      leading: Padding(
        padding: EdgeInsetsDirectional.only(start: inset),
        child: implied ?? const SizedBox.shrink(),
      ),
    );
  }
}
