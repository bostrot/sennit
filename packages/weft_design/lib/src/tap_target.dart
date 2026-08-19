import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// The smallest a control may be and still be reliably hittable.
///
/// Android's guideline, which is the stricter of the two Weft ships against —
/// iOS asks for 44. One number rather than two because a control sized for the
/// looser guideline fails the other, and a messenger's controls are the same
/// controls on both platforms.
const double kWeftMinTapTarget = 48;

/// Guarantees [child] at least [minSize] of *interactive* box without changing
/// what it paints.
///
/// The touch-target register in the accessibility audit is fourteen controls
/// between 22dp and 44dp — reaction chips, an add-reaction "+", a hang-up
/// button on the minimised call bar. Every one of them is legible; none of them
/// is reliably hittable, and the people that fails are the ones least able to
/// aim: anyone using the phone one-handed on a train, anyone with a tremor.
///
/// The mechanism is Material's own, which is worth saying because the
/// alternative looks cheaper and is wrong. A `Checkbox` paints 18dp and
/// *occupies* 48; the extra is transparent padding that takes real layout
/// space. Expanding only the hit test while reporting the old size is not
/// available — a [RenderBox] never receives a pointer outside its own bounds,
/// because [RenderBox.hitTest] rejects it before the child is consulted — and
/// expanding only the semantics rect would move the number a test reads without
/// moving the box a thumb has to find. So this takes the space, and the call
/// sites give back the margin they no longer need.
///
/// Wrap it *inside* the control's [Semantics] annotation, not outside. A node's
/// rect is the size of the render object under the annotation, so a tap target
/// added above the label leaves the node exactly as small as it was — which is
/// both what a screen reader's touch exploration uses and what
/// [MinimumTapTargetGuideline] measures.
class WeftTapTarget extends SingleChildRenderObjectWidget {
  const WeftTapTarget({
    super.key,
    this.minSize = const Size.square(kWeftMinTapTarget),
    required Widget super.child,
  });

  /// Both axes, because the guidelines are square. Give a control a smaller
  /// height only where the taller box would push a running line apart.
  final Size minSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTapTarget(minSize);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    // Declared against `RenderObject` rather than the private render class,
    // which would put a private type in a public signature.
    (renderObject as _RenderTapTarget).minSize = minSize;
  }
}

/// Material's `_InputPadding`, which is private to `material/`.
///
/// Copied rather than reached for because it is exactly right and exactly
/// unavailable: it centres the child in a box grown to the minimum, and it
/// forwards every hit in that box to the child's centre, so the padding is
/// live rather than dead space around a control that still only responds to
/// its own pixels.
class _RenderTapTarget extends RenderShiftedBox {
  _RenderTapTarget(this._minSize) : super(null);

  Size get minSize => _minSize;
  Size _minSize;
  set minSize(Size value) {
    if (_minSize == value) return;
    _minSize = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    child == null ? 0 : child!.getMinIntrinsicWidth(height),
    minSize.width,
  );

  @override
  double computeMaxIntrinsicWidth(double height) => math.max(
    child == null ? 0 : child!.getMaxIntrinsicWidth(height),
    minSize.width,
  );

  @override
  double computeMinIntrinsicHeight(double width) => math.max(
    child == null ? 0 : child!.getMinIntrinsicHeight(width),
    minSize.height,
  );

  @override
  double computeMaxIntrinsicHeight(double width) => math.max(
    child == null ? 0 : child!.getMaxIntrinsicHeight(width),
    minSize.height,
  );

  Size _sizeFor(Size childSize) => Size(
    math.max(childSize.width, minSize.width),
    math.max(childSize.height, minSize.height),
  );

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.constrain(minSize);
    return constraints.constrain(_sizeFor(child.getDryLayout(constraints)));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.constrain(minSize);
      return;
    }
    // The child's own constraints, unmodified: the point is to leave what it
    // paints exactly as it was, and a loosened or tightened box would relay it.
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(_sizeFor(child.size));
    final parentData = child.parentData! as BoxParentData;
    parentData.offset = Alignment.center.alongOffset(
      size - child.size as Offset,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;
    final child = this.child;
    if (child == null || !size.contains(position)) return false;
    // Anywhere in the grown box counts as the child's centre. Without this the
    // padding would be visually generous and functionally dead, which is the
    // failure mode that makes an over-large button feel broken.
    final Offset centre = child.size.center(Offset.zero);
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(centre),
      position: centre,
      hitTest: (result, position) => child.hitTest(result, position: centre),
    );
  }
}
