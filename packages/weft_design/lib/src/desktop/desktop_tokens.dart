import 'package:flutter/material.dart';

import '../surface.dart';

/// The metrics one desktop uses, in points, as that system actually uses them.
///
/// Three platforms share a shape — a source list, a conversation list, a
/// thread, one toolbar across the top — and disagree about almost every number
/// inside it. macOS is an 11/13 platform with 28pt sidebar rows and its window
/// controls at the leading edge; Windows reads at 14 with 36pt navigation
/// items, 4pt corners and its controls at the trailing edge; GNOME reads at 14
/// with a 47pt header bar and rounder everything. Matching those is most of
/// what makes a window belong to the system it is running on.
///
/// Held as a theme extension rather than as constants, because the answer
/// depends on which desktop and there are three. Read it through
/// `context.desktop`.
@immutable
class WeftDesktopTokens extends ThemeExtension<WeftDesktopTokens> {
  const WeftDesktopTokens({
    required this.toolbarHeight,
    required this.windowControlsInset,
    required this.sidebarWidth,
    required this.sidebarMinWidth,
    required this.sidebarMaxWidth,
    required this.listWidth,
    required this.listMinWidth,
    required this.listMaxWidth,
    required this.sidebarRowHeight,
    required this.rowRadius,
    required this.controlRadius,
    required this.controlSize,
    required this.fieldHeight,
    required this.popoverRadius,
    required this.translucent,
    required this.systemMenuBar,
    this.readingColumn = 760,
  });

  /// macOS: a tall unified toolbar, traffic lights over the leading pane, the
  /// window's own material showing through the sidebar, and a real menu bar.
  const WeftDesktopTokens.mac()
    : this(
        toolbarHeight: 52,
        // Three 12pt lights at 20pt spacing from a 20pt margin. Anything
        // narrower puts a control under the close button.
        windowControlsInset: 78,
        sidebarWidth: 220,
        sidebarMinWidth: 180,
        sidebarMaxWidth: 320,
        listWidth: 300,
        listMinWidth: 240,
        listMaxWidth: 420,
        sidebarRowHeight: 28,
        rowRadius: 7,
        controlRadius: 7,
        controlSize: 28,
        fieldHeight: 24,
        popoverRadius: 12,
        translucent: true,
        systemMenuBar: true,
      );

  /// Windows 11: Fluent's 4pt corners, a 48pt command bar under the system
  /// title bar, and roomier navigation items than a Mac's.
  ///
  /// Not translucent. Mica is a real material and it needs real native work —
  /// `DwmSetWindowAttribute` and a transparent swap chain — and a fake one
  /// drawn in Dart over the app's own pixels is a grey box pretending. Opaque
  /// is honest until that exists.
  const WeftDesktopTokens.windows()
    : this(
        toolbarHeight: 48,
        // The system draws its own title bar with minimise/maximise/close at
        // the trailing edge, so nothing has to be reserved at the leading one.
        windowControlsInset: 0,
        sidebarWidth: 260,
        sidebarMinWidth: 200,
        sidebarMaxWidth: 360,
        listWidth: 320,
        listMinWidth: 260,
        listMaxWidth: 440,
        sidebarRowHeight: 36,
        rowRadius: 4,
        controlRadius: 4,
        controlSize: 32,
        fieldHeight: 30,
        popoverRadius: 8,
        translucent: false,
        systemMenuBar: false,
      );

  /// GNOME: a header bar, rounder corners than either of the others, and no
  /// menu bar at all — the commands live behind a button in the bar.
  const WeftDesktopTokens.linux()
    : this(
        toolbarHeight: 47,
        windowControlsInset: 0,
        sidebarWidth: 240,
        sidebarMinWidth: 200,
        sidebarMaxWidth: 340,
        listWidth: 320,
        listMinWidth: 260,
        listMaxWidth: 440,
        sidebarRowHeight: 34,
        rowRadius: 8,
        controlRadius: 6,
        controlSize: 32,
        fieldHeight: 30,
        popoverRadius: 12,
        translucent: false,
        systemMenuBar: false,
      );

  /// The touch surface has no desktop chrome. Present so `context.desktop`
  /// answers on a phone rather than throwing, and never read there.
  const WeftDesktopTokens.touch()
    : this(
        toolbarHeight: 56,
        windowControlsInset: 0,
        sidebarWidth: 0,
        sidebarMinWidth: 0,
        sidebarMaxWidth: 0,
        listWidth: 0,
        listMinWidth: 0,
        listMaxWidth: 0,
        sidebarRowHeight: 48,
        rowRadius: 20,
        controlRadius: 14,
        controlSize: 48,
        fieldHeight: 48,
        popoverRadius: 20,
        translucent: false,
        systemMenuBar: false,
        readingColumn: double.infinity,
      );

  /// The tokens for the surface this build actually runs on.
  ///
  /// Two arms, not four. [WeftSurface] has only `mac` and `touch` — Windows and
  /// Linux deliberately run the touch layout, for the reason stated where the
  /// enum is declared — so there is nothing here that could be handed a
  /// `windows` or a `linux`. The token sets for those two are written and
  /// waiting above; what does not exist yet is a surface to select them with,
  /// and inventing one here to keep a switch exhaustive would be building the
  /// selection before the layout it selects.
  factory WeftDesktopTokens.forSurface(WeftSurface surface) =>
      switch (surface) {
        WeftSurface.mac => const WeftDesktopTokens.mac(),
        WeftSurface.touch => const WeftDesktopTokens.touch(),
      };

  /// Height of one pane's slice of the window-wide toolbar.
  final double toolbarHeight;

  /// Clearance the leading pane owes the window's own controls. Zero wherever
  /// the system draws them at the trailing edge.
  final double windowControlsInset;

  final double sidebarWidth;
  final double sidebarMinWidth;
  final double sidebarMaxWidth;

  final double listWidth;
  final double listMinWidth;
  final double listMaxWidth;

  final double sidebarRowHeight;

  /// A selected row's capsule, and a conversation row's.
  final double rowRadius;

  final double controlRadius;
  final double controlSize;
  final double fieldHeight;
  final double popoverRadius;

  /// Whether the window has a material behind it that the sidebar should let
  /// through. False means every pane paints itself opaque.
  final bool translucent;

  /// Whether the platform has a menu bar of its own to hang commands on. False
  /// means they go behind a button in the toolbar instead, which is what both
  /// Windows and GNOME do.
  final bool systemMenuBar;

  /// Widest a thread may run before it stops being readable — roughly ninety
  /// characters. A full-window message list on a 27" display runs a bubble to
  /// 1500pt and leaves the eye travelling the whole way back for each line.
  final double readingColumn;

  @override
  WeftDesktopTokens copyWith({
    double? toolbarHeight,
    double? windowControlsInset,
    double? sidebarWidth,
    double? sidebarMinWidth,
    double? sidebarMaxWidth,
    double? listWidth,
    double? listMinWidth,
    double? listMaxWidth,
    double? sidebarRowHeight,
    double? rowRadius,
    double? controlRadius,
    double? controlSize,
    double? fieldHeight,
    double? popoverRadius,
    bool? translucent,
    bool? systemMenuBar,
    double? readingColumn,
  }) => WeftDesktopTokens(
    toolbarHeight: toolbarHeight ?? this.toolbarHeight,
    windowControlsInset: windowControlsInset ?? this.windowControlsInset,
    sidebarWidth: sidebarWidth ?? this.sidebarWidth,
    sidebarMinWidth: sidebarMinWidth ?? this.sidebarMinWidth,
    sidebarMaxWidth: sidebarMaxWidth ?? this.sidebarMaxWidth,
    listWidth: listWidth ?? this.listWidth,
    listMinWidth: listMinWidth ?? this.listMinWidth,
    listMaxWidth: listMaxWidth ?? this.listMaxWidth,
    sidebarRowHeight: sidebarRowHeight ?? this.sidebarRowHeight,
    rowRadius: rowRadius ?? this.rowRadius,
    controlRadius: controlRadius ?? this.controlRadius,
    controlSize: controlSize ?? this.controlSize,
    fieldHeight: fieldHeight ?? this.fieldHeight,
    popoverRadius: popoverRadius ?? this.popoverRadius,
    translucent: translucent ?? this.translucent,
    systemMenuBar: systemMenuBar ?? this.systemMenuBar,
    readingColumn: readingColumn ?? this.readingColumn,
  );

  /// A platform has no midpoint — half a Mac and half a GNOME is neither — so
  /// this snaps rather than interpolating.
  @override
  WeftDesktopTokens lerp(ThemeExtension<WeftDesktopTokens>? other, double t) {
    if (other is! WeftDesktopTokens) return this;
    return t < 0.5 ? this : other;
  }
}

/// Reads the metrics of whichever desktop this is.
extension WeftDesktopContext on BuildContext {
  WeftDesktopTokens get desktop =>
      Theme.of(this).extension<WeftDesktopTokens>() ??
      WeftDesktopTokens.forSurface(surface);
}
