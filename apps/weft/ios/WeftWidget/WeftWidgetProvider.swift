import SwiftUI
import WidgetKit

/// One rendering of the shared container, at one instant.
struct WeftWidgetEntry: TimelineEntry {
  let date: Date
  let state: WeftWidgetState
}

/// The only thing in this target that touches the App Group.
///
/// ## The name collision, stated once
///
/// WidgetKit's `getSnapshot(in:completion:)` has nothing to do with
/// `InboxSnapshot`. Its "snapshot" is the single entry the system renders in the
/// widget gallery and in transient contexts; Weft's is the payload the phone
/// wrote. Both words are load-bearing in their own vocabulary and neither can be
/// renamed, so every mention below says which one it means.
///
/// ## Why the read is here
///
/// A provider runs once per reload, off the render pass, and it is the only
/// place with somewhere to put the result. A `body` that read the container
/// would re-read it every time the system re-rendered the same entry — which for
/// an accessory on the Lock Screen is often — and would do it inside a view
/// update, where there is nowhere to report a failure to. `WeftWidgetState.read`
/// is the whole of the privacy decision and it happens exactly once, here.
struct WeftWidgetProvider: TimelineProvider {
  /// How long the timeline waits before re-reading when there is nothing worth
  /// drawing.
  ///
  /// A backstop rather than the mechanism, and the same hour Android's
  /// `updatePeriodMillis` uses for the same reason: the payload is *pushed* —
  /// `WeftSnapshotChannel.reloadSurfaces` calls `reloadAllTimelines` on every
  /// write and on sign-out — so this interval only ever fires for a device where
  /// the app has not run at all. Twelve chances inside `kSnapshotStaleAfter`.
  private static let idleRefresh: TimeInterval = 60 * 60

  /// The skeleton the system draws while the real entry is being produced.
  ///
  /// WidgetKit renders this with `.redacted(reason: .placeholder)` applied for
  /// us, so what it needs is the right *shape* and no real content. It is built
  /// from `WeftSnapshotFormat.redactedTitle` rows with no previews and no sender
  /// names — the same rule the Android preview images follow: a placeholder that
  /// showed plausible invented conversations would teach the user to expect
  /// names on this surface before they had agreed to any leaving the encrypted
  /// store.
  func placeholder(in context: Context) -> WeftWidgetEntry {
    WeftWidgetEntry(date: Date(), state: .ready(Self.placeholderSnapshot))
  }

  /// WidgetKit's single-entry read, used for the gallery.
  ///
  /// Deliberately the *real* state rather than the placeholder, which is where
  /// this parts company with the Android preview images. Those are PNGs compiled
  /// into the APK and shipped to everyone, so they cannot show real
  /// conversations; this is generated live, on the user's own unlocked device,
  /// while they are the one adding the widget. Showing them what they are about
  /// to place — including "Widgets are off", which is the single most useful
  /// thing the gallery can say to someone who has not opted in — is the honest
  /// answer.
  func getSnapshot(in context: Context, completion: @escaping (WeftWidgetEntry) -> Void) {
    let now = Date()
    completion(WeftWidgetEntry(date: now, state: WeftWidgetState.read(now: now)))
  }

  /// The timeline: what to draw now, and when this stops being true.
  ///
  /// Two entries when there is a payload worth drawing, and that second one is
  /// the WidgetKit-specific piece of design in this target. The Glance provider
  /// can only re-read on a wake and so discovers staleness up to an hour late;
  /// here the moment the payload expires is *known* — `generatedAt +
  /// kSnapshotStaleAfter` — so an entry is scheduled at exactly it, carrying the
  /// `unavailable` state. The widget flips to "Open Weft on your phone" on the
  /// second, without the extension being woken at all.
  ///
  /// `.after` rather than `.atEnd` in both branches. `.atEnd` would ask to be
  /// refreshed as soon as the last entry is shown, which for the stale entry is
  /// the same instant it appears — a request the system would rightly start
  /// ignoring.
  func getTimeline(in context: Context, completion: @escaping (Timeline<WeftWidgetEntry>) -> Void) {
    let now = Date()
    let state = WeftWidgetState.read(now: now)

    guard let snapshot = state.snapshot else {
      let retry = now.addingTimeInterval(Self.idleRefresh)
      completion(Timeline(entries: [WeftWidgetEntry(date: now, state: state)], policy: .after(retry)))
      return
    }

    let expires = snapshot.staleAt
    completion(
      Timeline(
        entries: [
          WeftWidgetEntry(date: now, state: state),
          WeftWidgetEntry(date: expires, state: .unavailable),
        ],
        policy: .after(expires)))
  }

  /// Three rows of nothing, for the placeholder.
  ///
  /// `enabled` is true and `generatedAt` is now, so this lands in `ready` rather
  /// than in an empty state — a placeholder that rendered "Sign in to Weft" in
  /// skeleton grey would be a sentence nobody could read telling them something
  /// that may not be so.
  private static let placeholderSnapshot = WeftInboxSnapshot(
    version: WeftSnapshotFormat.version,
    generatedAt: Date(),
    enabled: true,
    totalUnread: 0,
    palette: [:],
    rows: (0..<3).map { index in
      WeftSnapshotRow(
        chatId: "placeholder-\(index)",
        title: WeftSnapshotFormat.redactedTitle,
        link: weftInboxURL,
        unreadCount: 0,
        unreadLabel: "0",
        networks: [],
        isMerged: false,
        preview: nil,
        senderName: nil,
        timestamp: nil)
    })
}

/// How many rows a family draws, and whether they carry a preview line.
///
/// The Android equivalent is a width threshold — `PREVIEW_MIN_WIDTH`, checked
/// against `LocalSize` — because a Glance widget is resized freely by the
/// launcher. WidgetKit families are fixed slots, so the same decision is a
/// `switch` rather than a measurement, and it comes out at the same place: the
/// narrow family drops the preview rather than showing three words and an
/// ellipsis.
///
/// Row counts are the number that fits without the last one being clipped, which
/// is a stronger constraint than it sounds: a half-drawn row on a Home Screen is
/// a conversation the user can see the top of and cannot tap.
struct WeftWidgetLayout {
  let rowCount: Int
  let showPreview: Bool
  let showHeading: Bool

  init(family: WidgetFamily) {
    switch family {
    case .systemLarge, .systemExtraLarge:
      self.init(rowCount: 6, showPreview: true, showHeading: true)
    case .systemMedium:
      self.init(rowCount: 3, showPreview: true, showHeading: false)
    default:
      // `systemSmall`, and anything a future OS adds. The narrow slot: three
      // titles and their badges, no previews, no heading — the heading would
      // cost a row and say less than the row it displaced.
      self.init(rowCount: 3, showPreview: false, showHeading: false)
    }
  }

  private init(rowCount: Int, showPreview: Bool, showHeading: Bool) {
    self.rowCount = rowCount
    self.showPreview = showPreview
    self.showHeading = showHeading
  }
}
