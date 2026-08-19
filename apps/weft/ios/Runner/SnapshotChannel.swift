#if canImport(FlutterMacOS)
  import FlutterMacOS
#else
  import Flutter
#endif
import Foundation
#if canImport(WidgetKit)
  import WidgetKit
#endif

/// The host app's end of the snapshot container: `com.bostrot.weft/snapshot`.
///
/// One file for iOS and macOS, and a member of both `Runner` targets. The two
/// platforms differ in exactly two places — which Flutter module is imported,
/// and which OS version gates `WidgetCenter` — and neither is worth a second
/// copy of the rest. `WeftSnapshotContainer` is the layout it and every reading
/// surface agree on; `WeftSnapshotChannel` in
/// `android/app/src/main/kotlin/com/bostrot/weft/widget/SnapshotChannel.kt` is
/// the same two methods over the same channel name against a different
/// container, which is what lets the Dart side not branch on platform at all.
///
/// ## What crosses it
///
/// * `writeSnapshot(json:widgets:watch:)` — the encoded `InboxSnapshot`, plus
///   which surfaces may render it. The JSON crosses unparsed: `SnapshotCodec`
///   is the only encoder, its key names are the contract the hand-written
///   SwiftUI reader is written against, and a second description of that shape
///   here is a second thing to keep in step.
/// * `clearSnapshot()` — sign-out. Deletes rather than blanking, because an
///   absent payload is a state the surfaces render differently.
///
/// Every method answers rather than throwing. This is called from a chat-list
/// listener that runs on every message, and a `FlutterError` from a container
/// the build has no entitlement for — an unsigned CI build, a macOS target
/// whose App Group has not been team-prefixed yet — would be an exception
/// thrown into that listener several times a minute.
enum WeftSnapshotChannel {
  static let channelName = "com.bostrot.weft/snapshot"

  static func register(with registrar: FlutterPluginRegistrar) {
    // The one API difference between the two platforms that is not about
    // imports: macOS declares the registrar's messenger as a property and iOS
    // as a method, so a single spelling fails to compile on one of them.
    #if canImport(FlutterMacOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
  }

  private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "writeSnapshot":
      guard let json = arguments["json"] as? String else {
        result(FlutterError(code: "bad_args", message: "json is required", details: nil))
        return
      }
      let widgets = arguments["widgets"] as? Bool ?? false
      let watch = arguments["watch"] as? Bool ?? false
      background {
        let stored = WeftSnapshotContainer.writePayload(
          json, widgets: widgets, watch: watch)
        if stored { reloadSurfaces() }
        DispatchQueue.main.async { result(stored) }
      }

    case "clearSnapshot":
      background {
        WeftSnapshotContainer.clear()
        reloadSurfaces()
        DispatchQueue.main.async { result(nil) }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Off the platform thread, because both of these touch the filesystem.
  ///
  /// A 64 KiB atomic write is fast and is still a write, and this happens on
  /// the same thread that draws the inbox. The share channel made the same call
  /// for larger files; the reason it applies to a small one is that this
  /// happens far more often.
  private static func background(_ work: @escaping () -> Void) {
    DispatchQueue.global(qos: .utility).async(execute: work)
  }

  /// Asks WidgetKit to rebuild every timeline this app owns.
  ///
  /// `reloadAllTimelines` rather than `reloadTimelines(ofKind:)`: the kinds are
  /// declared by the widget extension, which does not exist yet and which will
  /// grow more of them, and a kind string spelled here is a string that
  /// silently stops matching. Reloading all of them costs one wake per placed
  /// widget, which is what a snapshot change is asking for anyway.
  ///
  /// The availability guard is load-bearing rather than defensive: `Runner`'s
  /// deployment target is iOS 13, one below WidgetKit's. Without it this file
  /// does not compile.
  ///
  /// The watch is *not* reloaded from here. Its payload travels by
  /// `WatchConnectivity` from the app's own session, and reaching a
  /// `WCSession` out of a channel handler on a background queue is how that
  /// gets subtly wrong.
  private static func reloadSurfaces() {
    #if canImport(WidgetKit)
      if #available(iOS 14.0, macOS 11.0, *) {
        WidgetCenter.shared.reloadAllTimelines()
      }
    #endif
  }
}
