import Combine
import Foundation
import WatchConnectivity
#if canImport(WidgetKit)
  import WidgetKit
#endif

/// What became of a reply this watch asked the phone to send.
enum WeftWatchReplyState: Hashable {
  /// Handed to `WatchConnectivity`, no answer yet.
  case sending

  /// The phone said it sent it. The network is present only for a merged
  /// conversation, where naming the leg is the difference between a
  /// confirmation and a guess.
  case sent(network: String?)

  /// It did not go. `failure` is one of `WeftWatchProtocol`'s ids, or nil when
  /// this watch itself gave up waiting.
  case failed(failure: String?)
}

/// The watch's whole state, and its only way to reach anything.
///
/// **This device holds no Matrix session.** It renders a snapshot the phone
/// chose to send it and asks the phone to send messages on its behalf. There is
/// no homeserver here, no key material, and nothing this class can do that the
/// phone did not already agree to — which is the claim
/// `docs/architecture/companion-surfaces.md` makes and this file is the whole
/// implementation of.
///
/// ## Why the payload is cached on disk rather than held in memory
///
/// The snapshot arrives over `WatchConnectivity` and is written straight into
/// **this watch's** App Group container, through the same
/// `WeftSnapshotContainer` the phone and the widget use. Two reasons, and the
/// second is the load-bearing one:
///
/// 1. `WeftWatchComplication` is a separate process the system wakes on its own
///    schedule, with no reference to this object. A group container is how it
///    reads the same payload.
/// 2. A `WCSession` delivers the application context to a watch app that is
///    *running*. A watch whose app was killed an hour ago and whose complication
///    is on the face right now has to render something, and the honest answer is
///    the last thing the phone said — with staleness judged against the payload's
///    own `generatedAt`, which is why that field is inside the payload rather
///    than being the transport's business.
final class WeftWatchStore: NSObject, ObservableObject {
  static let shared = WeftWatchStore()

  /// The five states, as the views read them.
  @Published private(set) var state: WeftWatchState = .signedOut

  /// Every reply this launch has sent, by id.
  ///
  /// Held here rather than in the reply view, because the answer arrives from a
  /// `WCSessionDelegate` callback and the view that asked may have been swiped
  /// away by then. A wearer who dismissed the reply screen and came back finds
  /// out what happened, rather than finding a message they cannot tell was sent.
  @Published private(set) var replies: [String: WeftWatchReplyState] = [:]

  /// How long a reply waits before this side calls it failed.
  ///
  /// Longer than the phone's own two-minute queue, deliberately: the phone is
  /// allowed to hold a reply while its inbox syncs, and a watch that gave up
  /// first would show "not sent" for a message that then went. Long enough to
  /// cover that, short enough that "Sending…" is never the last thing this
  /// screen ever says.
  private let replyTimeout: TimeInterval = 3 * 60

  private override init() {
    super.init()
    refresh()
  }

  /// Activates the session. Called once, from the app's `init`.
  func activate() {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    session.delegate = self
    session.activate()
  }

  /// Re-reads the container.
  ///
  /// Called on receipt, on foreground, and on a timer — the third because
  /// **nothing writes anything when a snapshot crosses `kSnapshotStaleAfter`**.
  /// The payload simply stops being true, and a watch that only re-read on
  /// change would present yesterday's counts indefinitely.
  func refresh() {
    let next = WeftWatchState.read(now: Date())
    if next != state { state = next }
  }

  // MARK: - Replies

  /// Asks the phone to send `body` to `chatId`, and returns the id to watch.
  ///
  /// The id is minted here rather than on the phone, and it is the whole of the
  /// duplicate protection: `sendMessage` fails when the phone is unreachable and
  /// this falls back to `transferUserInfo`, which is queued and *will* arrive —
  /// so a reply sent at the edge of reachability can arrive once by each road.
  /// The phone answers a redelivery with the original result rather than sending
  /// a second message. See `WatchReplyHandler`.
  @discardableResult
  func send(chatId: String, body: String) -> String {
    let id = UUID().uuidString
    replies[id] = .sending

    let message: [String: Any] = [
      WeftWatchProtocol.replyIdKey: id,
      WeftWatchProtocol.replyChatIdKey: chatId,
      WeftWatchProtocol.replyBodyKey: body,
    ]

    guard WCSession.isSupported() else {
      finish(id, .failed(failure: WeftWatchProtocol.failureAppNotRunning))
      return id
    }
    let session = WCSession.default
    if session.isReachable {
      session.sendMessage(message, replyHandler: nil) { _ in
        // Unreachable between the check and the send. Queued instead, which is
        // slower and certain: the phone is what sends the message, and a
        // message that never reached the phone is the one failure mode this
        // path exists to make impossible.
        session.transferUserInfo(message)
      }
    } else {
      session.transferUserInfo(message)
    }

    // The phone will answer. This is what happens when it does not — a phone in
    // another room, switched off, or with Weft uninstalled.
    DispatchQueue.main.asyncAfter(deadline: .now() + replyTimeout) { [weak self] in
      guard let self, self.replies[id] == .sending else { return }
      // Nil failure: this side gave up and does not know why. The view says so
      // in those terms rather than inventing a cause.
      self.replies[id] = .failed(failure: nil)
    }
    return id
  }

  private func finish(_ id: String, _ state: WeftWatchReplyState) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.replies[id] == .sending else { return }
      self.replies[id] = state
    }
  }

  // MARK: - Receiving

  /// Applies an application context from the phone.
  ///
  /// Writes into this watch's own container rather than only into memory, for
  /// the two reasons in the type's doc, and then asks the complication to
  /// redraw. The surface flag is stored beside the payload exactly as it is on
  /// the phone, so the complication reads the same gate this app does.
  private func receive(context: [String: Any]) {
    let enabled = context[WeftWatchProtocol.watchEnabledKey] as? Bool ?? false
    let payload = context[WeftWatchProtocol.payloadKey] as? String

    if enabled, let payload, !payload.isEmpty {
      // `widgets: false` unconditionally: this is a watch, there is no Home
      // Screen on it, and the phone does not send that flag because it is not
      // this device's business.
      WeftSnapshotContainer.writePayload(payload, widgets: false, watch: true)
    } else {
      // Switched off, or signed out. Cleared rather than kept with the flag
      // down: a payload sitting in a container is a payload a future bug can
      // render, and the wearer asked for it not to be here.
      WeftSnapshotContainer.clear()
    }

    DispatchQueue.main.async { [weak self] in
      self?.refresh()
      self?.reloadComplications()
    }
  }

  private func receive(replyResult: [String: Any]) {
    guard let id = replyResult[WeftWatchProtocol.replyIdKey] as? String, !id.isEmpty else {
      // Unmatchable: a result with no id belongs to no reply. The timeout above
      // is the only mechanism that covers this, which is why it exists.
      return
    }
    let sent = replyResult[WeftWatchProtocol.resultSentKey] as? Bool ?? false
    let state: WeftWatchReplyState =
      sent
      ? .sent(network: replyResult[WeftWatchProtocol.resultNetworkKey] as? String)
      : .failed(failure: replyResult[WeftWatchProtocol.resultFailureKey] as? String)

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Ignores an id it does not know: a result for a reply sent by a previous
      // launch arrives after this map has been rebuilt empty, and resurrecting
      // it would put an outcome on screen for a message nothing is showing.
      guard self.replies[id] != nil else { return }
      self.replies[id] = state
    }
  }

  /// Asks WidgetKit to rebuild the complication's timeline.
  ///
  /// `reloadAllTimelines` rather than by kind, for the reason
  /// `WeftSnapshotChannel` gives: the kind is declared by the extension and a
  /// kind string spelled here is a string that silently stops matching.
  private func reloadComplications() {
    #if canImport(WidgetKit)
      WidgetCenter.shared.reloadAllTimelines()
    #endif
  }
}

extension WeftWatchStore: WCSessionDelegate {
  func session(
    _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?
  ) {
    guard state == .activated else { return }
    // Whatever the phone last published, applied as soon as there is a session
    // to read it through. `receivedApplicationContext` is the *stored* context
    // rather than a delivery, which is the whole reason the phone uses that API:
    // a watch app opened hours after the last publish still finds the current
    // inbox here instead of waiting for the phone to send it again.
    let context = session.receivedApplicationContext
    if !context.isEmpty { receive(context: context) }
  }

  func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
    receive(context: context)
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    receive(replyResult: message)
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    receive(replyResult: userInfo)
  }
}
