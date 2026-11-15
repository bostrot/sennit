import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The companion surfaces' container, on the same `com.bostrot.weft/snapshot`
    // channel iOS and Android answer. macOS has WidgetKit — a Weft widget in
    // Notification Center reads exactly the payload an iPhone's does — and the
    // channel code is literally the same file, a member of both `Runner`
    // targets. Until the macOS App Group is provisioned as
    // `<TeamID>.group.com.bostrot.weft` the container resolves to nil and every
    // write is answered as refused, which the writer treats as "try again",
    // not as an error. See docs/decisions/adr-002-ios-signing-handoff.md.
    //
    // No `if let` here, unlike `AppDelegate.swift` on iOS: macOS declares
    // `registrarForPlugin:` as `nonnull` and iOS as `nullable`, so the same
    // spelling is a compile error on one of the two platforms whichever one you
    // pick.
    WeftSnapshotChannel.register(
      with: flutterViewController.registrar(forPlugin: "WeftSnapshotChannel"))

    // Reading a picture off the pasteboard, which Flutter's own clipboard API
    // cannot do — it takes a format and accepts only `text/plain`. On a
    // desktop, pasting a screenshot into a chat is the ordinary way to send
    // one.
    WeftClipboardChannel.register(
      with: flutterViewController.registrar(forPlugin: "WeftClipboardChannel"))

    configureWindowChrome(around: flutterViewController)

    super.awakeFromNib()
  }

  /// Turns the stock Flutter window into a Mac window.
  ///
  /// Three things, and the app looks wrong without any one of them:
  ///
  ///  * **Full-size content.** The title bar stops being a bar and becomes the
  ///    top of the window, so the sidebar runs to the very top and the traffic
  ///    lights float over it. Sennit's toolbar reserves
  ///    `MacMetrics.trafficLightInset` for them.
  ///  * **Vibrancy behind everything.** An `NSVisualEffectView` under a
  ///    transparent Flutter view is the only way to get the real material —
  ///    the desktop, blurred and saturated by the compositor. A `BackdropFilter`
  ///    in Dart can only blur what Flutter itself has drawn, so a sidebar built
  ///    that way is glass over a wall. Sennit's sidebar is deliberately drawn
  ///    with a translucent tint and no opaque fill, which is what lets this
  ///    show through; every other pane paints itself opaque.
  ///  * **Drag by the background.** With no title bar there is nothing left to
  ///    drag the window by, and the sidebar's empty space is what a Mac user
  ///    reaches for.
  private func configureWindowChrome(around controller: FlutterViewController) {
    styleMask.insert(.fullSizeContentView)
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    // Tahoe draws no line under the toolbar; the app's own scroll-edge effect
    // is what marks the boundary, and only once something has scrolled under it.
    titlebarSeparatorStyle = .none
    isMovableByWindowBackground = true

    // Below this the three panes stop being usable rather than merely cramped:
    // 180 of sidebar, 240 of list and 300 of thread is the narrowest the layout
    // is designed for, and the height is two toolbars plus a readable list.
    minSize = NSSize(width: 720, height: 480)
    setFrameAutosaveName("BraidMainWindow")

    guard let contentView = contentView else { return }

    let vibrancy = NSVisualEffectView(frame: contentView.bounds)
    vibrancy.autoresizingMask = [.width, .height]
    // `.sidebar` rather than `.windowBackground`: it is the material the system
    // gives a source list, and it is what makes the wallpaper's colour reach
    // the window instead of a flat grey.
    vibrancy.material = .sidebar
    vibrancy.blendingMode = .behindWindow
    // Dims with the window, as every native sidebar does — a background app
    // whose sidebar still glows reads as a window that has not noticed it lost
    // focus.
    vibrancy.state = .followsWindowActiveState

    contentView.addSubview(vibrancy, positioned: .below, relativeTo: nil)

    // Without this the Flutter view paints an opaque background over the
    // material and none of the above is visible.
    controller.backgroundColor = .clear
  }
}
