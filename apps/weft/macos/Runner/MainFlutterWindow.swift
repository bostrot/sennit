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

    super.awakeFromNib()
  }
}
