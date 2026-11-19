import Flutter
import Intents

/// SiriKit messaging, handled in the app: "Read my messages", "Reply", "Send a
/// message to Anna on Sennit" and "Mark as read" — on the phone, on AirPods
/// and in CarPlay, where these three intents are the whole of a messaging app.
///
/// In-app rather than an Intents extension for the reason the notification
/// service extension does not decrypt: the Matrix client, its Olm store and
/// the merge fold live in this process, and a second process would need a
/// second client on the same database. iOS launches Sennit in the background
/// to answer, and the answer comes from Dart over `com.bostrot.weft/siri` —
/// see `lib/services/siri/siri_messaging.dart`.
///
/// **Dormant until signed with the Siri entitlement.** iOS only routes these
/// intents to an app whose signature carries `com.apple.developer.siri`, and
/// CarPlay only shows a messaging app that also carries
/// `com.apple.developer.carplay-communication`, which Apple grants on request.
/// Neither is in `Runner.entitlements` yet — see docs/car-integrations.md —
/// so in today's builds nothing here is ever called.
final class WeftSiriChannel {
  static let shared = WeftSiriChannel()

  private var channel: FlutterMethodChannel?
  /// Set when Dart has signed in and is listening. An intent that cold-started
  /// the app arrives long before that; its call waits here.
  private var ready = false
  private var waiting: [() -> Void] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.bostrot.weft/siri", binaryMessenger: registrar.messenger())
    shared.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "ready":
        shared.markReady()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func markReady() {
    ready = true
    let calls = waiting
    waiting.removeAll()
    calls.forEach { $0() }
  }

  /// Asks Dart, on the main thread, and answers [completion] exactly once:
  /// with Dart's result, or with nil when Dart is not up within [timeout] — a
  /// signed-out app, or a launch that took longer than Siri waits.
  func call(
    _ method: String, _ arguments: Any? = nil, timeout: TimeInterval = 8,
    completion: @escaping (Any?) -> Void
  ) {
    DispatchQueue.main.async {
      var answered = false
      let finish: (Any?) -> Void = { value in
        guard !answered else { return }
        answered = true
        completion(value)
      }
      let invoke = { [weak self] in
        guard let channel = self?.channel else { return finish(nil) }
        channel.invokeMethod(method, arguments: arguments) { value in
          if value is FlutterError { return finish(nil) }
          if let object = value as AnyObject?, object === FlutterMethodNotImplemented {
            return finish(nil)
          }
          finish(value)
        }
      }
      if self.ready { invoke() } else { self.waiting.append(invoke) }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
  }
}

/// The handler `AppDelegate.application(_:handlerFor:)` returns for all three.
final class WeftMessagesIntentHandler: NSObject, INSendMessageIntentHandling,
  INSearchForMessagesIntentHandling, INSetMessageAttributeIntentHandling
{
  static let shared = WeftMessagesIntentHandler()

  private let siri = WeftSiriChannel.shared

  /// Message id to conversation, from the last "read my messages". "Mark as
  /// read" names messages, and the read marker is per conversation.
  private var conversationOfMessage: [String: String] = [:]

  // MARK: Send

  func resolveRecipients(
    for intent: INSendMessageIntent,
    with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void
  ) {
    // A reply to a message Siri just read names the conversation itself.
    if let conversation = intent.conversationIdentifier, !conversation.isEmpty {
      let recipients = intent.recipients ?? []
      return completion(
        recipients.isEmpty
          ? [.success(with: Self.person(chatId: conversation, title: ""))]
          : recipients.map { .success(with: $0) })
    }
    guard let recipients = intent.recipients, !recipients.isEmpty else {
      return completion([.needsValue()])
    }

    var results = [INSendMessageRecipientResolutionResult?](
      repeating: nil, count: recipients.count)
    let group = DispatchGroup()
    for (index, recipient) in recipients.enumerated() {
      if let chatId = recipient.customIdentifier, !chatId.isEmpty {
        results[index] = .success(with: recipient)
        continue
      }
      let query = recipient.displayName
      group.enter()
      siri.call("recipients", ["query": query]) { value in
        let matches = (value as? [[String: Any]]) ?? []
        let people = matches.compactMap { match -> INPerson? in
          guard let chatId = match["chatId"] as? String else { return nil }
          return Self.person(chatId: chatId, title: match["title"] as? String ?? query)
        }
        switch people.count {
        case 0: results[index] = .unsupported()
        case 1: results[index] = .success(with: people[0])
        default: results[index] = .disambiguation(with: people)
        }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      completion(results.map { $0 ?? .unsupported() })
    }
  }

  func resolveContent(
    for intent: INSendMessageIntent,
    with completion: @escaping (INStringResolutionResult) -> Void
  ) {
    let text = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    completion(text.isEmpty ? .needsValue() : .success(with: text))
  }

  func handle(
    intent: INSendMessageIntent,
    completion: @escaping (INSendMessageIntentResponse) -> Void
  ) {
    let chatId = intent.conversationIdentifier ?? intent.recipients?.first?.customIdentifier
    guard let chatId, !chatId.isEmpty, let text = intent.content, !text.isEmpty else {
      return completion(INSendMessageIntentResponse(code: .failure, userActivity: nil))
    }
    siri.call("send", ["chatId": chatId, "text": text], timeout: 20) { value in
      let sent = (value as? Bool) == true
      completion(
        INSendMessageIntentResponse(code: sent ? .success : .failure, userActivity: nil))
    }
  }

  // MARK: Read

  func handle(
    intent: INSearchForMessagesIntent,
    completion: @escaping (INSearchForMessagesIntentResponse) -> Void
  ) {
    siri.call("unread") { [weak self] value in
      guard let rows = value as? [[String: Any]] else {
        return completion(INSearchForMessagesIntentResponse(code: .failure, userActivity: nil))
      }
      var messages: [INMessage] = []
      for row in rows {
        guard let id = row["id"] as? String, let chatId = row["chatId"] as? String else {
          continue
        }
        self?.conversationOfMessage[id] = chatId
        let title = row["title"] as? String ?? ""
        let isGroup = row["isGroup"] as? Bool ?? false
        let senderName = row["senderName"] as? String ?? title
        let sender = INPerson(
          personHandle: INPersonHandle(
            value: row["senderId"] as? String ?? chatId, type: .unknown),
          nameComponents: nil, displayName: senderName, image: nil,
          contactIdentifier: nil, customIdentifier: chatId)
        let sent = (row["timestamp"] as? NSNumber).map {
          Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        messages.append(
          INMessage(
            identifier: id, conversationIdentifier: chatId,
            content: row["text"] as? String, dateSent: sent, sender: sender,
            recipients: nil,
            groupName: isGroup ? INSpeakableString(spokenPhrase: title) : nil,
            messageType: .text))
      }
      let response = INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
      response.messages = messages
      completion(response)
    }
  }

  // MARK: Mark as read

  func resolveAttribute(
    for intent: INSetMessageAttributeIntent,
    with completion: @escaping (INMessageAttributeResolutionResult) -> Void
  ) {
    completion(intent.attribute == .read ? .success(with: .read) : .unsupported())
  }

  func handle(
    intent: INSetMessageAttributeIntent,
    completion: @escaping (INSetMessageAttributeIntentResponse) -> Void
  ) {
    let chatIds = Set((intent.identifiers ?? []).compactMap { conversationOfMessage[$0] })
    guard intent.attribute == .read, !chatIds.isEmpty else {
      return completion(INSetMessageAttributeIntentResponse(code: .failure, userActivity: nil))
    }
    siri.call("markRead", ["chatIds": Array(chatIds)], timeout: 20) { value in
      let done = (value as? Bool) == true
      completion(
        INSetMessageAttributeIntentResponse(code: done ? .success : .failure, userActivity: nil))
    }
  }

  /// A conversation as Siri carries it: the chat id rides as the custom
  /// identifier, the title is what Siri says.
  private static func person(chatId: String, title: String) -> INPerson {
    INPerson(
      personHandle: INPersonHandle(value: chatId, type: .unknown),
      nameComponents: nil, displayName: title, image: nil,
      contactIdentifier: nil, customIdentifier: chatId)
  }
}
