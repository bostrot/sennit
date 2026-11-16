import Foundation

/// What a watch surface has to draw, decided once so the app and the
/// complication decide it the same way.
///
/// The five states `WeftWidgetState` has, case for case, on every platform this
/// phase touches. Four hand-written renderers of one payload is already three
/// more than anyone wants; four that disagreed about *which* states exist would
/// be worse than any of them.
///
/// ## Why this is not `WeftWidgetState` with a parameter
///
/// It very nearly is, and the difference is the reason it is not. That type
/// reads `WeftSnapshotContainer.widgetsEnabled` out of the *phone's* App Group,
/// written by the app that generated the payload. This reads `watchEnabled` out
/// of a **different device's** container, written by
/// `WeftWatchStore.receive(context:)` from a `WCSession` payload that crossed a
/// Bluetooth link — the container here is a cache of what the phone said, not
/// the thing the phone wrote. Threading a surface flag through one type would
/// have made two very different reads look like one, which is exactly the shape
/// of the Kotlin side's `WeftWidgetState` and `WeftWearState` living in two
/// Gradle modules.
///
/// The fifth state means the same thing inverted here: a payload present and
/// this surface not allowed to draw it is a **widgets-only user**, whose phone
/// published the context with the flag off and no payload in it.
enum WeftWatchState: Hashable {
  /// The phone has never published to this watch, or published a sign-out.
  case signedOut

  /// The phone is signed in and this watch may not draw.
  case switchedOff

  /// There is a payload and it cannot be presented as current: stale past
  /// `kSnapshotStaleAfter`, or unreadable. One state deliberately — a
  /// twelve-hour-old snapshot and a half-written one are the same fact to the
  /// person reading them, and the sentence for both is the phase brief's own:
  /// *open Weft on your phone*.
  case unavailable

  /// Worth drawing. `rows` may still be empty, which the content renders rather
  /// than treating as an error.
  case ready(WeftInboxSnapshot)

  /// Reads the watch's own container and decides.
  ///
  /// `now` is passed rather than read so that "is this stale" is a question that
  /// can be asked without waiting twelve hours — and so the complication can put
  /// a future entry on its timeline at the exact moment the payload expires.
  ///
  /// The order of the checks is the whole of the privacy behaviour and it runs
  /// fail-closed at every step: no payload loses to nothing, the surface flag is
  /// consulted *before* the rows are looked at, and an unreadable payload never
  /// reaches a renderer.
  static func read(now: Date, fileManager: FileManager = .default) -> WeftWatchState {
    guard let raw = WeftSnapshotContainer.readPayload(fileManager: fileManager) else {
      return .signedOut
    }
    guard WeftSnapshotContainer.watchEnabled else { return .switchedOff }
    guard let snapshot = WeftSnapshotFormat.decode(raw) else { return .unavailable }
    guard snapshot.enabled else { return .switchedOff }
    guard !snapshot.isStale(at: now) else { return .unavailable }
    return .ready(snapshot)
  }

  var snapshot: WeftInboxSnapshot? {
    if case .ready(let snapshot) = self { return snapshot }
    return nil
  }

  var rows: [WeftSnapshotRow] { snapshot?.rows ?? [] }

  /// The unread total this state may show, which is zero for every state that is
  /// not `ready`.
  ///
  /// Explicit rather than implied. The complication's entire content is this
  /// number, and "the number when we have one" is the sort of rule that gets
  /// re-derived at a call site as a sum over the visible rows — which is wrong,
  /// because `totalUnread` counts the conversations past the row cap too.
  var totalUnread: Int { snapshot?.totalUnread ?? 0 }
}

/// The sentences this watch is made of.
///
/// English literals in Swift rather than a `Localizable.strings` catalogue, the
/// same shape `WeftWidgetStrings` takes and for the same reason: the app ships
/// one language, and a catalogue for one locale is a build phase and a lookup
/// that buy nothing. Nothing here can reach the Flutter app's strings in any
/// case — this is a different *device*.
///
/// Kept word-for-word identical to `WeftWidgetStrings` and to the wear module's
/// `res/values/strings.xml` wherever the fact is the same one, because a user
/// with a widget and a watch must not be told two different things about a
/// single switch. The two places they differ are the two places the fact
/// differs: this surface is the watch, and its off-switch is spelled "Watch".
enum WeftWatchStrings {
  static let signedOutTitle = "Sign in to Sennit"
  static let signedOutBody = "Open Sennit on your phone and sign in."

  static let disabledTitle = "Watch is off"
  static let disabledBody = "Open Sennit on your phone and turn on Watch under Widgets & watch."

  static let staleTitle = "Open Sennit on your phone"
  static let staleBody = "This is out of date. Open Sennit to refresh it."

  static let emptyTitle = "No conversations"
  static let emptyBody =
    "Nothing to show yet. Conversations on excluded networks are never shown here."

  static let inboxHeading = "Recent"
  static let merged = "Merged conversation"

  static let replyDictate = "Dictate"
  static let replySending = "Sending…"
  static let replySent = "Sent"

  static let complicationDisplayName = "Sennit unread"
  static let complicationDescription =
    "How many unread messages you have, across every conversation."

  /// The headline and detail for a state.
  ///
  /// A pair rather than two functions, because the one thing that must not
  /// happen is a headline about the watch being off over a body explaining
  /// staleness.
  static func emptyState(for state: WeftWatchState) -> (title: String, body: String) {
    switch state {
    case .signedOut: return (signedOutTitle, signedOutBody)
    case .switchedOff: return (disabledTitle, disabledBody)
    case .unavailable: return (staleTitle, staleBody)
    // An enabled snapshot with no rows: an empty inbox, or one whose every
    // conversation is on an excluded network. Not an error, and phrased so that
    // it does not read as one.
    case .ready: return (emptyTitle, emptyBody)
    }
  }

  /// `3 unread messages`, pluralised. The one place a plural is formed here.
  static func unreadCount(_ count: Int) -> String {
    count == 1 ? "1 unread message" : "\(count) unread messages"
  }

  /// One sentence per `WeftWatchProtocol` failure id, and a fallback for an id
  /// this build has not heard of.
  ///
  /// **Falls through rather than switching exhaustively**, which is the one place
  /// this file is defensive on purpose. The ids are a contract shared with a
  /// phone app that updates on its own schedule; a watch app is updated late and
  /// sometimes never, so an id this build does not know has to render as "Not
  /// sent" rather than as an empty line.
  static func replyFailure(_ failure: String?) -> String {
    switch failure {
    case WeftWatchProtocol.failureUnknownChat:
      return "That conversation is no longer in Sennit."
    case WeftWatchProtocol.failureNotSignedIn:
      return "Not sent. Nobody is signed in on your phone."
    case WeftWatchProtocol.failureSendFailed:
      return "Not sent. Open Sennit on your phone to try again."
    case WeftWatchProtocol.failureTimedOut:
      return "Not sent. Your phone did not answer."
    case WeftWatchProtocol.failureOverflowed:
      return "Not sent. Too many replies at once."
    case WeftWatchProtocol.failureAppNotRunning:
      return "Not sent. Open Sennit on your phone."
    default:
      return "Not sent"
    }
  }

  /// The canned replies, in the order they are offered.
  ///
  /// The same six the wear module offers, in the same order, and ordered by how
  /// often a watch is the wrong device to be holding a conversation on: the two
  /// that end one come first. Deliberately text and deliberately short — this
  /// list is what a wearer taps when dictating out loud is the wrong thing to
  /// do, which is most of the times a watch is the device being used.
  static let cannedReplies = [
    "Yes",
    "No",
    "On my way",
    "Thanks!",
    "Can't talk right now",
    "Can I call you later?",
  ]
}
