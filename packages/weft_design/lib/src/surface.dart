import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

/// The kind of machine Braid is drawing on.
///
/// Not a restatement of `defaultTargetPlatform`, and deliberately not read from
/// it at each call site. It is a *design* decision with two values, because the
/// app has two layouts: one built for a thumb on a screen you hold, and one
/// built for a pointer, a keyboard and a window you resize. iPad runs the touch
/// surface at desk size and is right to; a Mac never runs it.
///
/// Carried in the theme rather than looked up, for the reason every other
/// cross-cutting fact in this package is: a widget that asks `Platform.isMacOS`
/// cannot be golden-tested in the other case, and half of them would forget to
/// ask at all.
enum WeftSurface {
  /// Phones and tablets. Thumb reach, 48dp targets, sheets from the bottom.
  touch,

  /// macOS. Pointer, menu bar, window chrome, popovers from their anchor.
  mac,
}

/// The surface this build runs on.
///
/// Read once, at the app root, and folded into the theme — the same discipline
/// the contrast and motion settings get, and for the same reason.
///
/// Windows and Linux stay on the touch surface deliberately. Everything the
/// desktop layout is built from here is *macOS* — 13pt system type, a
/// vibrancy sidebar, traffic-light clearance, a title-bar sheet — and giving
/// Windows a Mac window would be a worse fit than giving it the phone's,
/// which at least does not claim to be native. Their own layouts are their own
/// piece of work.
WeftSurface get weftSurface =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
    ? WeftSurface.mac
    : WeftSurface.touch;

/// Which surface the theme was built for.
@immutable
class WeftSurfaceTokens extends ThemeExtension<WeftSurfaceTokens> {
  const WeftSurfaceTokens({this.surface = WeftSurface.touch});

  final WeftSurface surface;

  bool get isMac => surface == WeftSurface.mac;

  @override
  WeftSurfaceTokens copyWith({WeftSurface? surface}) =>
      WeftSurfaceTokens(surface: surface ?? this.surface);

  /// A surface has no midpoint — half a Mac is not a thing to draw — so this
  /// snaps rather than interpolating.
  @override
  WeftSurfaceTokens lerp(ThemeExtension<WeftSurfaceTokens>? other, double t) {
    if (other is! WeftSurfaceTokens) return this;
    return t < 0.5 ? this : other;
  }
}

/// macOS metrics, in points, as the platform actually uses them.
///
/// These are not tuned-by-eye numbers: a macOS sidebar row is 24pt tall, a
/// toolbar is 52pt in Tahoe's taller default, body text is 13pt and secondary
/// text 11pt. Matching them is most of what makes a window look like it belongs
/// on the system rather than like a phone screen someone widened.
abstract final class MacMetrics {
  /// Unified toolbar, title bar included. Tahoe's toolbars are taller than the
  /// 38pt of previous releases and hold their controls in floating groups.
  static const double toolbarHeight = 52;

  /// Clearance for the close/minimise/zoom buttons in a window whose title bar
  /// is hidden and whose content runs full-size. Three 12pt lights at 20pt
  /// spacing from a 20pt margin — anything narrower puts a control under them.
  static const double trafficLightInset = 78;

  /// Source list. macOS Mail sits at 220; below about 180 a two-line row stops
  /// being readable, above about 280 it is wasting the window.
  static const double sidebarWidth = 220;
  static const double sidebarMinWidth = 180;
  static const double sidebarMaxWidth = 320;

  /// Conversation list, between the sidebar and the thread.
  static const double listWidth = 300;
  static const double listMinWidth = 240;
  static const double listMaxWidth = 420;

  /// One row in the source list, and its selected capsule's radius.
  static const double sidebarRowHeight = 28;
  static const double sidebarRowRadius = 7;

  /// A two-line conversation row.
  static const double listRowRadius = 7;

  /// Toolbar controls: 28pt square is the system's icon-button size, and 22pt
  /// is the height of a toolbar search field.
  static const double controlSize = 28;
  static const double fieldHeight = 24;
  static const double controlRadius = 7;

  /// Widest a thread is allowed to get before it stops being readable.
  ///
  /// A full-window message list on a 27" display runs a bubble to 1500pt and
  /// leaves the eye travelling the whole way back for the next line. Every
  /// desktop messenger constrains this; the number is roughly 90 characters at
  /// 13pt.
  static const double readingColumn = 760;

  /// The window's own corner radius on Tahoe. Panels drawn near a corner are
  /// rounded *concentrically* with it — an inner radius equal to the outer
  /// minus the gap — which is what stops a rounded panel from looking pasted
  /// into a rounded window.
  static const double windowRadius = 12;

  /// Sheets and popovers.
  static const double popoverRadius = 12;
  static const double sheetRadius = 12;
  static const double popoverWidth = 320;
}

/// Reads the surface the theme was built for.
extension WeftSurfaceContext on BuildContext {
  WeftSurface get surface =>
      Theme.of(this).extension<WeftSurfaceTokens>()?.surface ??
      WeftSurface.touch;

  /// Whether this is the desktop layout. Read it rather than the platform.
  bool get isMac => surface == WeftSurface.mac;
}
