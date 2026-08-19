import SwiftUI
import WidgetKit

/// Weft's WidgetKit extension: everything Weft can show while it is not running.
///
/// ## Why this holds no session
///
/// A widget extension is a separate process with its own container, its own
/// (small) memory ceiling, and no Matrix session — the session lives in the host
/// app's keychain and its sync loop in the host app's process, and there is no
/// supported way to run a second one here without two clients racing on the same
/// Olm ratchet state. It is the same argument the Share Extension and the
/// notification service extension make, and it applies here with less nuance
/// still, because this process is started by the system at moments the user
/// never chose.
///
/// So the whole of what this target does is: read one JSON file out of the App
/// Group, decide which of five states it is in, and draw. It never decrypts, it
/// never fetches, and it never writes. `packages/weft_snapshot` is the contract
/// it reads — **hand-written on this side**, with no compiler checking the key
/// names against the Dart class, which is why `SnapshotPayload.swift` spells
/// every key once at the top.
///
/// ## The bundle
///
/// | Widget | Kind | Families |
/// | --- | --- | --- |
/// | `WeftInboxWidget` | `WeftInbox` | small, medium, large |
/// | `WeftUnreadWidget` | `WeftUnread` | the Lock Screen accessories, iOS only |
///
/// Neither kind string is named by the writer. `WeftSnapshotChannel` reloads
/// with `reloadAllTimelines()` rather than `reloadTimelines(ofKind:)` precisely
/// so that adding a third widget here is a change to one file — a kind spelled
/// on the app side is a string that silently stops matching.
@main
struct WeftWidgetBundle: WidgetBundle {
  var body: some Widget {
    WeftInboxWidget()
    // Lock Screen accessories are an iOS surface. macOS has no complication
    // slots to put one in, and `WidgetFamily.accessory*` does not exist there —
    // this is a compile-time exclusion rather than an empty `supportedFamilies`.
    #if os(iOS)
      WeftUnreadWidget()
    #endif
  }
}

// MARK: - The inbox list

/// Recent conversations, in the order the inbox put them.
///
/// **Not re-sorted here**, and that is the one thing this file must not be
/// tempted into. `InboxSnapshot.rows` arrives in the order the app's own chat
/// list decided — pinned first, then activity — and a companion surface showing
/// a different top three than the app it companions is a bug the user reads as
/// the app being wrong about their messages. There is no `sorted` in this file
/// and there should never be one.
struct WeftInboxWidget: Widget {
  static let kind = "WeftInbox"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: WeftWidgetProvider()) { entry in
      WeftInboxWidgetView(entry: entry)
    }
    .configurationDisplayName(WeftWidgetStrings.inboxDisplayName)
    .description(WeftWidgetStrings.inboxDescription)
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

struct WeftInboxWidgetView: View {
  @Environment(\.widgetFamily) private var family

  let entry: WeftWidgetEntry

  var body: some View {
    let layout = WeftWidgetLayout(family: family)
    Group {
      // Everything that is not a populated snapshot is a sentence, not a blank
      // rectangle. `ready` with no rows falls in here too — see
      // `WeftWidgetStrings.emptyState`, which has a phrasing for it that does
      // not read as a failure.
      if let snapshot = entry.state.snapshot, !snapshot.rows.isEmpty {
        rows(of: snapshot, layout: layout)
      } else {
        WeftEmptyStateView(state: entry.state, compact: family == .systemSmall)
      }
    }
    .padding(WeftWidgetTokens.spaceMD)
    // The surface behind the rows, aimed at the inbox, so the gaps between rows
    // are not dead space and every empty state — especially the empty ones —
    // opens the app when tapped.
    //
    // On `systemSmall` this is the *only* tap target the system honours: a small
    // widget is one link by design and WidgetKit ignores the per-row `Link`s
    // there. That is why the small family drops the preview but keeps three
    // rows — it is a glanceable summary that opens the inbox, not a menu.
    .widgetURL(weftInboxURL)
    .weftWidgetContainerBackground()
  }

  @ViewBuilder
  private func rows(of snapshot: WeftInboxSnapshot, layout: WeftWidgetLayout) -> some View {
    VStack(alignment: .leading, spacing: WeftWidgetTokens.spaceXS) {
      if layout.showHeading {
        Text(WeftWidgetStrings.inboxHeading)
          .font(WeftWidgetTokens.labelFont.weight(.medium))
          .foregroundStyle(.secondary)
      }
      // Keyed on `WeftSnapshotRow.id`, which is the chat id. The payload is
      // rebuilt on every inbox tick and rows move within it constantly; keyed by
      // position, SwiftUI would carry row three's identity onto whatever is
      // third now.
      ForEach(snapshot.rows.prefix(layout.rowCount)) { row in
        WeftConversationRowView(
          row: row,
          // The palette travels once per payload rather than per row, so it is
          // threaded down rather than looked up again.
          palette: snapshot.palette,
          showPreview: layout.showPreview)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

// MARK: - The Lock Screen accessory

#if os(iOS)

  /// Total unread, on the Lock Screen.
  ///
  /// `InboxSnapshot.totalUnread` rather than a sum over the rows, and that
  /// distinction is the reason the field exists: it counts every conversation
  /// the policy allowed, *including* the ones past the row cap. The seventeenth
  /// conversation's unread messages are still unread.
  ///
  /// This is also the surface `WeftSnapshotContainer.writePayload`'s file
  /// protection class was chosen for. A widget renders on a *locked* screen, and
  /// a file protected as `complete` is unreadable there — so the accessory whose
  /// entire job is to show a count on a locked phone would render nothing.
  /// `completeUntilFirstUserAuthentication` is what makes this widget possible.
  struct WeftUnreadWidget: Widget {
    static let kind = "WeftUnread"

    var body: some WidgetConfiguration {
      StaticConfiguration(kind: Self.kind, provider: WeftWidgetProvider()) { entry in
        WeftUnreadWidgetView(entry: entry)
      }
      .configurationDisplayName(WeftWidgetStrings.unreadDisplayName)
      .description(WeftWidgetStrings.unreadDescription)
      .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
  }

  struct WeftUnreadWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: WeftWidgetEntry

    var body: some View {
      Group {
        switch family {
        case .accessoryCircular: circular
        case .accessoryInline: inline
        default: rectangular
        }
      }
      .widgetURL(weftInboxURL)
      .weftWidgetContainerBackground()
    }

    /// The count in a ring.
    ///
    /// `AccessoryWidgetBackground` rather than a colour: it is the system's own
    /// vibrancy-aware disc, and it is the only thing that keeps a circular
    /// accessory legible over an arbitrary wallpaper. A widget that paints its
    /// own background here is the one that disappears against a light photo.
    ///
    /// The cap is applied *here* — `unreadLabel` — because unlike a row's badge
    /// this number does not arrive pre-formatted. `totalUnread` is a count
    /// rather than a label precisely so the accessory and the watch
    /// complication can have it as one; the `99+` rule is then owed on this
    /// side, which is what `WeftSnapshotFormat.unreadLabel` is.
    private var circular: some View {
      ZStack {
        AccessoryWidgetBackground()
        VStack(spacing: 0) {
          Text(WeftSnapshotFormat.unreadLabel(entry.state.totalUnread))
            .font(WeftWidgetTokens.countFont)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
          Text(WeftWidgetStrings.unreadLabel)
            .font(WeftWidgetTokens.labelFont)
            .lineLimit(1)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
    }

    /// One line beside the clock. A single `Text` because that is all the
    /// `accessoryInline` family renders — a `VStack` here is silently collapsed.
    private var inline: some View {
      Text(inlineText)
    }

    /// The wide slot: the count, and the state's own sentence when there is no
    /// count worth showing.
    private var rectangular: some View {
      VStack(alignment: .leading, spacing: 0) {
        if entry.state.snapshot != nil {
          Text("\(WeftSnapshotFormat.unreadLabel(entry.state.totalUnread)) \(WeftWidgetStrings.unreadLabel)")
            .font(WeftWidgetTokens.titleFont.weight(.semibold))
            .lineLimit(1)
          // The most recent conversation's name, and the one piece of this
          // widget that is a disclosure rather than a count — so it is the one
          // piece marked `privacySensitive`. On a Lock Screen with previews
          // hidden the system redacts it and the count above survives, which is
          // exactly the split `SnapshotPolicy.includePreviews` and
          // `includeSenderNames` make on the writing side.
          if let title = entry.state.snapshot?.rows.first?.title {
            Text(title)
              .font(WeftWidgetTokens.bodyFont)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .privacySensitive()
          }
        } else {
          WeftEmptyStateView(state: entry.state, compact: true)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
    }

    /// What the inline family says, and what a screen reader hears everywhere.
    ///
    /// Never a bare number: "3" beside a clock is not a fact anybody can act on.
    private var inlineText: String {
      guard entry.state.snapshot != nil else {
        return WeftWidgetStrings.emptyState(for: entry.state).title
      }
      return WeftWidgetStrings.unreadCount(entry.state.totalUnread)
    }

    private var accessibilityLabel: String { inlineText }
  }

#endif
