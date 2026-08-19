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
  }
}
