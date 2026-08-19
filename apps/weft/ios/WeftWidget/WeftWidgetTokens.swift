import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// `weft_design`, duplicated deliberately, for a process that has no Flutter in
/// it.
///
/// Every token in `packages/weft_design/lib/src/tokens.dart` is a Flutter type —
/// `Color`, `BorderRadius`, `Curve`, `ThemeExtension`. A WidgetKit view is
/// rendered by the system, in a process with no Flutter engine, and it cannot
/// import any of them. So the numbers are written twice, and this comment is the
/// other half of that: **`weft_design` is the source of truth**, this is a copy,
/// and a change there is a change owed here. The same bargain
/// `WeftWidgetTokens.kt` strikes on Android and `ShareContainer.swift` strikes
/// for its path constants.
///
/// ## What is *not* duplicated
///
/// **Network brand colours.** They travel in the payload as
/// `InboxSnapshot.palette` — `ChatNetwork.id` → `0xAARRGGBB` — rather than being
/// re-tabled here, because that table changes every time a network is added and
/// a stale copy on this side would render the new network in the fallback grey
/// with nothing to say it had gone wrong.
///
/// **Most of the palette.** This is the sharpest difference from the Android
/// copy, which restates a whole twenty-four-slot Material scheme. iOS has no
/// wallpaper-derived widget palette to defer to, but it does have semantic
/// colours — `.primary`, `.secondary`, the container's own material background —
/// that are already correct in light, in dark, in Increase Contrast, and in the
/// desaturated rendering mode the system uses for a tinted Home Screen. Reaching
/// past them to paint a literal grey is how a widget ends up being the one
/// rectangle on the Home Screen that ignores the user's display settings. So
/// only the *accent* is Weft's: the unread badge, which has to be Weft's indigo
/// rather than the system tint to read as the same badge the app draws.
///
/// **Motion.** The system draws these surfaces and does not animate them, so
/// `WeftMotion` has no referent on a Home Screen.
enum WeftWidgetTokens {
  // MARK: - Spacing, from `WeftSpace`'s 4pt grid

  static let spaceXS: CGFloat = 4
  static let spaceSM: CGFloat = 8
  static let spaceMD: CGFloat = 12

  // MARK: - Radii, from `WeftRadius`

  /// The badge pill. A widget's own card corner is the system's — WidgetKit
  /// clips the container itself and a second radius inside it reads as a
  /// mistake — so `WeftRadius.md` has no call site on this surface.
  static let radiusPill: CGFloat = 999

  // MARK: - Sizes

  /// Side of a network glyph dot. Small enough that four fit beside a title,
  /// large enough to stay visible in the `systemSmall` family.
  static let dot: CGFloat = 8

  /// At most this many dots beside a row.
  ///
  /// Four is past every merged conversation the app can currently produce and
  /// keeps the strip inside the width `systemSmall` has. A fifth would be
  /// dropped silently, which is why the accessibility label counts networks off
  /// the row rather than off what was drawn.
  static let maxNetworkDots = 4

  // MARK: - Type

  // WidgetKit has a real type scale and it is the system's, not Weft's: these
  // are `Font.TextStyle`s rather than point sizes so that Dynamic Type moves
  // them. The Android copy names sizes in `sp` because Glance has no `TextTheme`
  // to defer to; here there is one, and deferring is the whole point.
  static let titleFont = Font.subheadline
  static let bodyFont = Font.caption
  static let labelFont = Font.caption2

  /// The accessory's number. Rounded because it is read at a glance on a Lock
  /// Screen, and `.title` rather than a literal size because an accessory family
  /// is already scaled by the system to the complication's slot.
  static let countFont = Font.title2.weight(.semibold)

  // MARK: - Colour

  /// Weft's indigo-violet, `WeftTheme.defaultSeed` run through
  /// `ColorScheme.fromSeed` — the same two tones `res/values/colors.xml` and
  /// `res/values-night/colors.xml` hold, read out of the running app rather than
  /// eyeballed, so the badge on a widget is the badge in the app.
  static let brandPrimary = dynamic(light: 0xFF5D_5791, dark: 0xFFC6_BFFF)
  static let brandOnPrimary = dynamic(light: 0xFFFF_FFFF, dark: 0xFF2E_295F)

  /// The colour a network dot falls back to when the payload names a network
  /// this build has never heard of.
  ///
  /// Semantic rather than a literal grey, so it tracks the system's contrast
  /// settings. That fallback is also why the *count* of dots rather than their
  /// colour is what says "merged": an unknown network still gets a dot.
  static let unknownNetwork = Color.secondary

  /// `0xAARRGGBB` as a `Color`, in the sRGB space Flutter's `Color` means.
  ///
  /// Total by construction — every one of the four shifts is inside `UInt32`,
  /// which is why `decodePalette` narrows to that width rather than handing an
  /// `Int` down. A palette entry cannot make this trap.
  static func color(fromARGB argb: UInt32) -> Color {
    Color(
      .sRGB,
      red: Double((argb >> 16) & 0xFF) / 255,
      green: Double((argb >> 8) & 0xFF) / 255,
      blue: Double(argb & 0xFF) / 255,
      opacity: Double((argb >> 24) & 0xFF) / 255
    )
  }

  /// A colour that resolves itself against whichever appearance it is drawn in.
  ///
  /// A dynamic platform colour rather than an `@Environment(\.colorScheme)`
  /// branch, deliberately. WidgetKit re-renders an *archived* view hierarchy in
  /// appearances the provider never saw — a Home Screen switching to dark at
  /// sunset does not wake the extension — so a colour chosen from the
  /// environment at build time is a colour that can be wrong until the next
  /// reload. A `UIColor`/`NSColor` provider is resolved at draw time, by the
  /// process doing the drawing, which is the only way this is right for free.
  ///
  /// **watchOS resolves to the dark value and does not branch**, and that is a
  /// platform fact rather than a shortcut: there is no light mode on a watch,
  /// `UITraitCollection.userInterfaceStyle` and `UIColor(dynamicProvider:)` are
  /// both unavailable there, and the reason is a hardware one — an OLED pixel
  /// showing black is a pixel that is off, on a device whose battery is measured
  /// in hours. The wear module's `WeftWearTokens` states the same thing for the
  /// same reason and takes only the `values-night` half of the scheme.
  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    #if os(macOS)
      return Color(
        NSColor(name: nil) { appearance in
          let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          return platformColor(fromARGB: isDark ? dark : light)
        })
    #elseif os(watchOS)
      return Color(platformColor(fromARGB: dark))
    #else
      return Color(
        UIColor { traits in
          platformColor(fromARGB: traits.userInterfaceStyle == .dark ? dark : light)
        })
    #endif
  }

  #if os(macOS)
    private static func platformColor(fromARGB argb: UInt32) -> NSColor {
      NSColor(
        srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
        green: CGFloat((argb >> 8) & 0xFF) / 255,
        blue: CGFloat(argb & 0xFF) / 255,
        alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }
  #else
    private static func platformColor(fromARGB argb: UInt32) -> UIColor {
      UIColor(
        red: CGFloat((argb >> 16) & 0xFF) / 255,
        green: CGFloat((argb >> 8) & 0xFF) / 255,
        blue: CGFloat(argb & 0xFF) / 255,
        alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }
  #endif
}

extension View {
  /// The container background every widget family needs from iOS 17 on.
  ///
  /// Not cosmetic and not optional: a widget built against the iOS 17 SDK that
  /// declares no `containerBackground` is *not shown* in the Lock Screen and
  /// StandBy contexts, and Xcode emits a runtime warning for the Home Screen
  /// one. The modifier is only available from iOS 17 / macOS 14 though, and this
  /// target deploys lower, so it is applied behind the check and the older OSes
  /// keep the default background they have always drawn.
  ///
  /// `.background` as the container's own material rather than a colour: it is
  /// what makes a widget sit in the Home Screen's tint rather than on top of it,
  /// and on an accessory family the system flattens it away entirely.
  @ViewBuilder
  func weftWidgetContainerBackground() -> some View {
    if #available(iOS 17.0, macOS 14.0, *) {
      containerBackground(.fill.tertiary, for: .widget)
    } else {
      self
    }
  }
}
