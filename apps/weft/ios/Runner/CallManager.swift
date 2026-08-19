import AVFoundation
import CallKit
import Flutter
import Foundation
import PushKit
import UIKit

/// iOS's end of `com.bostrot.weft/call`: CallKit, PushKit, and nothing else.
///
/// Hand-written rather than `flutter_callkit_incoming`, for the reason every
/// other bridge in this app is hand-written — `ShareChannel.swift`,
/// `SmsBridge.kt`. What that package adds over `CXProvider` is a call *UI* Weft
/// already has, an incoming-call notification iOS does not use (CallKit **is**
/// the incoming-call UI, so there is no notification to post and no category to
/// register), and a second state machine keeping its own idea of what call is in
/// progress. Weft has one of those and this phase spent three tasks testing it.
/// What is left once those are removed is this file.
///
/// ## The one rule that shapes everything here
///
/// A PushKit VoIP push **must** be answered by `reportNewIncomingCall` before
/// the push handler returns. Not "should": iOS terminates the app for missing
/// it, and repeat offences stop VoIP pushes being delivered to the app at all.
/// Dart cannot be on that path — the engine may not be running, and even when it
/// is, a homeserver sync is not a thing to do inside a callback with a deadline.
///
/// So the ordering is inverted from every other bridge in Weft: **the native
/// side reports the call first and Dart catches up.** The push wakes the app,
/// this reports a call with whatever name the push carried, Dart syncs, finds
/// the `m.call.invite` and calls `reportIncomingCall` for the same call id —
/// which lands on a call that already exists and becomes an *update* to its
/// caller name rather than a second call.
///
/// The corollary is [pushGraceSeconds]. If Dart never confirms — the push was
/// for a call already cancelled, the sync failed, the account was signed out —
/// the reported call would ring forever with nothing behind it. It is ended
/// automatically after the grace period, as a missed call.
///
/// ## Audio
///
/// CallKit owns the audio session for the length of a call: it activates one,
/// hands it over in `didActivate`, and takes it back in `didDeactivate`.
/// `flutter_webrtc` configures and drives the WebRTC audio unit itself, so this
/// file does not touch the sample rate, the buffer duration or the mode. What it
/// does do is declare the category with the options a call needs *before*
/// reporting anything, so the first ring is not routed to the media volume, and
/// forward the route back to Dart so Weft's own speaker button agrees with the
/// system's.
@objc(WeftCallManager)
final class WeftCallManager: NSObject {
  static let channelName = "com.bostrot.weft/call"

  /// How long a call reported from a VoIP push may go unconfirmed by Dart.
  ///
  /// Long enough for a cold launch, a homeserver sync and a decryption on a slow
  /// connection; short enough that a phone does not ring at nothing for a
  /// minute. The invite's own lifetime is 60 s, so anything past that would be
  /// ringing for a call the far end has already given up on.
  private static let pushGraceSeconds: TimeInterval = 20

  private let provider: CXProvider
  private let callController = CXCallController()
  private var channel: FlutterMethodChannel?
  private var voipRegistry: PKPushRegistry?

  /// The call CallKit is showing, and the UUID it knows it by.
  ///
  /// One, not a dictionary. Weft carries a single call at a time — enforced in
  /// `CallStateMachine` and again in `CallService` — and a map here would be a
  /// second, weaker opinion about that with its own way of getting out of step.
  private var currentCallId: String?
  private var currentUUID: UUID?

  /// Set while a call exists that was reported from a push and not yet
  /// confirmed by Dart. Cancelled the moment Dart reports the same call id.
  private var pushGrace: DispatchWorkItem?

  /// Whether the answer button was pressed before Dart was listening.
  ///
  /// A cold launch from the CallKit UI is the case: the user taps answer, iOS
  /// starts the app, and `CXAnswerCallAction` arrives long before the Flutter
  /// engine has a handler on the channel. Held and replayed, the same way
  /// `MainActivity` replays a cold-start share intent.
  private var pendingAction: (method: String, arguments: [String: Any])?

  @objc static let shared = WeftCallManager()

  private override init() {
    // The `localizedName` initialiser rather than the empty one, which is iOS 14
    // and Weft deploys to 13. The name is what the system call screen and the
    // call log put under the caller.
    let configuration = CXProviderConfiguration(localizedName: "Weft")
    configuration.supportsVideo = true
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    // `.generic` rather than `.phoneNumber` or `.emailAddress`: a Matrix id is
    // neither, and claiming it is one makes iOS offer a redial that dials
    // nothing. Generic handles are shown verbatim, which for `@anna:example.org`
    // is the honest thing anyway.
    configuration.supportedHandleTypes = [.generic]
    // The call log would otherwise keep a Matrix id for every call placed, on a
    // device that syncs its call history. Weft's own history is the room.
    configuration.includesCallsInRecents = true
    provider = CXProvider(configuration: configuration)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  // MARK: - Registration

  @objc static func register(with registrar: FlutterPluginRegistrar) {
    shared.attach(messenger: registrar.messenger())
  }

  private func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel

    // Replay whatever the user pressed before Dart existed. Dispatched rather
    // than sent inline so the handler above is fully installed first.
    if let pending = pendingAction {
      pendingAction = nil
      DispatchQueue.main.async { channel.invokeMethod(pending.method, arguments: pending.arguments) }
    }

    registerForVoipPushes()
  }

  /// Registers for VoIP pushes, once.
  ///
  /// **This needs its own APNs certificate.** A VoIP push is signed with a
  /// "VoIP Services" certificate, which is a different artefact from the
  /// ordinary APNs auth key `firebase_messaging` uses and cannot be derived from
  /// it — see `docs/decisions/adr-002-ios-signing-handoff.md`. Until one exists
  /// the token below is registered with nothing and no VoIP push is ever
  /// delivered; the app still takes calls perfectly well while it is in the
  /// foreground, which is what this whole file degrades to.
  private func registerForVoipPushes() {
    guard voipRegistry == nil else { return }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
  }

  // MARK: - Dart → CallKit

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "reportIncomingCall":
      guard let callId = arguments["callId"] as? String else {
        result(FlutterError(code: "bad_args", message: "callId is required", details: nil))
        return
      }
      reportIncoming(
        callId: callId,
        handle: arguments["handle"] as? String ?? callId,
        displayName: arguments["displayName"] as? String,
        video: arguments["video"] as? Bool ?? false)
      result(nil)

    case "reportOutgoingCall":
      guard let callId = arguments["callId"] as? String else {
        result(FlutterError(code: "bad_args", message: "callId is required", details: nil))
        return
      }
      reportOutgoing(
        callId: callId,
        handle: arguments["handle"] as? String ?? callId,
        displayName: arguments["displayName"] as? String,
        video: arguments["video"] as? Bool ?? false)
      result(nil)

    case "reportCallConnected":
      if let uuid = uuidFor(arguments["callId"] as? String) {
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
      }
      result(nil)

    case "reportCallEnded":
      end(
        callId: arguments["callId"] as? String,
        reason: arguments["reason"] as? String ?? "hangup")
      result(nil)

    case "updateCall":
      // Mute and hold changed inside Weft. CallKit has no "the app did this"
      // API for either — the only way to move its buttons is to request the
      // same action the user would have pressed, which comes straight back as a
      // delegate callback and is idempotent on the Dart side.
      if let uuid = uuidFor(arguments["callId"] as? String) {
        if let muted = arguments["muted"] as? Bool {
          request(CXSetMutedCallAction(call: uuid, muted: muted))
        }
        if let held = arguments["held"] as? Bool {
          request(CXSetHeldCallAction(call: uuid, onHold: held))
        }
      }
      result(nil)

    case "setProximityEnabled":
      // iOS manages this itself for a call routed to the receiver, and has done
      // since before CallKit existed. Answered rather than left to
      // `notImplemented` so the Dart side's `MissingPluginException` arm stays
      // reserved for a build with no native call code at all.
      UIDevice.current.isProximityMonitoringEnabled = arguments["enabled"] as? Bool ?? false
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func reportIncoming(
    callId: String, handle: String, displayName: String?, video: Bool
  ) {
    // Dart confirming the call the push already reported. An update, not a
    // second call — the caller's real name arriving to replace the placeholder.
    if callId == currentCallId, let uuid = currentUUID {
      pushGrace?.cancel()
      pushGrace = nil
      provider.reportCall(with: uuid, updated: update(handle: handle, displayName: displayName, video: video))
      return
    }

    prepareAudioSession(video: video)
    let uuid = UUID()
    currentCallId = callId
    currentUUID = uuid
    provider.reportNewIncomingCall(
      with: uuid,
      update: update(handle: handle, displayName: displayName, video: video)
    ) { [weak self] error in
      guard error != nil else { return }
      // Do Not Disturb, a blocked caller, or an app iOS has decided is
      // misbehaving. The call is not on screen and never will be, so it must not
      // be left as `currentCallId` — the next `reportIncomingCall` would think
      // it was an update to it.
      self?.forget(callId: callId)
    }
  }

  private func reportOutgoing(
    callId: String, handle: String, displayName: String?, video: Bool
  ) {
    prepareAudioSession(video: video)
    let uuid = UUID()
    currentCallId = callId
    currentUUID = uuid
    // `CXStartCallAction` rather than a direct report: an outgoing call has to
    // be *requested* of CallKit, which is what lets iOS refuse it — during an
    // ordinary phone call, for instance. The refusal arrives as an error here
    // and Weft's own call carries on regardless, without a system call screen.
    let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
    action.isVideo = video
    action.contactIdentifier = displayName
    request(action)
    provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
  }

  private func update(handle: String, displayName: String?, video: Bool) -> CXCallUpdate {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: handle)
    // What the lock screen shows. Falls back to the handle rather than to the
    // app name, so an unresolved caller reads as `@anna:example.org` instead of
    // "Weft" — the same rule the inbox uses.
    update.localizedCallerName = displayName ?? handle
    update.hasVideo = video
    update.supportsHolding = true
    // Weft is 1:1 only, and offering either of these on a call that cannot do
    // them puts two dead buttons on the system call screen.
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    return update
  }

  /// Ends the call CallKit is showing, mapping [reason] onto `CXCallEndedReason`.
  ///
  /// `callId` is checked rather than trusted: an end for a call that is not the
  /// current one is a late arrival, and acting on it would tear down the call
  /// that replaced it.
  private func end(callId: String?, reason: String) {
    guard let uuid = uuidFor(callId) else { return }
    let mapped: CXCallEndedReason
    switch reason {
    case "declined": mapped = .declinedElsewhere
    case "missed": mapped = .unanswered
    case "answeredElsewhere": mapped = .answeredElsewhere
    case "busy": mapped = .failed
    case "failed": mapped = .failed
    default: mapped = .remoteEnded
    }
    provider.reportCall(with: uuid, endedAt: nil, reason: mapped)
    forget(callId: callId)
    deactivateAudioSession()
  }

  private func forget(callId: String?) {
    guard callId == nil || callId == currentCallId else { return }
    pushGrace?.cancel()
    pushGrace = nil
    currentCallId = nil
    currentUUID = nil
  }

  private func uuidFor(_ callId: String?) -> UUID? {
    guard let callId, callId == currentCallId else { return nil }
    return currentUUID
  }

  private func request(_ action: CXAction) {
    callController.request(CXTransaction(action: action)) { error in
      guard let error else { return }
      NSLog("weft: CallKit refused \(type(of: action)): \(error.localizedDescription)")
    }
  }

  // MARK: - Audio session

  /// Declares the category a call needs, before anything rings.
  ///
  /// `.playAndRecord` with `.voiceChat` is what gets the call routed to the
  /// receiver at the call volume rather than to the speaker at the media volume,
  /// and `.allowBluetooth` is what makes a paired headset appear as a route at
  /// all — without it `resolveCallAudioRoute` on the Dart side would never see
  /// one to choose. The session is *declared* here and *activated* by CallKit,
  /// which is why nothing below calls `setActive(true)`.
  ///
  /// `.allowBluetooth` warns on the newest SDK, which renamed it to
  /// `.allowBluetoothHFP`. The new spelling exists only in that SDK, so adopting
  /// it would make this file fail to compile on every Xcode before it — a
  /// deprecation warning on a rename is the cheaper of the two, and the option
  /// itself is unchanged.
  private func prepareAudioSession(video: Bool) {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playAndRecord,
        mode: video ? .videoChat : .voiceChat,
        options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers])
    } catch {
      NSLog("weft: could not configure the call audio session: \(error.localizedDescription)")
    }
  }

  private func deactivateAudioSession() {
    UIDevice.current.isProximityMonitoringEnabled = false
    do {
      try AVAudioSession.sharedInstance().setActive(
        false, options: [.notifyOthersOnDeactivation])
    } catch {
      // Routine when a call ends while the session was never activated — an
      // invite that expired before it was answered.
    }
  }

  // MARK: - CallKit → Dart

  /// Sends an action to Dart, holding it when there is nothing listening yet.
  private func send(_ method: String, _ arguments: [String: Any]) {
    guard let channel else {
      pendingAction = (method, arguments)
      return
    }
    channel.invokeMethod(method, arguments: arguments)
  }
}

// MARK: - CXProviderDelegate

extension WeftCallManager: CXProviderDelegate {
  /// The system reset — a crash, or CallKit being restarted underneath the app.
  ///
  /// Every call it was showing is gone, so Dart is told to hang up rather than
  /// left driving a peer connection nothing on screen can end.
  func providerDidReset(_ provider: CXProvider) {
    if let callId = currentCallId {
      send("onHangUp", ["callId": callId])
    }
    forget(callId: nil)
    deactivateAudioSession()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let callId = currentCallId, action.callUUID == currentUUID else {
      action.fail()
      return
    }
    send("onAnswer", ["callId": callId])
    // Fulfilled immediately rather than when Dart answers. CallKit gives an
    // action five seconds and then times it out, and answering a call involves a
    // homeserver round trip and a peer connection — routinely longer. A timed-out
    // answer tears the call down from underneath a state machine that is midway
    // through accepting it, which is a far worse failure than a call screen that
    // is up a moment before media flows.
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if let callId = currentCallId {
      // Decline and hang up are the same red button to CallKit and two
      // different events on the wire — `m.call.reject` against `m.call.hangup`,
      // which show as "declined" and "call ended" in Element. Only Dart knows
      // which the call is in, so both are sent as a hangup and `CallService`
      // routes it: its own `hangUp` on a ringing call already emits a reject.
      send("onHangUp", ["callId": callId])
    }
    forget(callId: nil)
    deactivateAudioSession()
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if let callId = currentCallId {
      send("onSetMuted", ["callId": callId, "muted": action.isMuted])
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    if let callId = currentCallId {
      send("onSetHeld", ["callId": callId, "held": action.isOnHold])
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    // Weft placed this call itself; the action exists so iOS could refuse it.
    // Nothing to do but say it happened.
    action.fulfill()
  }

  /// CallKit handed the audio session over.
  ///
  /// The route is read *here* rather than on a timer because this is the first
  /// moment it is true: before activation the session reports whatever the last
  /// app to use it left behind.
  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    reportRoute(of: audioSession)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    UIDevice.current.isProximityMonitoringEnabled = false
  }

  /// Tells Dart where the sound is actually going.
  ///
  /// The names match `CallAudioRoute` on the Dart side exactly — an unknown one
  /// is dropped there rather than guessed at, so a route iOS grows later is a
  /// speaker button that does not move rather than one that lies.
  private func reportRoute(of session: AVAudioSession) {
    guard let output = session.currentRoute.outputs.first, let callId = currentCallId else {
      return
    }
    let route: String
    switch output.portType {
    case .builtInSpeaker: route = "speaker"
    case .builtInReceiver: route = "earpiece"
    case .headphones, .usbAudio, .headsetMic: route = "wiredHeadset"
    case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio: route = "bluetooth"
    default: return
    }
    send("onAudioRouteChanged", ["callId": callId, "route": route])
  }
}

// MARK: - PKPushRegistryDelegate

extension WeftCallManager: PKPushRegistryDelegate {
  func pushRegistry(
    _ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    send("onVoipToken", ["token": token])
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType
  ) {
    guard type == .voIP else { return }
    send("onVoipToken", ["token": ""])
  }

  /// A VoIP push arrived. **A call must be reported before this returns.**
  ///
  /// Whatever the gateway sent is used for the caller's name, and a placeholder
  /// stands in when it sent nothing — an `event_id_only` push carries no body by
  /// design, which is the same trade Weft's message pushes already make. Dart
  /// replaces it with the real name a moment later.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }

    let dictionary = payload.dictionaryPayload
    let callId = (dictionary["call_id"] as? String) ?? UUID().uuidString
    let handle = (dictionary["handle"] as? String) ?? (dictionary["sender"] as? String) ?? "Unknown"
    let displayName = dictionary["display_name"] as? String
    let video = (dictionary["video"] as? Bool) ?? false

    reportIncoming(callId: callId, handle: handle, displayName: displayName, video: video)

    // If Dart never confirms this call, end it. The push may be for an invite
    // that was cancelled before the phone woke, the account may be signed out,
    // or the sync may simply have failed — and a call screen ringing at nothing
    // is the one failure mode a user cannot dismiss.
    let grace = DispatchWorkItem { [weak self] in
      guard let self, self.currentCallId == callId else { return }
      self.end(callId: callId, reason: "missed")
    }
    pushGrace?.cancel()
    pushGrace = grace
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pushGraceSeconds, execute: grace)

    // Forwarded so the client can sync and find the invite this was about. Sent
    // *after* the call is reported, because nothing about this send is allowed
    // to delay that.
    send("onVoipPush", dictionary.reduce(into: [String: Any]()) { result, entry in
      if let key = entry.key as? String { result[key] = entry.value }
    })

    completion()
  }
}
