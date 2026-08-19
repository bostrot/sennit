#if canImport(FlutterMacOS)
  import FlutterMacOS
#else
  import Flutter
#endif
import Foundation
#if canImport(WatchConnectivity)
  import WatchConnectivity
#endif

/// The host app's end of `com.bostrot.weft/watch`.
///
/// The counterpart of `WeftWatchChannel` in
/// `android/app/src/main/kotlin/com/bostrot/weft/wear/WatchChannel.kt` — same
/// channel name, same three methods, a `WCSession` instead of a `MessageClient`.
/// The Dart side (`WeftWatchBridge`) does not branch on platform.
///
/// ## Why this is a class with an instance, when `WeftSnapshotChannel` is an enum
///
/// The snapshot channel is called *by* Dart and answers. This one is called by a
/// watch, at a moment the app did not choose, through a `WCSessionDelegate` —
/// which the framework requires to be a live object, retained, activated once
/// per process. So there is a singleton, and it holds the two things a reply
/// needs: the channel to hand it to, and the session to answer over.
///
/// ## The whole file is a no-op where `WatchConnectivity` does not exist
///
/// This file is a member of both `Runner` targets and macOS has no
/// `WatchConnectivity` framework at all. Rather than a second copy or a target
/// membership that has to be remembered, the availability is a compile-time
/// branch: on macOS `register` installs a handler that answers everything, which
/// is exactly what the Dart side already expects from a platform with no watch.
final class WeftWatchChannel: NSObject {
  static let channelName = "com.bostrot.weft/watch"

  /// The one instance. Created on the launch path by `AppDelegate`.
  static let shared = WeftWatchChannel()

  private var channel: FlutterMethodChannel?

  private override init() { super.init() }

  static func register(with registrar: FlutterPluginRegistrar) {
    shared.attach(registrar: registrar)
  }

  private func attach(registrar: FlutterPluginRegistrar) {
    #if canImport(FlutterMacOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
    activate()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "reportReply":
      let arguments = call.arguments as? [String: Any] ?? [:]
      sendReplyResult(arguments)
      result(nil)

    // Sign-out. The Dart side has already failed back everything it was
    // holding; there is nothing to tear down here, because a `WCSession` is
    // activated once per process and deactivating it would mean the next
    // sign-in had no way to hear a watch at all.
    case "stopWatch":
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - WatchConnectivity

  #if canImport(WatchConnectivity)
    /// Activates the session, if this device supports one.
    ///
    /// `isSupported()` is false on iPad and on a Mac running an iOS app, and
    /// activating anyway is a runtime exception rather than a no-op — which is
    /// why the check is here and not a comment.
    private func activate() {
      guard WCSession.isSupported() else { return }
      let session = WCSession.default
      session.delegate = self
      session.activate()
      // Whatever the container already holds, pushed as soon as there is a
      // session to push it over. A watch app launched before Weft was ever
      // opened has nothing until the first inbox tick, which can be minutes
      // away — and a watch showing "sign in" to someone who is signed in is the
      // one wrong answer of the five states.
      publish()
    }

    /// Hands the current snapshot to the watch.
    ///
    /// **`updateApplicationContext`, not `sendMessage`.** The context is *state*:
    /// it is stored by the system, it survives the watch being asleep or out of
    /// range, and a watch that wakes an hour later is handed the current value
    /// with this app doing nothing. Exactly the properties the Wear side gets
    /// from a `DataItem` and for the same reason — the question a companion
    /// surface answers is "what does the inbox look like", and the answer must
    /// be current or knowably stale rather than missing.
    ///
    /// It reads the container rather than taking the payload as an argument, so
    /// that this and the file can never disagree about what the watch was told.
    /// The cost is one file read per publish, which is a publish that only
    /// happens when the snapshot actually changed.
    func publish() {
      guard WCSession.isSupported() else { return }
      let session = WCSession.default
      guard session.activationState == .activated else { return }

      var context: [String: Any] = [
        WeftWatchProtocol.watchEnabledKey: WeftSnapshotContainer.watchEnabled,
        // The Data Layer deduplicates by content and so does this: an identical
        // context dictionary is not delivered again. `SnapshotWriter` rewrites
        // an unchanged payload every three hours precisely so a surface does not
        // drift into its stale state, and without a stamp that rewrite would be
        // swallowed and the watch would go stale anyway.
        WeftWatchProtocol.updatedAtKey: Date().timeIntervalSince1970,
      ]
      // Withheld rather than blanked when the surface is off, so a watch cannot
      // render rows it was told it may not have even if it ignores the flag.
      // Fail-closed at the transport, not only at the renderer.
      if WeftSnapshotContainer.watchEnabled, let payload = WeftSnapshotContainer.readPayload() {
        context[WeftWatchProtocol.payloadKey] = payload
      }

      do {
        try session.updateApplicationContext(context)
      } catch {
        // No paired watch, no installed watch app, a session that has not
        // finished activating. All ordinary, none worth throwing into a
        // chat-list listener that runs on every message.
        NSLog("weft: watch context not delivered: \(error.localizedDescription)")
      }
    }

    private func sendReplyResult(_ arguments: [String: Any]) {
      guard WCSession.isSupported() else { return }
      let session = WCSession.default
      guard session.activationState == .activated, let id = arguments["id"] as? String else {
        return
      }

      var message: [String: Any] = [
        WeftWatchProtocol.replyIdKey: id,
        WeftWatchProtocol.resultSentKey: arguments["sent"] as? Bool ?? false,
      ]
      if let failure = arguments["failure"] as? String {
        message[WeftWatchProtocol.resultFailureKey] = failure
      }
      if let network = arguments["network"] as? String {
        message[WeftWatchProtocol.resultNetworkKey] = network
      }

      if session.isReachable {
        session.sendMessage(message, replyHandler: nil) { _ in
          // Unreachable between the check and the send. Queued instead, which
          // is slower and certain — the watch is showing "sending…" and the one
          // outcome it must never be left in is that one.
          session.transferUserInfo(message)
        }
      } else {
        session.transferUserInfo(message)
      }
    }

    /// Hands one reply to Dart.
    ///
    /// Both transports land here: `sendMessage` when the phone was reachable and
    /// `transferUserInfo` when it was not, which is precisely why the reply
    /// carries an id. A reply sent at the edge of reachability arrives once by
    /// each road, and `WatchReplyHandler` answers the second with the first's
    /// result rather than sending a second message.
    private func deliver(_ payload: [String: Any]) {
      guard let id = payload[WeftWatchProtocol.replyIdKey] as? String, !id.isEmpty,
        let chatId = payload[WeftWatchProtocol.replyChatIdKey] as? String, !chatId.isEmpty,
        let body = payload[WeftWatchProtocol.replyBodyKey] as? String,
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }

      // A `FlutterMethodChannel` must be used from the platform thread, and no
      // `WCSessionDelegate` callback arrives on it.
      DispatchQueue.main.async { [weak self] in
        guard let channel = self?.channel else {
          // No engine yet: the system woke this process for the message and Dart
          // is not up. Answered rather than dropped — the watch is showing
          // "sending…", and the honest thing is that nothing sent it.
          self?.sendReplyResult([
            "id": id, "sent": false, "failure": WeftWatchProtocol.failureAppNotRunning,
          ])
          return
        }
        channel.invokeMethod(
          "onWatchReply",
          arguments: [
            WeftWatchProtocol.replyIdKey: id,
            WeftWatchProtocol.replyChatIdKey: chatId,
            WeftWatchProtocol.replyBodyKey: body,
          ])
      }
    }
  #else
    /// macOS, and anything else without `WatchConnectivity`. Both are the
    /// answer the Dart side already expects from a platform with no watch.
    private func activate() {}
    func publish() {}
    private func sendReplyResult(_ arguments: [String: Any]) {}
  #endif
}

#if canImport(WatchConnectivity)
  extension WeftWatchChannel: WCSessionDelegate {
    func session(
      _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
      error: Error?
    ) {
      guard state == .activated else { return }
      publish()
    }

    /// The phone was paired to a different watch.
    ///
    /// Both of these are required by the protocol on iOS and both must reactivate:
    /// a session left inactive after a switch is a watch that is paired, running
    /// Weft, and never hears from the phone again.
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
      WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
      deliver(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
      deliver(userInfo)
    }
  }
#endif
