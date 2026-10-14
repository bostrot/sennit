import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The Share Extension's drain. Registered here rather than lazily because a
    // share staged before this launch is drained *on* this launch, and Dart asks
    // for it in the first post-frame callback.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WeftShareChannel") {
      WeftShareChannel.register(with: registrar)
    }
    // CallKit and PushKit. Registered on the launch path rather than when the
    // first call happens, and the reason is PushKit: the VoIP registry has to
    // exist before a push can be delivered to it, and the push that matters most
    // is the one that arrives while Weft is not running. Registering lazily would
    // mean the first incoming call after every launch is the one that is missed.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WeftCallManager") {
      WeftCallManager.register(with: registrar)
    }
    // The companion surfaces' container. Registered on the launch path like the
    // two above, and for a smaller version of the same reason: the first thing
    // the app does once the session is ready is write a snapshot, and a channel
    // registered lazily would answer that first write with
    // `MissingPluginException` — which the Dart side reads as "this platform
    // has no surfaces" and would not retry until the inbox next changed.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WeftSnapshotChannel") {
      WeftSnapshotChannel.register(with: registrar)
    }
    // The watch. Registered here for a stronger version of the reason above and
    // one of its own: this one *activates the `WCSession`*, and a reply dictated
    // on a wrist can be what launches this process — so a session activated
    // lazily is a reply delivered to nobody. It also pushes whatever the
    // container already holds the moment the session comes up, which is what
    // stops a watch app opened before Weft from showing a sign-in prompt to
    // someone who is signed in.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WeftWatchChannel") {
      WeftWatchChannel.register(with: registrar)
    }
    // Long jobs the user started — a backup, a restore, uploads. Lazily would
    // do, but every other channel is here and this one costs nothing until used.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WeftBackgroundWork") {
      WeftBackgroundWork.register(with: registrar)
    }
  }
}

/// `com.bostrot.weft/background_work`: the iOS end of `IosBackgroundWorkHost`.
///
/// `begin` asks for the background time iOS grants a task in progress, so a
/// backup or an upload started just before the user switched away finishes
/// instead of freezing mid-file; `end` hands it back. When iOS runs out of
/// patience first, the expiration handler ends the task itself — an assertion
/// held past its expiry gets the whole app killed.
enum WeftBackgroundWork {
  private static var task: UIBackgroundTaskIdentifier = .invalid

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.bostrot.weft/background_work", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "begin":
        let name = (call.arguments as? [String: Any])?["name"] as? String
        begin(name: name ?? "Background work")
        result(nil)
      case "end":
        end()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func begin(name: String) {
    guard task == .invalid else { return }
    task = UIApplication.shared.beginBackgroundTask(withName: name) { end() }
  }

  private static func end() {
    guard task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(task)
    task = .invalid
  }
}
