import 'package:flutter/material.dart';

import '../surface.dart';
import '../theme.dart';
import '../tokens.dart';

/// Whether the route [context] sits in covers the whole window.
///
/// The shell's own panes live in the first route, where the sidebar's toolbar
/// already keeps clear of the traffic lights. Anything pushed over it — a
/// conversation opened from search, a thread, a settings page — starts at the
/// window's top-left corner, under the close, minimise and zoom buttons.
bool macRouteCoversWindow(BuildContext context) =>
    context.isMac && !(ModalRoute.of(context)?.isFirst ?? true);

/// The leading clearance a toolbar at the top of [context]'s route needs:
/// [MacMetrics.trafficLightInset] on a pushed Mac route, nothing otherwise.
double macToolbarInsetFor(BuildContext context) =>
    macRouteCoversWindow(context) ? MacMetrics.trafficLightInset : 0;

/// One pane's slice of the window's unified toolbar.
///
/// The window has a single toolbar running its whole width, divided by the
/// same splits as the content below it — that is what a Mac's title bar has
/// been since it stopped being a title bar. Each pane hosts its own segment,
/// so the sidebar's segment carries the traffic-light inset and the thread's
/// carries the conversation's name.
///
/// [leadingInset] is that clearance. Only the pane at the window's starting
/// edge passes it; passing it twice puts a gap in the middle of the window.
class MacToolbar extends StatelessWidget {
  const MacToolbar({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.leadingInset = 0,
    this.height = MacMetrics.toolbarHeight,
    this.titleWidget,
  });

  final Widget? leading;

  /// The pane's name, at the system's toolbar-title size and weight.
  final String? title;

  /// A second, quieter line — who a conversation is with, how many are in a
  /// group. Drawn under [title] rather than beside it.
  final String? subtitle;

  /// Replaces [title]/[subtitle] entirely, for a segment whose middle is a
  /// control rather than a name.
  final Widget? titleWidget;

  final List<Widget> actions;
  final double leadingInset;
  final double height;

  @override
  Widget build(BuildContext context) {
    final middle =
        titleWidget ??
        (title == null
            ? const SizedBox.shrink()
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.titleSmall,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.labelSmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ));

    return SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: leadingInset + WeftSpace.md,
          end: WeftSpace.md,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: WeftSpace.sm),
            ],
            Expanded(child: middle),
            if (actions.isNotEmpty) ...[
              const SizedBox(width: WeftSpace.sm),
              Row(mainAxisSize: MainAxisSize.min, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
