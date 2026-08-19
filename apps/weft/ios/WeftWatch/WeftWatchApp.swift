import SwiftUI

/// The Weft watch app.
///
/// A list of conversations and a reply screen, and deliberately no more. There
/// is no timeline here, no history and no search: this device holds no Matrix
/// session, so everything it can show is the handful of rows the phone decided
/// to send it, and a screen that looked like more would be promising a
/// conversation it cannot open.
///
/// Single-target, `WKApplication`-style — the modern watchOS app shape, where
/// the app *is* the SwiftUI `App` and there is no separate WatchKit extension.
/// The complication is the one thing that still needs its own target, because a
/// complication is a WidgetKit extension and always will be.
@main
struct WeftWatchApp: App {
  @StateObject private var store = WeftWatchStore.shared

  /// The `WCSession` is activated once, here, on the launch path.
  ///
  /// Not lazily on the first view: the session is what the *phone* pushes into,
  /// and `receivedApplicationContext` is only readable once it has activated. A
  /// session activated when the first list appears is a list that has nothing in
  /// it for its first frames, which reads as an empty inbox rather than as a
  /// loading one.
  init() {
    WeftWatchStore.shared.activate()
  }

  var body: some Scene {
    WindowGroup {
      WeftWatchInboxView()
        .environmentObject(store)
    }
  }
}
