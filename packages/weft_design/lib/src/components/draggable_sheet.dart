import 'package:flutter/material.dart';

/// A draggable bottom-sheet body that keeps clear of the soft keyboard.
///
/// [DraggableScrollableSheet] sizes itself as a fraction of the space it is
/// given, and a modal bottom sheet is given the whole screen — the part the
/// keyboard is about to cover included. A sheet whose last row is a text field
/// therefore draws that field *under* the keys the moment it is tapped: the
/// caption on a photo about to be sent, typed blind behind the keyboard, with
/// the Send button under it equally out of reach.
///
/// So the sheet is inset by the keyboard, and then corrected for having been:
/// the fraction is scaled by however much the space shrank, which leaves the
/// sheet the height in pixels it already had and simply rides it above the
/// keys. Without that second half the sheet would keep its *fraction* and lose
/// two fifths of its height at the exact moment the user needs to see both the
/// files and what they are typing about them.
///
/// Scaling the current size rather than jumping to [initialSize] because the
/// user may have dragged the sheet somewhere else first, and where they put it
/// is where it belongs. A keyboard tall enough to leave less room than the
/// sheet asks for runs the scaling into [maxSize]: the sheet gives up the
/// difference for as long as the keys are up, and the height it wanted is
/// remembered so that dismissing them gives it back.
class WeftDraggableSheet extends StatefulWidget {
  const WeftDraggableSheet({
    super.key,
    required this.initialSize,
    required this.builder,
    this.minSize = 0.25,
    this.maxSize = 1.0,
  });

  /// Fraction of the available height the sheet opens at.
  final double initialSize;

  /// Fractions the sheet may be dragged — and grown by the keyboard — between.
  final double minSize;
  final double maxSize;

  /// Built with the scroll controller the sheet drags from, exactly as
  /// [DraggableScrollableSheet.builder] is. Hand it to the scrollable inside;
  /// a sheet whose controller is never attached still avoids the keyboard, it
  /// just cannot keep its height while doing so.
  final ScrollableWidgetBuilder builder;

  @override
  State<WeftDraggableSheet> createState() => _WeftDraggableSheetState();
}

class _WeftDraggableSheetState extends State<WeftDraggableSheet> {
  final DraggableScrollableController _sheet = DraggableScrollableController();

  /// Height the sheet's current size was last reconciled against, or 0 before
  /// the first layout.
  ///
  /// The keyboard arrives over several frames, so this walks down with it and
  /// the correction is applied a slice at a time — which is what makes the
  /// sheet track the keys instead of jumping when they finish sliding.
  double _available = 0;

  /// The fraction the sheet would be at if it fitted, while it does not.
  ///
  /// Zero the rest of the time, meaning "the sheet's own size is the truth".
  /// Held because [maxSize] loses the difference otherwise: a sheet squeezed
  /// from 0.75 down to a full 1.0 of what a tall keyboard left would come back
  /// as 1.0 scaled down — smaller than the sheet the user opened, for no
  /// reason they could see.
  double _wanted = 0;

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  /// Trades fraction for pixels, so the sheet is the same size it was.
  void _keepHeight(double available) {
    final was = _available;
    if (available == 0 || available == was) return;
    if (was == 0) {
      _available = available;
      return;
    }
    // Unattached until the builder's scrollable has clients. Nothing is
    // recorded in that case: the size was not touched, so the height it is
    // still measured against is the one already held.
    if (!_sheet.isAttached) return;

    // A drag since the last correction beats anything remembered — the sheet
    // is where the user put it, not where the keyboard found it.
    if (_wanted != 0 &&
        _sheet.size != _wanted.clamp(widget.minSize, widget.maxSize)) {
      _wanted = 0;
    }
    final wanted = (_wanted == 0 ? _sheet.size : _wanted) * was / available;
    final size = wanted.clamp(widget.minSize, widget.maxSize);
    _wanted = wanted == size ? 0 : wanted;
    _available = available;
    if (size == _sheet.size) return;
    _sheet.jumpTo(size);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Plain, not `AnimatedPadding`: the view insets already grow a frame at a
      // time as the keyboard slides, and a second animation over that one only
      // trails the keys it is supposed to sit on.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Deferred: this runs during layout, and `jumpTo` writes the extent
          // the sheet below is being laid out from.
          final available = constraints.maxHeight;
          if (available != _available) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _keepHeight(available);
            });
          }
          return DraggableScrollableSheet(
            expand: false,
            controller: _sheet,
            initialChildSize: widget.initialSize,
            minChildSize: widget.minSize,
            maxChildSize: widget.maxSize,
            builder: widget.builder,
          );
        },
      ),
    );
  }
}
