import 'package:flutter/material.dart';

import 'surface.dart';

/// Keeps a page's content inside a column someone can actually read.
///
/// A phone screen is 400 points wide and a settings row fills it exactly. The
/// same row in a 1280-point window puts its label at the far left and its
/// chevron 1240 points away, and the eye has to travel the whole distance to
/// find out what the switch belongs to. Every desktop settings app answers this
/// the same way — macOS System Settings, GNOME Settings, Windows Settings all
/// hold their content to roughly 700 points and centre it — and an app that
/// does not is recognisably a phone screen someone widened.
///
/// A pass-through on touch, so the phone layout is untouched and there is no
/// second version of any page to keep in step.
class WeftReadingPane extends StatelessWidget {
  const WeftReadingPane({super.key, required this.child, this.maxWidth = 720});

  final Widget child;

  /// Roughly ninety characters at the desktop type scale. Wider than this and
  /// the return sweep starts costing the reader their place.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!context.isDesktop) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
