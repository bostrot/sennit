import AuthenticationServices
import Flutter
import Intents
import UIKit
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Reply and Mark read under a notification run without opening Sennit, in
    // an engine flutter_local_notifications starts for them. That engine needs
    // the plugins the headless Matrix stack uses; without this callback the
    // plugin starts it with none and the action dies before reaching Dart.
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// APNs answered `registerForRemoteNotifications`: the token Sennit's
  /// gateway addresses this device by. Not passed on to `super`, which would
  /// hand it to firebase_messaging's iOS half — a Firebase app this build
  /// never configures, because iOS pushes go to APNs directly.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    WeftApns.received(token: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("weft: APNs registration failed: \(error.localizedDescription)")
    WeftApns.failed()
  }

  /// SiriKit messaging, handled in-app. See `SiriIntents.swift`.
  override func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
    switch intent {
    case is INSendMessageIntent, is INSearchForMessagesIntent, is INSetMessageAttributeIntent:
      return WeftMessagesIntentHandler.shared
    default:
      return nil
    }
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
    // Siri. On the launch path because an intent is often what launched it.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WeftSiriChannel") {
      WeftSiriChannel.register(with: registrar)
    }
    // The APNs token for Sennit's push gateway. On the launch path so a
    // token iOS reissues is passed on even before Dart asks for it.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WeftApns") {
      WeftApns.register(with: registrar)
    }
    // Sign-in in the person's own browser. Costs nothing until used.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WeftBrowserAuth") {
      WeftBrowserAuth.register(with: registrar)
    }
  }
}

/// `com.bostrot.weft/apns`: the iOS end of `ApnsPushTransport`.
///
/// `token` registers with APNs and answers with the hex token, or nil when
/// iOS has not answered within ten seconds; a token that arrives or changes
/// later is sent as `tokenChanged`. `environment` reads `aps-environment`
/// from the embedded profile, so a development build registers under the
/// gateway's sandbox app id. An App Store install has no embedded profile
/// and is production.
enum WeftApns {
  private static var channel: FlutterMethodChannel?
  private static var token: String?
  private static var waiting: [FlutterResult] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.bostrot.weft/apns", binaryMessenger: registrar.messenger())
    self.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "environment":
        result(environment())
      case "token":
        if let token {
          result(token)
          return
        }
        waiting.append(result)
        UIApplication.shared.registerForRemoteNotifications()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { answer(nil) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func received(token data: Data) {
    let hex = data.map { String(format: "%02x", $0) }.joined()
    let changed = hex != token
    token = hex
    answer(hex)
    if changed { channel?.invokeMethod("tokenChanged", arguments: hex) }
  }

  static func failed() { answer(nil) }

  private static func answer(_ value: String?) {
    let pending = waiting
    waiting = []
    pending.forEach { $0(value) }
  }

  private static func environment() -> String {
    guard
      let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .isoLatin1),
      let key = text.range(of: "<key>aps-environment</key>"),
      let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
      let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex)
    else { return "production" }
    return String(text[open.upperBound..<close.lowerBound])
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

/// `com.bostrot.weft/browser_auth`: a web sign-in in Safari's own sheet, and
/// the address it finishes on. The iOS end of `BrowserAuth.kt`.
///
/// `ASWebAuthenticationSession` watches for the callback scheme itself and
/// hands the address to this session alone — the official Mattermost app's
/// `mmauth://` registration is never consulted. It shares Safari's cookies,
/// so a company SSO the person is already signed in to does not ask again.
final class WeftBrowserAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
  private static let shared = WeftBrowserAuth()

  private var session: ASWebAuthenticationSession?
  private var pending: FlutterResult?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.bostrot.weft/browser_auth", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "authenticate":
        let args = call.arguments as? [String: Any]
        guard let raw = args?["url"] as? String, let url = URL(string: raw),
          let scheme = args?["callbackScheme"] as? String
        else {
          result(FlutterError(code: "bad_args", message: "url and callbackScheme are required", details: nil))
          return
        }
        shared.authenticate(url: url, scheme: scheme, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func authenticate(url: URL, scheme: String, result: @escaping FlutterResult) {
    // A second tap while the first sheet is up abandons the first.
    session?.cancel()
    finish(nil)
    pending = result
    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) {
      [weak self] callback, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.session = nil
        if let callback {
          self.finish(callback.absoluteString)
        } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          self.finish(nil)
        } else {
          let pending = self.pending
          self.pending = nil
          pending?(FlutterError(code: "failed", message: error?.localizedDescription, details: nil))
        }
      }
    }
    session.presentationContextProvider = self
    self.session = session
    if !session.start() {
      self.session = nil
      let pending = self.pending
      self.pending = nil
      pending?(FlutterError(code: "no_browser", message: "The sign-in sheet could not open", details: nil))
    }
  }

  private func finish(_ url: String?) {
    let pending = self.pending
    self.pending = nil
    pending?(url)
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow } ?? ASPresentationAnchor()
  }
}
