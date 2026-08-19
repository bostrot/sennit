import SwiftUI
import WidgetKit

/// The pieces every Weft widget is built from.
///
/// Two widgets, one vocabulary: the same rows, the same empty states, the same
/// badge. Split out rather than duplicated because the difference between the
/// Lock Screen accessory and the inbox list is only what they draw when there
/// *is* something to draw — every other state is the same sentence, and a user
/// with both on one device must not be told two different things about one
/// setting. The Swift counterpart of `WeftWidgetContent.kt`.

/// `weft://`, which `WeftLink.parse` reads as `OpenInboxLink`.
///
/// A URL with no path segments rather than an invented `weft://inbox`: the
/// parser returns `OpenInboxLink` for an empty segment list and `null` for an
/// unrecognised first segment, so the invented spelling is the one that opens
/// nothing. Written here rather than carried in the payload because it names no
/// conversation and so discloses nothing — it is the one link on this surface
/// that is not a privacy decision.
///
/// Force-unwrapped, which is the one force-unwrap in this target: the string is
/// a literal, `URL(string:)` on it cannot fail, and the alternative is an
/// optional every call site has to have an opinion about.
let weftInboxURL = URL(string: "weft://")!

// MARK: - Empty states

/// A state that has nothing to show, and says why.
///
/// Every branch of `WeftWidgetState` that is not a populated `ready` lands here.
/// The rule it exists to keep is the phase brief's — *placeholder, signed-out
/// and disabled states, all legible* — so each one names its own cause and,
/// where there is one, the thing the user would do about it. None of them is a
/// blank rectangle.
///
/// Nothing here is `privacySensitive`: these sentences are about the app's own
/// configuration and disclose no conversation, so redacting them on a locked
/// screen would hide the only text that could explain why the widget is empty.
struct WeftEmptyStateView: View {
  let state: WeftWidgetState

  /// Compact families get the headline alone. A `systemSmall` widget or an
  /// `accessoryRectangular` slot has room for about two lines, and a headline
  /// truncated to make space for a body neither of which fits is worse than the
  /// headline on its own.
  var compact: Bool = false

  var body: some View {
    let copy = WeftWidgetStrings.emptyState(for: state)
    VStack(alignment: .leading, spacing: WeftWidgetTokens.spaceXS) {
      Text(copy.title)
        .font(WeftWidgetTokens.titleFont.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(2)
      if !compact {
        Text(copy.body)
          .font(WeftWidgetTokens.bodyFont)
          .foregroundStyle(.secondary)
          .lineLimit(4)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Rows

/// One conversation.
///
/// The whole row is the tap target and it carries the row's own link, which is
/// the part that has to be right. `Link` rather than `widgetURL` because a
/// medium or large family draws several of these and `widgetURL` is one URL for
/// the entire widget — set it per row and the last one wins, silently, which
/// reads as every row opening the same conversation. `widgetURL` is still set on
/// the surface *behind* the rows, so the gaps between them are not dead space.
///
/// Merged conversations are signalled two ways, neither of them colour on its
/// own: the *number* of glyph dots, and the accessibility label. `ChatTile`
/// manages three; a row this size can carry two, which is the floor the design
/// notes set.
struct WeftConversationRowView: View {
  let row: WeftSnapshotRow
  let palette: [String: UInt32]
  let showPreview: Bool

  var body: some View {
    // Folded into one optional rather than kept as a flag beside the text: the
    // row has to make the same decision twice — once for its layout and once for
    // its second line — and two spellings of it is how those two drift apart.
    let preview = showPreview ? row.previewLine : nil

    Link(destination: row.link) {
      HStack(alignment: .center, spacing: WeftWidgetTokens.spaceSM) {
        WeftNetworkDotsView(row: row, palette: palette)
        VStack(alignment: .leading, spacing: 2) {
          Text(row.title)
            .font(
              // Unread is what this surface exists to show, so it is carried by
              // weight as well as by the badge — the same "never one signal
              // alone" rule the merged indicator follows, and the one that
              // survives a user who cannot see the badge's colour.
              WeftWidgetTokens.titleFont.weight(row.unreadCount > 0 ? .bold : .regular)
            )
            .foregroundStyle(.primary)
            .lineLimit(1)
            // The conversation's name is a disclosure, so the system may hide it
            // when it renders this widget on a locked screen. `privacySensitive`
            // is what asks it to: without it the redacted rendering mode leaves
            // the text exactly as it is.
            .privacySensitive()
          // The preview is already policy-filtered, already rendered per kind by
          // `weft_notify`, and already cut at a grapheme boundary. Nothing here
          // re-truncates it: a second cut would be a second rule, and this one
          // would be measured in the wrong units.
          if let preview {
            Text(preview)
              .font(WeftWidgetTokens.bodyFont)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .privacySensitive()
          }
        }
        Spacer(minLength: 0)
        if row.unreadCount > 0 {
          WeftUnreadBadgeView(label: row.unreadLabel)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // The whole row, including its empty right-hand side, has to be tappable —
      // `contentShape` is what makes the `Spacer` part of the target rather than
      // a hole between the title and the badge.
      .contentShape(Rectangle())
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel(preview: preview))
  }

  /// What a screen reader hears for a row.
  ///
  /// Assembled here rather than left to SwiftUI's default, which would read the
  /// title, the preview and the badge as three unrelated strings in layout
  /// order — so a merged conversation would be indistinguishable from a plain
  /// one, and the unread count would arrive after the message it belongs to.
  ///
  /// Counts networks off `row.networks` rather than off the dots that were
  /// drawn, because the strip is capped at `maxNetworkDots` and a fifth network
  /// is dropped silently.
  private func accessibilityLabel(preview: String?) -> String {
    var parts = [row.title]
    if row.isMerged { parts.append(WeftWidgetStrings.merged) }
    if row.unreadCount > 0 {
      parts.append(WeftWidgetStrings.unreadCount(row.unreadCount))
    }
    if let preview { parts.append(preview) }
    return parts.joined(separator: ", ")
  }
}

/// The `99+` pill.
///
/// The label is `SnapshotRow.unreadLabel`, formatted on the phone. The cap is
/// `WeftUnreadBadge`'s and it is applied in Dart precisely so the same
/// conversation does not read `120` in the app and `99+` here, or the reverse.
struct WeftUnreadBadgeView: View {
  let label: String

  var body: some View {
    Text(label)
      .font(WeftWidgetTokens.labelFont.weight(.medium))
      .foregroundStyle(WeftWidgetTokens.brandOnPrimary)
      .padding(.horizontal, WeftWidgetTokens.spaceSM)
      .padding(.vertical, 2)
      .background(WeftWidgetTokens.brandPrimary, in: Capsule())
      .lineLimit(1)
      // A count is not a name. It stays visible on a locked screen for the same
      // reason the accessory exists at all — the number is the fact the user
      // asked this surface to show them, and it identifies no one.
      .accessibilityHidden(true)
  }
}

/// One dot per network feeding the conversation, in the payload's order.
///
/// Colours come from `InboxSnapshot.palette` — `ChatNetwork.brandColor`, carried
/// as an int, once per payload rather than once per row — and fall back to a
/// semantic colour when the payload names a network this build has never heard
/// of. That fallback is why the *count* of dots rather than their colour is what
/// says "merged": an unknown network still gets a dot.
///
/// Stacked vertically rather than in a row because the strip sits in a fixed
/// column to the left of the title, and a merged conversation must not push the
/// title further right than a plain one does.
struct WeftNetworkDotsView: View {
  let row: WeftSnapshotRow
  let palette: [String: UInt32]

  var body: some View {
    VStack(spacing: 2) {
      ForEach(row.networks.prefix(WeftWidgetTokens.maxNetworkDots), id: \.self) { network in
        Circle()
          .fill(colour(for: network))
          .frame(width: WeftWidgetTokens.dot, height: WeftWidgetTokens.dot)
      }
    }
    .frame(width: WeftWidgetTokens.dot)
    .accessibilityHidden(true)
  }

  private func colour(for network: String) -> Color {
    guard let brand = palette[network] else { return WeftWidgetTokens.unknownNetwork }
    return WeftWidgetTokens.color(fromARGB: brand)
  }
}
