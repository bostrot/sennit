import SwiftUI
import WidgetKit

/// Total unread, on a watch face.
///
/// The smallest surface in the phase and the one with the sharpest rule: it
/// shows `InboxSnapshot.totalUnread` and never a sum over the visible rows,
/// because `totalUnread` counts the conversations past the row cap and the
/// seventeenth conversation's unread messages are still unread. The same
/// sentence appears in `InboxSnapshot`'s own doc, in `WeftWidgetState.swift` and
/// in `WeftWearState.kt`, because this is the number it is about.
///
/// **No names, ever.** A complication sits on a watch face that is on whenever
/// the wrist is up — in a meeting, on a table, in front of whoever is sitting
/// opposite. A count identifies nobody; a name identifies somebody to everyone
/// who can see the watch. That is the same split `privacySensitive()` makes on a
/// Lock Screen, made here by simply not having a variant that could carry one,
/// which is the stronger version of it: there is nothing to redact.
///
/// A complication is a WidgetKit extension, which is why this is a target of its
/// own rather than part of the watch app. It reads the same App Group container
/// the app writes from `WCSession` — see `WeftWatchStore` for why the payload is
/// cached on disk rather than held in memory, of which this process is the whole
/// second reason.
@main
struct WeftWatchComplicationBundle: WidgetBundle {
  var body: some Widget {
    WeftWatchUnreadComplication()
  }
}

struct WeftWatchUnreadComplication: Widget {
  // The corner family exists only on watchOS, and this file has to survive an
  // iOS compile too: the target itself is watchOS-only, but `flutter build
  // ios` builds the whole workspace and a bare `.accessoryCorner` fails it.
  private static var families: [WidgetFamily] {
    #if os(watchOS)
      return [
        .accessoryCircular, .accessoryCorner, .accessoryInline,
        .accessoryRectangular,
      ]
    #else
      return [.accessoryCircular, .accessoryInline, .accessoryRectangular]
    #endif
  }

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "WeftWatchUnread", provider: WeftWatchComplicationProvider()) { entry in
      WeftWatchComplicationView(entry: entry)
        .weftWidgetContainerBackground()
    }
    .configurationDisplayName(WeftWatchStrings.complicationDisplayName)
    .description(WeftWatchStrings.complicationDescription)
    .supportedFamilies(Self.families)
  }
}

struct WeftWatchComplicationEntry: TimelineEntry {
  let date: Date
  let state: WeftWatchState
}

/// Reads the container once per reload and hands the result to the view.
///
/// The read belongs here rather than in a `body`: a `body` that read the
/// container would re-read it every time the system re-rendered the same entry,
/// which for a complication on an always-on face is very often.
struct WeftWatchComplicationProvider: TimelineProvider {
  /// The skeleton, drawn while the real entry is produced.
  ///
  /// Zero rather than an invented number. A placeholder showing "7" would flash
  /// a count the wearer has no messages behind, and on this surface the count
  /// *is* the content — there is nothing else on screen for them to tell it
  /// apart from.
  func placeholder(in context: Context) -> WeftWatchComplicationEntry {
    WeftWatchComplicationEntry(date: Date(), state: .signedOut)
  }

  /// The complication gallery, and it shows the **real** state.
  ///
  /// Generated live, on the wearer's own unlocked watch, while they are the one
  /// adding it — unlike the Android tile's preview, which is a drawable compiled
  /// into the APK and shipped to everyone. "Watch is off" is the single most
  /// useful thing a gallery can say to someone who has not opted in.
  func getSnapshot(in context: Context, completion: @escaping (WeftWatchComplicationEntry) -> Void)
  {
    let now = Date()
    completion(WeftWatchComplicationEntry(date: now, state: WeftWatchState.read(now: now)))
  }

  /// Two entries: now, and the exact instant the payload expires.
  ///
  /// The stale flip is *exact* here for the reason it is exact in
  /// `WeftSnapshotProvider` and cannot be on Glance or on a Wear tile: WidgetKit
  /// takes a timeline rather than polling, and `generatedAt + kSnapshotStaleAfter`
  /// is a known moment. The complication stops showing a count it cannot vouch
  /// for on the second, with this extension never woken.
  func getTimeline(
    in context: Context, completion: @escaping (Timeline<WeftWatchComplicationEntry>) -> Void
  ) {
    let now = Date()
    let state = WeftWatchState.read(now: now)
    var entries = [WeftWatchComplicationEntry(date: now, state: state)]

    if let snapshot = state.snapshot, snapshot.staleAt > now {
      entries.append(
        WeftWatchComplicationEntry(date: snapshot.staleAt, state: .unavailable))
    }
    // `.never` rather than an interval: the phone pushes, through
    // `WeftWatchStore.reloadComplications`. A watch that polls a container
    // nothing is writing is a watch spending battery to read the same file.
    completion(Timeline(entries: entries, policy: .never))
  }
}

/// The count, in whichever slot the face gave it.
///
/// Four families and one number. `accessoryInline` is a single line of text the
/// face renders in its own font, so it says the whole sentence; the other three
/// have a shape of their own and get the number with a word under it where there
/// is room.
struct WeftWatchComplicationView: View {
  let entry: WeftWatchComplicationEntry

  @Environment(\.widgetFamily) private var family

  private var label: String {
    WeftSnapshotFormat.unreadLabel(entry.state.totalUnread)
  }

  var body: some View {
    switch family {
    case .accessoryInline:
      Text(WeftWatchStrings.unreadCount(entry.state.totalUnread))
    case .accessoryRectangular:
      HStack(spacing: WeftWidgetTokens.spaceXS) {
        Text(label)
          .font(WeftWidgetTokens.countFont)
          .foregroundStyle(WeftWidgetTokens.brandPrimary)
        Text(WeftWatchStrings.unreadCount(entry.state.totalUnread))
          .font(WeftWidgetTokens.labelFont)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
    default:
      // Circular and corner. The number alone: both slots are small enough that
      // a word under it is a word nobody reads, and the accessibility label is
      // where the sentence goes instead.
      Text(label)
        .font(WeftWidgetTokens.countFont)
        .minimumScaleFactor(0.6)
        .accessibilityLabel(WeftWatchStrings.unreadCount(entry.state.totalUnread))
    }
  }
}
