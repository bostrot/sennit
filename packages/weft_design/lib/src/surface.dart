import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

/// The kind of machine Sennit is drawing on.
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

/// Whether this machine drives Sennit with a pointer and a hardware keyboard.
///
/// Deliberately *not* the same question as [weftSurface]. Windows and Linux
/// answer the two differently: they keep the touch layout, because the desktop
/// one is macOS down to its 13pt type and its vibrancy sidebar, but they have a
/// mouse with a right button, a scroll wheel, and a Ctrl key — and every
/// behaviour that follows from *that* is theirs too. Right-click opens the
/// context menu, hovering reveals the quick actions, swipe-to-reply stays out
/// of the way, and message text selects by dragging across it.
///
/// Read once at the app root and folded into the theme, like [weftSurface] and
/// for the same reason: three widgets had grown a private copy of this switch,
/// and none of them could be tested in the case they were written for.
bool get weftHasPointer =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };

/// Which surface the theme was built for, and what it is driven with.
@immutable
class WeftSurfaceTokens extends ThemeExtension<WeftSurfaceTokens> {
  /// [pointer] defaults to what [surface] implies — a Mac has one — so a theme
  /// built for the desktop is never accidentally built without it. Windows and
  /// Linux are the case that has to pass it: touch layout, pointer input.
  const WeftSurfaceTokens({this.surface = WeftSurface.touch, bool? pointer})
    : pointer = pointer ?? surface == WeftSurface.mac;

  final WeftSurface surface;

  /// Whether a pointer and a hardware keyboard are what arrive.
  final bool pointer;

  bool get isMac => surface == WeftSurface.mac;

  @override
  WeftSurfaceTokens copyWith({WeftSurface? surface, bool? pointer}) =>
      WeftSurfaceTokens(
        surface: surface ?? this.surface,
        pointer: pointer ?? this.pointer,
      );

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

  /// The narrowest a thread can be and still be a thread.
  ///
  /// The other two panes are fixed widths and the conversation is the
  /// `Expanded` one, so it is the pane that pays for the window being small —
  /// and nothing used to stop it paying everything. At the 720pt minimum
  /// `MainFlutterWindow.swift` enforces, a default sidebar and list left the
  /// conversation 192pt: narrower than the conversation *list* is allowed to
  /// be, and too narrow for a bubble to hold a sentence.
  ///
  /// 240 rather than the 300 the arithmetic allows, and the difference is a
  /// deliberate stopping point. `macPaneWidths` takes from the sidebar first
  /// and the list second; 240 is exactly what the sidebar alone can give up
  /// (220 → [sidebarMinWidth]) at the 720pt minimum window, so the list is
  /// never squeezed at all.
  ///
  /// Asking for 300 would have been within the arithmetic — 720 − 180 − 240 —
  /// and it drove the list to [listMinWidth], where its *own* toolbar does not
  /// fit: a focused search field grows from 120 to 180 and put that row 36
  /// points over the edge. That is a real and separate bug, reachable today by
  /// dragging the splitter to its minimum, and it is not this constant's to
  /// fix. Taking the thread from 192 to 240 without walking into it is the
  /// better trade; see `docs/quality/manual-walkthrough.md`, MW-09.
  ///
  /// Read by `macPaneWidths`.
  static const double detailMinWidth = 240;

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

  /// One row in a pop-up menu.
  ///
  /// `PopupMenuItem` defaults to `kMinInteractiveDimension` — 48 points, a
  /// thumb's target — and no theme field overrides it, so a menu of five verbs
  /// came out 240 points tall where the system's is nearer 120. Each call site
  /// has to state it.
  static const double menuItemHeight = 28;

  /// Sheets and popovers.
  static const double popoverRadius = 12;
  static const double sheetRadius = 12;
  static const double popoverWidth = 320;
}

/// Reads the surface the theme was built for.
extension WeftSurfaceContext on BuildContext {
  WeftSurfaceTokens get _surfaceTokens =>
      Theme.of(this).extension<WeftSurfaceTokens>() ??
      const WeftSurfaceTokens();

  WeftSurface get surface => _surfaceTokens.surface;

  /// Whether this is the desktop layout. Read it rather than the platform.
  bool get isMac => surface == WeftSurface.mac;

  /// Whether this is the desktop *layout* — the metrics question.
  ///
  /// Separate from [isMac] because most of what the desktop changes is not
  /// macOS-specific — a mouse lands within a pixel or two whichever system it
  /// is plugged into — and this is the question Windows and Linux will answer
  /// the same way once they have layouts of their own.
  bool get isDesktop => surface != WeftSurface.touch;

  /// Whether a pointer and a hardware keyboard are what arrive — the *input*
  /// question, which Windows and Linux already answer yes to.
  ///
  /// Ask this, not [isDesktop], for anything about how the user reaches the
  /// interface rather than how wide it is drawn: right-click menus, hover
  /// affordances, gestures that only a finger makes, and whether text is
  /// selectable by dragging across it. See [weftHasPointer].
  bool get hasPointer => _surfaceTokens.pointer;
}
