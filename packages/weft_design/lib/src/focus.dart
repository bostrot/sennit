import 'package:flutter/material.dart';

import 'theme.dart';

/// A control that a keyboard can reach, announced as one node.
///
/// The audit's CROSS-3 finding was that the app had no keyboard model at all,
/// and the half of it that is not about shortcuts is this: a control built on a
/// `GestureDetector` is not focusable. Tab never lands on it, so it has no
/// focus ring, no Enter-to-activate and no place in the traversal order — while
/// the `InkWell`-based controls beside it have all three. That inconsistency is
/// worse than a uniform absence, because Tab appears to work right up until it
/// silently skips the inbox.
///
/// Three things have to be true at once for a control to work, and doing any
/// two of them is the trap this widget exists to close:
///
///  * **It is focusable.** A [Semantics] node with `button: true` is not — the
///    semantics tree is what a screen reader walks, and the focus tree is what
///    Tab walks, and they are different trees. Only a real [Focus] puts the
///    control in the second one.
///  * **The focus is visible.** [WeftPalette.focusRing] is designed to clear
///    3:1 against the surfaces a control is drawn *on*, so the ring is painted
///    outside the control's bounds rather than inside them — through a
///    [Stack] with negative insets, which costs no layout and cannot shift the
///    thing it is drawn around.
///  * **Enter and Space activate it.** Landing on a control that can only be
///    tapped is the same dead end as not landing on it at all, so
///    [ActivateIntent] and [ButtonActivateIntent] both run [onTap].
///
/// The semantics half is deliberately in the same widget rather than left to
/// the caller. Task 3 and task 4 of the accessibility phase established the
/// exact recipe every one of these call sites needs — `container: true` so the
/// control is its own node, `excludeSemantics: true` so its innards stop
/// speaking separately, and the tap and long-press restated because excluding
/// the subtree takes the `GestureDetector`'s actions with it — and splitting
/// that recipe across two widgets is how the next call site gets one half of
/// it.
class WeftFocusable extends StatefulWidget {
  const WeftFocusable({
    super.key,
    required this.label,
    required this.child,
    this.onTap,
    this.onActivate,
    this.onLongPress,
    this.onLongPressHint,
    this.button = true,
    this.image = false,
    this.selected,
    this.checked,
    this.excludeSemantics = true,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
    this.ringInset = 2,
    this.focusNode,
    this.autofocus = false,
    this.onHoverChanged,
    this.canRequestFocus = true,
  });

  /// The whole control as one sentence — what [Semantics.label] gets.
  final String label;

  final Widget child;

  final VoidCallback? onTap;

  /// What Enter and Space do, when that is not what a tap does.
  ///
  /// Defaults to [onTap], which is the ordinary case. Set separately where the
  /// pointer affordance and the keyboard one genuinely differ: a message
  /// bubble opens its action sheet on long-press, and a keyboard has no
  /// long-press — but making a *tap* open it too would put a menu in front of
  /// anyone who touched a message.
  final VoidCallback? onActivate;

  final VoidCallback? onLongPress;

  /// Verb for the long-press, as a screen reader reads it: "double tap and hold
  /// to `<hint>`". Null when there is no long-press.
  final String? onLongPressHint;

  /// False for a group — a node that names what is inside it without being a
  /// control itself. A message bubble is the case: it is a heading over a body
  /// whose links have to stay individually reachable.
  final bool button;

  final bool image;
  final bool? selected;
  final bool? checked;

  /// Whether the subtree stops speaking for itself.
  ///
  /// True for a control, which is one node. False for a group whose children
  /// are themselves controls — excluding those would silence the links and
  /// mention pills inside a bubble, which is a worse bug than the one the
  /// group label fixes.
  final bool excludeSemantics;

  /// The shape the ring traces. Match the control's own corner radius, or the
  /// ring sits square around a pill.
  final BorderRadiusGeometry? borderRadius;

  /// [BoxShape.circle] for a round control — an accent swatch, an avatar — for
  /// which no radius describes the outline.
  final BoxShape shape;

  /// How far outside the control the ring sits.
  ///
  /// Outside rather than inside because [WeftPalette.focusRing] is measured
  /// against the surfaces a control is drawn on, not against the control's own
  /// fill. A ring painted inside a filled button is measured against the wrong
  /// colour, and on the accent swatches it would be invisible.
  final double ringInset;

  final FocusNode? focusNode;
  final bool autofocus;

  /// Pointer hover, for a control that paints a hover state of its own.
  ///
  /// Here rather than in a separate `MouseRegion` because
  /// [FocusableActionDetector] is already listening — a second region over the
  /// same box is two subscriptions reporting the same event.
  final ValueChanged<bool>? onHoverChanged;

  /// False to keep a control out of the traversal order while still announcing
  /// it. Rare, and never the answer to "this list is long".
  final bool canRequestFocus;

  @override
  State<WeftFocusable> createState() => _WeftFocusableState();
}

class _WeftFocusableState extends State<WeftFocusable> {
  /// Whether the node holds focus at all — what the semantics tree is told.
  bool _focused = false;

  /// Whether the *ring* should be drawn, which is a different question.
  ///
  /// `onShowFocusHighlight` is false while the user is driving with a finger
  /// and true once they touch a key, so a phone does not grow a ring around
  /// every row the moment something takes focus programmatically.
  bool _highlighted = false;

  bool get _enabled =>
      widget.onTap != null ||
      widget.onActivate != null ||
      widget.onLongPress != null;

  void _activate() => (widget.onActivate ?? widget.onTap)?.call();

  @override
  Widget build(BuildContext context) {
    // The annotation is the outermost widget, above the detector rather than
    // below it. Both a screen reader and `tester.getSemantics` resolve a node
    // by walking *up* from a widget's first render object, so a node buried
    // under the detector's `MouseRegion` is a node nothing asking about this
    // control ever finds — the label reads as absent while being right there
    // in the tree.
    return Semantics(
      container: true,
      excludeSemantics: widget.excludeSemantics,
      button: widget.button,
      image: widget.image,
      selected: widget.selected,
      checked: widget.checked,
      focusable: _enabled && widget.canRequestFocus,
      focused: _focused,
      // Restated because `excludeSemantics` takes the `GestureDetector`'s
      // actions with it. A control that goes quiet *and* unreachable is worse
      // than the bug being fixed.
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onLongPressHint: widget.onLongPress == null
          ? null
          : widget.onLongPressHint,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: _enabled && widget.canRequestFocus,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        mouseCursor: widget.onTap == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        // The detector's own focus semantics would be a second, unlabelled
        // node under the labelled one — and under `excludeSemantics` it would
        // not survive anyway. The flags belong on the node that carries the
        // name, so they are set there instead.
        includeFocusSemantics: false,
        onFocusChange: (value) {
          if (mounted && value != _focused) setState(() => _focused = value);
        },
        onShowFocusHighlight: (value) {
          if (mounted && value != _highlighted) {
            setState(() => _highlighted = value);
          }
        },
        onShowHoverHighlight: widget.onHoverChanged,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => _activate(),
          ),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) => _activate(),
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          behavior: HitTestBehavior.opaque,
          child: _ringed(context, widget.child),
        ),
      ),
    );
  }

  /// [child] with the focus ring painted around — not over — it.
  ///
  /// [StackFit.passthrough] hands the stack's constraints straight to the
  /// child, so the control sizes exactly as it did before it was wrapped, and
  /// `Clip.none` is what lets the ring sit outside those bounds.
  Widget _ringed(BuildContext context, Widget child) {
    if (!_highlighted) return child;
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned(
          left: -widget.ringInset,
          top: -widget.ringInset,
          right: -widget.ringInset,
          bottom: -widget.ringInset,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: widget.shape,
                borderRadius: widget.shape == BoxShape.circle
                    ? null
                    : widget.borderRadius,
                border: Border.all(color: context.palette.focusRing, width: 2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
