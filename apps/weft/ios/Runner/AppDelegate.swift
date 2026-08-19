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
  }
}
