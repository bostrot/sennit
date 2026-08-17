import UserNotifications

/// The iOS notification service extension: the only place an `event_id_only`
/// push can be turned into readable text while Weft is not running.
///
/// **This target is registered and built, and does not decrypt.** Phase 04
/// added it to `Runner.xcodeproj` alongside the Share Extension; what is still
/// outstanding is a provisioning profile for
/// `com.bostrot.weft.NotificationService`, which no repository can hold. See
/// the README beside this file, and
/// `docs/decisions/adr-002-ios-signing-handoff.md`. Until the decryption work
/// below is done, iOS shows the placeholder alert from `kIosDefaultPayload`
/// with the shape improvements made here, and the real notification is posted
/// when the app next runs.
///
/// ## Why an extension is required at all
///
/// Weft registers its pusher with `format: event_id_only`, so the homeserver
/// tells the gateway only *that* something happened: a room id, an event id, a
/// count. That is the entire point — the alternative hands every message body to
/// the push gateway and to Apple. The cost lands here: the payload has no text,
/// so something on the device has to fetch the event and decrypt it before there
/// is anything to display, and on iOS the app is not running to do it.
///
/// `mutable-content: 1` in the pusher's `default_payload` is what gives this
/// extension its chance. iOS then allows roughly 30 seconds and a modest memory
/// budget; overrun and [serviceExtensionTimeWillExpire] fires and the
/// placeholder is shown instead.
///
/// ## What finishing it requires, in the order the problems appear
///
/// 1. **An App Group.** The extension is a separate process with its own
///    container. It cannot read the Runner's Matrix store unless both are in the
///    same group and the database has been moved there.
/// 2. **A second vodozemac initialisation.** `WeftMatrixSession._ensureVodozemac`
///    caches init process-wide because flutter_rust_bridge throws on a second
///    call *in one process*. This is a different process, so it needs its own
///    init — and its own database handle, opened read/write against a store the
///    app may have open at the same moment. That concurrency, not the crypto, is
///    the hard part.
/// 3. **A decision about Olm sessions.** Decrypting here consumes ratchet state.
///    If the extension advances a session the app does not know about, the app
///    can be left unable to decrypt the same event later. Sharing the store is
///    what makes this safe, which is why (1) comes first.
///
/// A build that has not solved (2) should leave this extension doing exactly
/// what it does below: improve the *shape* of the notification from the payload
/// alone, and let the app post the real one when it next runs. A wrong
/// notification is worse than a vague one.
class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    let content = request.content.mutableCopy() as? UNMutableNotificationContent
    bestAttempt = content

    guard let content else {
      contentHandler(request.content)
      return
    }

    let info = request.content.userInfo

    // The thread identifier is the one thing that can be set correctly without
    // decrypting anything, and it is the one that matters most: it must equal
    // `notificationGroupKey(chat)` — `Chat.id` — or a merged contact's two legs
    // stack as two conversations on iOS while stacking as one on Android.
    //
    // Only the room id is in the payload, and a room is a *leg*. Grouping by it
    // is therefore wrong for a merged contact and right for everyone else,
    // which is the best an extension with no access to the merge fold can do —
    // and the reason the app re-posts with the real key when it runs.
    if let roomId = info["room_id"] as? String {
      content.threadIdentifier = roomId
    }
    content.categoryIdentifier = "weft.message"

    // The event id travels through to the app so a tap can be resolved and so
    // the dedupe ledger recognises the message it has already decided on.
    if let eventId = info["event_id"] as? String {
      content.userInfo["weft_event_id"] = eventId
    }

    // Deliberately *not* "1 new message": the count in the payload is the
    // homeserver's unread total at push time, which is stale the moment the
    // user reads on another device.
    content.body = content.body.isEmpty ? "New message" : content.body

    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    // Out of time. Show what there is rather than nothing — iOS will otherwise
    // deliver the original payload, which is the same placeholder without the
    // thread identifier.
    if let contentHandler, let bestAttempt {
      contentHandler(bestAttempt)
    }
  }
}
