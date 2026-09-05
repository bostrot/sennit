import 'package:flutter/material.dart';

/// Spacing scale. A 4pt grid — every gap in Weft is one of these.
///
/// Fine at the bottom and coarse at the top, which is where the eye needs the
/// resolution: the difference between a 2pt and a 4pt gap inside a chip is
/// visible, the difference between 32 and 36 between sections is not.
///
/// [dense] is the one step that is not on the 4pt grid, and it is here because
/// the Mac's chrome is not either — see its own note. The route walk in
/// `apps/weft/integration_test/route_walk_test.dart` scans the live widget tree
/// for gaps that are not one of these, so a number added by hand shows up in
/// `docs/quality/ui-audit.md` rather than in nobody's review.
abstract final class WeftSpace {
  static const double xxs = 2;
  static const double xs = 4;

  /// The half-step between [xs] and [sm], for the Mac's denser chrome.
  ///
  /// Added in the Phase 04 audit, which found the same 6 written by hand in
  /// five places and nowhere else: a sidebar row's side inset, the gap between
  /// a sidebar row's glyph and its label, a conversation row's vertical inset
  /// in the Mac list, the toolbar search field's, and the unread badge's side
  /// padding. Every one of them is a control whose size the system dictates —
  /// a 24pt macOS row is 24pt — and rounding them to [xs] or [sm] changes
  /// controls that were measured against the platform rather than against this
  /// scale.
  ///
  /// Not a general-purpose step. If a *phone* layout wants 6, it wants [xs] or
  /// [sm] and has not decided which.
  static const double dense = 6;

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;

  /// Bottom padding for a scroll view that a floating action button sits over.
  ///
  /// Not a rhythm step like the rest of this scale — a *clearance*, and it is
  /// here because it is arithmetic rather than taste: a `FloatingActionButton`
  /// is 56 tall and `Scaffold` floats it [lg] above the bottom edge, so a list
  /// needs 56 + 16 of bottom padding before its last row clears the button, and
  /// [sm] more before the two stop touching. Any smaller and the final row of
  /// the list sits under the FAB for ever — which on a screen whose rows carry
  /// their own buttons, like the merge screen's *Unmerge*, means a control that
  /// cannot be pressed at all.
  ///
  /// Added in the Phase 10 manual walkthrough, which found the four screens
  /// with a FAB using four different bottom paddings — [md], [lg], [xl] and a
  /// hand-written `xxl * 2` — and only the last of them anywhere near enough.
  /// Use it for the scroll view under a FAB and nothing else; a section gap
  /// that wants 80 wants [huge] and has not decided why.
  static const double fabClearance = 80;
}

/// Corner radii. Weft leans soft — squircle-ish surfaces, fully round pills.
abstract final class WeftRadius {
  static const Radius xs = Radius.circular(6);
  static const Radius sm = Radius.circular(10);
  static const Radius md = Radius.circular(14);
  static const Radius lg = Radius.circular(20);
  static const Radius xl = Radius.circular(28);

  static const BorderRadius allXs = BorderRadius.all(xs);
  static const BorderRadius allSm = BorderRadius.all(sm);
  static const BorderRadius allMd = BorderRadius.all(md);
  static const BorderRadius allLg = BorderRadius.all(lg);
  static const BorderRadius allXl = BorderRadius.all(xl);
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

/// Motion tokens.
///
/// Durations are short on purpose: a messenger is used in bursts, and anything
/// over ~250ms on a routine interaction reads as lag rather than polish. The
/// springy curves are reserved for selection and entry, where the extra
/// character is noticed and welcome.
abstract final class WeftMotion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration normal = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 380);

  /// Default easing for size, colour and opacity.
  static const Curve standard = Curves.easeOutCubic;

  /// Overshoot for selection — the network rail, chips, toggles.
  static const Curve spring = Curves.easeOutBack;

  /// Deceleration for content arriving on screen.
  static const Curve enter = Curves.easeOutQuint;

  /// Per-item delay for staggered list entry.
  static const Duration stagger = Duration(milliseconds: 28);
}

/// The motion scale a widget should actually animate at.
///
/// [WeftMotion]'s constants are the *design* durations; this is the pair of
/// them with the platform's "reduce motion" switch applied. Read it through
/// `context.motion` and every transition in the app collapses to nothing when
/// the user has asked for that, without a `MediaQuery.disableAnimationsOf`
/// check at each of the sixty-odd animation sites.
///
/// Reduced motion means [Duration.zero] rather than a shorter duration: a
/// vestibular trigger is movement, not slow movement, and the accessibility
/// setting is a request for none. The curves are kept as-is because a
/// zero-length animation never samples them.
@immutable
class WeftMotionTokens extends ThemeExtension<WeftMotionTokens> {
  const WeftMotionTokens({this.reduced = false});

  /// Set from `MediaQuery.disableAnimations`.
  final bool reduced;

  Duration get instant => reduced ? Duration.zero : WeftMotion.instant;
  Duration get fast => reduced ? Duration.zero : WeftMotion.fast;
  Duration get normal => reduced ? Duration.zero : WeftMotion.normal;
  Duration get slow => reduced ? Duration.zero : WeftMotion.slow;

  /// Per-item entry delay. Zero when reduced, so a staggered list appears at
  /// once rather than marching in.
  Duration get stagger => reduced ? Duration.zero : WeftMotion.stagger;

  Curve get standard => WeftMotion.standard;
  Curve get spring => WeftMotion.spring;
  Curve get enter => WeftMotion.enter;

  @override
  WeftMotionTokens copyWith({bool? reduced}) =>
      WeftMotionTokens(reduced: reduced ?? this.reduced);

  /// Motion has no meaningful midpoint — half a disabled animation is still an
  /// animation — so this snaps rather than interpolating.
  @override
  WeftMotionTokens lerp(ThemeExtension<WeftMotionTokens>? other, double t) {
    if (other is! WeftMotionTokens) return this;
    return t < 0.5 ? this : other;
  }
}

/// Elevation as shadow, tuned to stay subtle on dark surfaces where a heavy
/// shadow just looks like grime.
abstract final class WeftShadow {
  static List<BoxShadow> low(Color shadow) => [
    BoxShadow(
      color: shadow.withValues(alpha: 0.10),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  static List<BoxShadow> medium(Color shadow) => [
    BoxShadow(
      color: shadow.withValues(alpha: 0.14),
      blurRadius: 20,
      offset: const Offset(0, 6),
    ),
  ];

  static List<BoxShadow> glow(Color accent) => [
    BoxShadow(
      color: accent.withValues(alpha: 0.35),
      blurRadius: 16,
      spreadRadius: -2,
    ),
  ];
}
