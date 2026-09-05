import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// The count pill Weft draws in two places: on a chat row and on a rail icon.
///
/// One widget rather than two, because they were two copies of the same defect.
/// Both fixed their height — 20dp on the row, 18dp on the rail — around a
/// `fontSize` that grows with `MediaQuery.textScaler`, so at 2.0× the digits
/// were 22dp and 20dp of glyph inside a box that had not moved, and both badges
/// drew their numbers with the tops and bottoms sliced off. That is the audit's
/// SCALE-4 and SCALE-5, and a shared component is the fix rather than two edits
/// because the next fixed height added beside them would be SCALE-17.
///
/// The rule is: the pill is *at least* [extent] square at 1.0× and grows with
/// the text, so a single digit stays a circle and "99+" stays a pill at every
/// scale. Every dimension goes through the ambient [TextScaler] rather than
/// being multiplied by a factor — the same thing at 1.0×, so every golden taken
/// before this widget existed is unmoved, and the right thing under a
/// non-linear scaler, where a factor does not exist.
class WeftUnreadBadge extends StatelessWidget {
  const WeftUnreadBadge({
    super.key,
    required this.count,
    required this.color,
    required this.ink,
    this.extent = 20,
    this.fontSize = 11,
    this.horizontalPadding = WeftSpace.dense,
    this.borderColor,
  });

  /// Unread messages. Shown as `99+` above 99, which is where the pill stops
  /// growing sideways and starts being a shape rather than a number.
  final int count;

  /// The pill's fill.
  final Color color;

  /// The digits.
  final Color ink;

  /// The pill's diameter at 1.0×, and its minimum on both axes once scaled.
  final double extent;

  final double fontSize;

  /// Breathing room either side of a two- or three-character count, which is
  /// the only case where the pill is wider than [extent].
  final double horizontalPadding;

  /// A 2dp ring, for the rail — where the badge overlaps the icon it belongs to
  /// and needs a hairline against it. Null everywhere else.
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final minimum = scaler.scale(extent);
    // The count changing is the only thing that ever happens to this widget,
    // and it happens while the reader is looking at something else — a pill
    // that pops rather than swaps is how they notice. The first build is not
    // animated, so no golden is captured mid-transition.
    return AnimatedSwitcher(
      duration: context.motion.fast,
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: Container(
        key: ValueKey(count),
        constraints: BoxConstraints(minWidth: minimum, minHeight: minimum),
        padding: EdgeInsetsDirectional.symmetric(
          horizontal: scaler.scale(horizontalPadding),
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: WeftRadius.pill,
          border: borderColor == null
              ? null
              : Border.all(color: borderColor!, width: 2),
        ),
        // `Center` with both factors rather than `Container(alignment:)`, which
        // is an `Align` that fills whatever it is given: in a `Row` or a
        // `Stack` the badge's width arrives unbounded and it shrink-wraps, but
        // hand it a bounded box — a `Center`, a `SizedBox`, a test — and the
        // pill silently becomes as wide as the pane. The factors pin the
        // shrink-wrap so the badge is the same size wherever it is put.
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Text(
            count > 99 ? '99+' : '$count',
            style: TextStyle(
              color: ink,
              fontSize: fontSize,
              height: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
