import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

/// How a glass layer relates to what is behind it.
enum MacGlassKind {
  /// Sidebars and source lists.
  ///
  /// The one kind that does *not* blur. Behind a sidebar is the window's own
  /// `NSVisualEffectView`, which the compositor has already blurred and
  /// saturated with the desktop behind it; a `BackdropFilter` here would be
  /// blurring Flutter's own empty pixels and costing a saveLayer a frame to do
  /// it. All this layer contributes is the tint over that material.
  sidebar,

  /// Toolbars, and any bar content scrolls beneath. Tinted toward the window
  /// so text stays legible while a photograph passes under it.
  toolbar,

  /// Popovers, menus and sheets — a panel floating over the app's own content.
  popover,
}

/// A Liquid Glass surface.
///
/// Tahoe's material is four things at once, and leaving any of them out reads
/// as "a translucent box" rather than as glass: it blurs what is behind it, it
/// *saturates* it (which is why a colourful wallpaper glows through a sidebar
/// instead of turning grey), it carries a specular highlight along its top
/// edge, and it is bounded by a hairline that is lighter at the top than at the
/// bottom. The saturation is the one most often missed and the one that does
/// the most work.
///
/// Falls back to an opaque fill when the user has asked for high contrast.
/// Flutter surfaces no "reduce transparency" flag of its own, and of the
/// switches it does surface that is the one whose intent this material would
/// otherwise defeat — the whole point of glass is that the contrast under it is
/// unknowable.
class MacGlass extends StatelessWidget {
  const MacGlass({
    super.key,
    required this.child,
    this.kind = MacGlassKind.toolbar,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.opaque = false,
    this.elevated = false,
  });

  final Widget child;
  final MacGlassKind kind;
  final BorderRadius borderRadius;

  /// Which edges get the hairline. Null means all of them, which is what a
  /// popover wants; a toolbar passes only its bottom edge.
  final Border? border;

  /// Forces the opaque fill — for a layer over content that is already opaque,
  /// where the blur would cost a saveLayer and show nothing.
  final bool opaque;

  /// Adds the drop shadow a floating panel casts. Bars do not float.
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = context.palette;
    final flat = opaque || MediaQuery.highContrastOf(context);

    final tint = _tint(context, isDark: isDark, flat: flat);
    // The tint and the highlight are two decorations, not one. A
    // `BoxDecoration` carrying both a `color` and a `gradient` paints only the
    // gradient — so expressing the specular line as this box's gradient threw
    // the tint away and left a sheet of near-transparent white, which is how a
    // dark window ended up with a white sidebar.
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: borderRadius,
        border: border ?? (flat ? null : _hairline(palette.border)),
      ),
      child: flat
          ? child
          : DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                // A single bright line along the top edge, fading out within a
                // few points — the light catching the edge of the glass.
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: isDark ? 0.06 : 0.30),
                    Colors.white.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.06],
                ),
              ),
              child: child,
            ),
    );

    // The sidebar's material is the window's, not Flutter's — see
    // [MacGlassKind.sidebar].
    if (flat || kind == MacGlassKind.sidebar) {
      return _maybeShadow(
        ClipRRect(borderRadius: borderRadius, child: decorated),
        context,
      );
    }

    return _maybeShadow(
      ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.compose(
            // Saturate *after* blurring: blurring a saturated image and
            // saturating a blurred one differ, and the second is the one that
            // keeps a wallpaper's colour instead of averaging it to grey.
            outer: _saturate(kind == MacGlassKind.sidebar ? 1.9 : 1.5),
            inner: ui.ImageFilter.blur(
              sigmaX: _blur(kind),
              sigmaY: _blur(kind),
              // Clamped, not mirrored. A blur this wide needs samples from
              // outside its own bounds, and mirroring folds the content just
              // past the edge back in — which put a lavender smear of the top
              // message across the thread's toolbar.
              tileMode: TileMode.clamp,
            ),
          ),
          child: decorated,
        ),
      ),
      context,
    );
  }

  Widget _maybeShadow(Widget child, BuildContext context) {
    if (!elevated) return child;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.55
                  : 0.22,
            ),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: child,
    );
  }

  static double _blur(MacGlassKind kind) => switch (kind) {
    MacGlassKind.sidebar => 40,
    MacGlassKind.toolbar => 32,
    MacGlassKind.popover => 48,
  };

  /// The wash over the blurred backdrop.
  ///
  /// Opaque enough that 13pt text on it clears its contrast bar against a
  /// worst-case backdrop, which is the constraint that sets these numbers —
  /// a prettier, thinner glass fails on a white photograph.
  Color _tint(
    BuildContext context, {
    required bool isDark,
    required bool flat,
  }) {
    final scheme = Theme.of(context).colorScheme;
    if (flat) {
      return switch (kind) {
        MacGlassKind.sidebar => scheme.surfaceContainerLow,
        MacGlassKind.toolbar => scheme.surface,
        MacGlassKind.popover => scheme.surfaceContainerHigh,
      };
    }
    final base = switch (kind) {
      MacGlassKind.sidebar => scheme.surfaceContainerLow,
      MacGlassKind.toolbar => scheme.surface,
      MacGlassKind.popover => scheme.surfaceContainerHigh,
    };
    final alpha = switch (kind) {
      // Heavy enough to survive its own absence. When the window has its
      // vibrancy view this reads as a tinted material with the desktop behind
      // it; when it does not — a build without the native chrome, a golden —
      // what shows through is white, and a thinner tint would put a pale
      // sidebar in a dark window and grey text on top of it.
      MacGlassKind.sidebar => isDark ? 0.90 : 0.86,
      MacGlassKind.toolbar => isDark ? 0.86 : 0.82,
      MacGlassKind.popover => isDark ? 0.88 : 0.84,
    };
    return base.withValues(alpha: alpha);
  }

  Border _hairline(Color color) =>
      Border.all(color: color.withValues(alpha: 0.55), width: 0.5);

  /// A saturation matrix, as the vibrancy filter uses it.
  static ui.ColorFilter _saturate(double amount) {
    // Luminance weights, so a fully desaturated result is the correct grey.
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final inv = 1 - amount;
    return ui.ColorFilter.matrix(<double>[
      inv * r + amount, inv * g, inv * b, 0, 0, //
      inv * r, inv * g + amount, inv * b, 0, 0, //
      inv * r, inv * g, inv * b + amount, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);
  }
}

/// A bar that content scrolls beneath, which thickens as it does.
///
/// macOS calls this the scroll edge effect: a toolbar over a list at rest is
/// almost invisible, and the moment the first row passes under it the material
/// gains its tint and its hairline. Without it a toolbar either always has a
/// separator — which is the old, heavier look — or never does, and text slides
/// under text.
class MacScrollEdge extends StatefulWidget {
  const MacScrollEdge({
    super.key,
    required this.bar,
    required this.barHeight,
    required this.child,
    this.kind = MacGlassKind.toolbar,
  });

  /// The bar itself — a toolbar, a search row, a thread header.
  final Widget bar;

  /// How tall [bar] is. Needed as a number rather than measured, because it is
  /// also the top inset the content is laid out with: the content sits *under*
  /// the bar and is padded down by exactly its height, which is what makes the
  /// first row slide beneath the glass instead of stopping short of it.
  final double barHeight;

  /// The scrolling content. Give it `padding: EdgeInsets.only(top: barHeight)`
  /// — or let [MacScrollEdge] do it, which it does for a [ScrollView].
  final Widget child;

  final MacGlassKind kind;

  @override
  State<MacScrollEdge> createState() => _MacScrollEdgeState();
}

class _MacScrollEdgeState extends State<MacScrollEdge> {
  bool _under = false;

  bool _onScroll(ScrollNotification notification) {
    // Only the vertical scrollable this bar actually covers: a horizontal
    // filter strip or a nested list would otherwise toggle the bar as it
    // scrolls, which reads as flicker. Depth 0 for the same reason — a list
    // inside a row inside the list is not what the bar is over.
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification.depth != 0) return false;
    final under = notification.metrics.extentBefore > 2;
    if (under != _under) setState(() => _under = under);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Stack(
      children: [
        Positioned.fill(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: Padding(
              padding: EdgeInsets.only(top: widget.barHeight),
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: widget.child,
              ),
            ),
          ),
        ),
        PositionedDirectional(
          top: 0,
          start: 0,
          end: 0,
          child: AnimatedContainer(
            duration: context.motion.fast,
            curve: context.motion.standard,
            height: widget.barHeight,
            // Foreground, so the hairline is painted *over* the bar rather
            // than taking half a point out of the height the caller stated —
            // which is a bar that overflows its own box by 0.5.
            foregroundDecoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: _under ? palette.divider : Colors.transparent,
                  width: 0.5,
                ),
              ),
            ),
            child: MacGlass(
              kind: widget.kind,
              // The bar's own hairline is the animated one above; a second
              // border from the glass would double it.
              border: const Border(),
              child: widget.bar,
            ),
          ),
        ),
      ],
    );
  }
}
