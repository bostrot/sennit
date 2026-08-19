import Foundation

/// What a widget has to draw, decided once so every family decides it the same
/// way.
///
/// `InboxSnapshot`'s doc names three states a surface must tell apart — signed
/// out, switched off, nothing to show — and the codec adds a fourth by making
/// staleness a first-class fact. This is those four, plus the one the Dart side
/// cannot have: **the payload exists and this Home Screen is not allowed to read
/// it**, which is a watch-only user. All five are rendered, none is blank.
///
/// The Swift mirror of `WeftWidgetState.kt`, deliberately case-for-case. Two
/// hand-written renderers of one payload are already one more than anyone wants;
/// two renderers that disagree about *which* five states exist would be worse
/// than either.
///
/// Deciding this outside the SwiftUI views is not tidiness. A `TimelineProvider`
/// is where the file read belongs — it runs once per reload, off the render
/// pass, and it is the only place with somewhere to put the result. A `body`
/// that read the container would re-read it every time the system re-rendered
/// the same entry, which for an accessory on the Lock Screen is often.
enum WeftWidgetState: Hashable {
  /// No payload at all. The writer deletes it on logout, so this means "nobody
  /// is signed in" rather than "nothing has happened yet".
  case signedOut

  /// Signed in, and this surface may not draw.
  ///
  /// Two ways to get here and one message, because they are one fact to the
  /// person looking at the widget: the payload says `enabled` false (both
  /// surfaces off in Settings), or the payload is fine but
  /// `WeftSnapshotContainer.widgetsEnabled` is false (the watch is on and the
  /// Home Screen is not). Either way the honest thing is to say so and name the
  /// setting, rather than show a sign-in prompt to someone who is already signed
  /// in.
  case switchedOff

  /// There is a payload and it cannot be presented as current.
  ///
  /// Stale past `kSnapshotStaleAfter`, or unreadable. Deliberately one state: a
  /// twelve-hour-old snapshot and a half-written one are both "these counts are
  /// not the truth", and there is nothing a widget can offer for either except
  /// the same sentence.
  case unavailable

  /// A snapshot worth drawing. `rows` may still be empty — an inbox with no
  /// conversations, or one whose every conversation is on an excluded network —
  /// and that is a state the content renders, not an error.
  case ready(WeftInboxSnapshot)

  /// Reads the shared container and decides.
  ///
  /// `now` is passed rather than read so that "is this stale" is a question that
  /// can be asked without waiting twelve hours — the same reason `buildSnapshot`
  /// takes a `now`, and the reason the provider can put a *future* entry on the
  /// timeline at the exact moment the payload expires.
  ///
  /// The order of the checks is the whole of the privacy behaviour, and it runs
  /// fail-closed at every step: no payload loses to nothing, an unreadable
  /// payload never reaches a renderer, and the surface flag is consulted
  /// *before* the rows are looked at rather than after.
  static func read(now: Date, fileManager: FileManager = .default) -> WeftWidgetState {
    guard let raw = WeftSnapshotContainer.readPayload(fileManager: fileManager) else {
      return .signedOut
    }
    guard WeftSnapshotContainer.widgetsEnabled else { return .switchedOff }
    guard let snapshot = WeftSnapshotFormat.decode(raw) else { return .unavailable }
    guard snapshot.enabled else { return .switchedOff }
    guard !snapshot.isStale(at: now) else { return .unavailable }
    return .ready(snapshot)
  }

  /// The snapshot when there is one worth drawing, nil otherwise.
  var snapshot: WeftInboxSnapshot? {
    if case .ready(let snapshot) = self { return snapshot }
    return nil
  }

  /// Whether there is at least one conversation to render.
  ///
  /// `ready` with no rows is deliberately *not* content: it falls through to the
  /// empty state, which has a phrasing for it that does not read as a failure.
  var hasRows: Bool { !(snapshot?.rows.isEmpty ?? true) }

  /// The unread total this state may show, which is zero for every state that is
  /// not `ready`.
  ///
  /// Explicit rather than implied. The accessory's whole content is a number,
  /// and "the number when we have one, otherwise nothing" is the sort of rule
  /// that gets re-derived at the call site as `snapshot?.totalUnread ?? 0` and
  /// then quietly changed to sum the visible rows.
  var totalUnread: Int { snapshot?.totalUnread ?? 0 }
}

/// The sentences every empty state is made of.
///
/// English literals in Swift rather than a `Localizable.strings` catalogue,
/// which is the same shape the Android side takes (`res/values/strings.xml`, no
/// `values-<lang>` siblings): the app itself ships one language today, and a
/// catalogue for one locale is a build phase and a lookup that buy nothing.
/// Nothing here can reach the Flutter app's strings in any case — WidgetKit
/// renders this, and there is no engine in the process — so this duplicates the
/// localisation *mechanism* and not any string. No sentence below appears
/// anywhere in the Flutter app.
///
/// Kept word-for-word identical to `res/values/strings.xml`'s `weft_widget_*`
/// entries, with "Home screen" as the only edit — it is the platform's own name
/// for the surface, and it is capitalised differently on each.
enum WeftWidgetStrings {
  static let signedOutTitle = "Sign in to Weft"
  static let signedOutBody = "Open Weft and sign in to see your conversations here."

  static let disabledTitle = "Widgets are off"
  static let disabledBody =
    "Open Weft and turn on Home Screen widgets under Widgets & watch."

  static let staleTitle = "Open Weft on your phone"
  static let staleBody = "This is out of date. Open Weft to refresh it."

  static let emptyTitle = "No conversations"
  static let emptyBody =
    "Nothing to show yet. Conversations on excluded networks are never shown here."

  static let inboxHeading = "Recent"
  static let unreadLabel = "unread"
  static let merged = "Merged conversation"

  static let inboxDisplayName = "Weft conversations"
  static let inboxDescription = "Your most recent conversations. Tap one to open it."
  static let unreadDisplayName = "Weft unread"
  static let unreadDescription =
    "How many unread messages you have, across every conversation."

  /// The headline and detail for a state, or nil when the state has rows to draw
  /// instead.
  ///
  /// Returns a pair rather than being two functions, because the one thing that
  /// must not happen is a widget headlining "Widgets are off" over the body that
  /// explains staleness.
  static func emptyState(for state: WeftWidgetState) -> (title: String, body: String) {
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

  /// `3 unread messages`, pluralised.
  ///
  /// Android gets this from a `<plurals>` resource; Foundation's equivalent is a
  /// `.stringsdict`, which is a second resource file for one rule in one
  /// language. Spelled out here instead, and it is the only place a plural is
  /// formed on this surface.
  static func unreadCount(_ count: Int) -> String {
    count == 1 ? "1 unread message" : "\(count) unread messages"
  }
}
